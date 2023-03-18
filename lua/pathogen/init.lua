local actions = require("telescope.actions")
local builtin = require('telescope.builtin')
local state = require("telescope.actions.state")
local finders = require("telescope.finders")
local previewers = require('telescope.previewers')

local M = {}

local unescape_chars = function(str)
    return string.gsub(str, "\\", "")
end

local orig_new_oneshot_job = finders.new_oneshot_job
local __last_search
finders.new_oneshot_job = function(args, opts)
    __last_search = unescape_chars(args[#args])
    return orig_new_oneshot_job(args, opts)
end

local current_mode
local function reload_picker(curr_picker, prompt_bufnr, cwd)
    if current_mode == "browse_file" then
        return curr_picker:reload(cwd)
    end
    local opts = {
        default_text = curr_picker:_get_prompt(),
        attach_mappings = curr_picker.attach_mappings,
        cwd = cwd,
        prompt_prefix = cwd .. "> ",
    }
    if current_mode == "grep_string" then
        opts.search = __last_search
    end
    actions._close(prompt_bufnr)
    builtin[current_mode](opts)
end
local function get_parent_dir(dir)
    return vim.fn.fnamemodify((vim.fs.normalize(dir)):gsub("(\\S*)/*$", "%1"), ":h")
end

local cwd_stack = {}
local previous_mode
local word_match = "-w"
local function common_mappings(_, map)
    local function proceed_with_parent_dir(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local cwd = curr_picker.prompt_prefix:gsub("> $", "")
        if get_parent_dir(cwd) == cwd then
            vim.notify("You are already under root.")
            return
        end
        table.insert(cwd_stack, cwd)
        reload_picker(curr_picker, prompt_bufnr, get_parent_dir(cwd))
    end
    local function revert_back_last_dir(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if #cwd_stack == 0 then
            return
        end
        reload_picker(curr_picker, prompt_bufnr, table.remove(cwd_stack, #cwd_stack))
    end
    local function clear_prompt_or_proceed_with_parent_dir(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if curr_picker:_get_prompt() == "" then
            proceed_with_parent_dir(prompt_bufnr)
        else
            curr_picker:reset_prompt()
        end
    end
    local function change_working_directory(prompt_bufnr)
        local curr_picker = state.get_current_picker(prompt_bufnr)
        local cwd = curr_picker.prompt_prefix:gsub("> $", "")

        if previous_mode then
            if previous_mode == "browse_file" then
                M.browse_file({ cwd = cwd })
            else
                current_mode = previous_mode
                reload_picker(curr_picker, prompt_bufnr, cwd)
            end
            previous_mode = nil
        else
            if current_mode == "browse_file" then
                return
            else
                actions._close(prompt_bufnr)
                previous_mode = current_mode
                M.browse_file({ cwd = cwd, only_dir = true, prompt_title = "Browse directory" })
            end
        end
    end
    map("i", "<C-o>", proceed_with_parent_dir)
    map("i", "<C-l>", revert_back_last_dir)
    map("i", "<C-w>", clear_prompt_or_proceed_with_parent_dir)
    map("i", "<C-b>", change_working_directory)
    if current_mode == "grep_string" then
        local function toggle_word_match(prompt_bufnr)
            word_match = word_match == nil and "-w" or nil
            local curr_picker = state.get_current_picker(prompt_bufnr)
            local cwd = curr_picker.prompt_prefix:gsub("> $", "")
            local opts = {
                default_text = curr_picker:_get_prompt(),
                attach_mappings = curr_picker.attach_mappings,
                cwd = cwd,
                prompt_prefix = cwd .. "> ",
                results_title = word_match == nil and "Results" or "Results with exact word matches",
                word_match = word_match,
                search = __last_search
            }
            actions._close(prompt_bufnr)
            builtin.grep_string(opts)
        end
        map("i", "<C-y>", toggle_word_match)
    end
    return true
end


function M.browse_file(opts)
    current_mode = "browse_file"
    local entry_display = require "telescope.pickers.entry_display"
    -- local cwd = opts.cwd or utils.capture("git rev-parse --show-toplevel", ture)
    local cwd = opts.cwd or vim.fs.normalize(vim.fn.getcwd())
    opts.prompt_title = opts.prompt_title or "Browse file"
    local ls1 = function(path)
        local t = {}
        for _, f in ipairs(vim.fn.globpath(path, "*", false, true)) do
            local offset = string.len(path) + 2
            if path == "/" then
                offset = 2
            elseif string.match(path, ":/$") ~= nil then
                offset = 4
            end
            table.insert(t, {
                value = string.sub(f, offset),
                kind = vim.fn.isdirectory(f) == 1 and "📁" or " "
            })
        end
        return t
    end
    local displayer = entry_display.create {
        separator = " ",
        items = {
            { width = 4 },
            { remaining = true },
        },
    }
    local new_finder = function(cwd)
        return finders.new_table({
            results = ls1(cwd),
            entry_maker = function(entry)
                return {
                    ordinal = entry.value .. (entry.kind == "📁" and "/" or ""),
                    value = entry.value,
                    kind = entry.kind,
                    display = function(entry)
                        return displayer {
                            entry.kind,
                            { entry.value, entry.kind == "📁" and "Directory" or "" },
                        }
                    end,
                }
            end
        })
    end
    local pickit = function(prompt_bufnr)
        local content = state.get_selected_entry(prompt_bufnr)
        if content == nil then
            return
        end
        local curr_picker = state.get_current_picker(prompt_bufnr)
        if content.kind == "📁" then
            cwd = (cwd):sub(-1) ~= "/" and cwd .. "/" or cwd
            cwd = cwd .. content.value
            curr_picker:refresh(new_finder(cwd), { reset_prompt = true, new_prefix = cwd .. "> " })
        else
            vim.cmd("tabedit " .. cwd .. "/" .. content.value)
        end
    end
    local function find_files(prompt_bufnr)
        actions._close(prompt_bufnr)
        previous_mode = current_mode
        M.find_files({
            cwd = cwd
        })
    end
    local function live_grep(prompt_bufnr)
        actions._close(prompt_bufnr)
        previous_mode = current_mode
        M.live_grep({
            cwd = cwd
        })
    end
    local picker = require("telescope.pickers").new(opts, {
        prompt_title = opts.prompt_title,
        prompt_prefix = cwd .. "> ",
        finder = new_finder(cwd),
        previewer = previewers.new_buffer_previewer {
            title = "File Preview",
            define_preview = function(self, entry, status)
                local p = cwd .. "/" .. entry.value
                if p == nil or p == "" then
                    return
                end
                require("telescope.config").values.buffer_previewer_maker(p, self.state.bufnr, {
                    bufname = self.state.bufname,
                    winid = self.state.winid,
                    preview = opts.preview,
                })
            end,
        },
        sorter = require("telescope.config").values.generic_sorter({}),
        attach_mappings = function(_, map)
            -- vim.fn.iunmap
            map("i", "<CR>", pickit)
            map("i", "<Tab>", pickit)
            map("i", "<C-e>", live_grep)
            map("i", "<C-f>", find_files)
            return common_mappings(_, map)
        end,
    })
    picker.reload = function(_, _cwd)
        cwd = _cwd
        local previous_prompt = picker:_get_prompt(),
        picker:refresh(new_finder(cwd), { reset_prompt = true, new_prefix = cwd .. "> " })
        picker:set_prompt(previous_prompt)
    end
    picker:find()
end

local function start_builtin(opts)
    opts = opts or {}
    opts.cwd = opts.cwd or vim.loop.cwd()
    opts.prompt_prefix = opts.cwd .. "> "
    opts.attach_mappings = common_mappings
    builtin[current_mode](opts)
end

function M.grep_string(opts)
    current_mode = "grep_string"
    opts = opts or {}
    opts.word_match = word_match
    opts.results_title = word_match == nil and "Results" or "Results with exact word matches"
    start_builtin(opts)
end

function M.find_files(opts)
    current_mode = "find_files"
    start_builtin(opts)
end

function M.live_grep(opts)
    current_mode = "live_grep"
    start_builtin(opts)
end

return M