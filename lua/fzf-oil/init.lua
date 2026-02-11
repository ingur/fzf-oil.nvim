local M = {}

local api = vim.api

local defaults = {
    cmd = "fd --max-depth 1 --hidden --exclude .git --type f --type d --type l",
    find_cmd = "fd --hidden --exclude .git --type f --type l",
    cwd = vim.fn.getcwd,
    start_mode = "fzf", -- "fzf" or "oil"
    zindex = 40,
    border = "rounded",
    keys = {
        parent = "<C-h>",
        toggle_find = "<C-f>",
        edit = "<C-e>",
        quit = "q",
        home = "<C-g>",
    },
    fzf_exec_opts = {},
}

-- helpers

local function eval(v)
    if type(v) == "function" then return v() end
    return v
end

-- translate vim keymap notation ("<C-e>") to fzf key notation ("ctrl-e")
local vim_special = {
    BS = "bs", CR = "enter", Space = "space", Tab = "tab",
    ["S-Tab"] = "btab", Esc = "esc", Del = "del",
    Up = "up", Down = "down", Left = "left", Right = "right",
    Home = "home", End = "end", PageUp = "pgup", PageDown = "pgdn",
}

local function vim_to_fzf(key)
    local mod, rest = key:match("^<([CcAaMm])%-(.+)>$")
    if mod then
        local fzf_mod = (mod == "C" or mod == "c") and "ctrl" or "alt"
        local fzf_key = vim_special[rest] or rest:lower()
        return fzf_mod .. "-" .. fzf_key
    end
    local special = key:match("^<(.+)>$")
    if special and vim_special[special] then
        return vim_special[special]
    end
    return key
end

-- window sizing (reads from fzf-lua's resolved config)

local function fzf_win_opts()
    local fzf_config = require("fzf-lua.config").globals
    local winopts = fzf_config.winopts
    local width = winopts.width or 0.80
    local height = winopts.height or 0.85
    local row = winopts.row or 0.35
    local col = winopts.col or 0.55

    local ch = vim.o.cmdheight
    local w = math.floor(vim.o.columns * width) - 2
    local h = math.floor((vim.o.lines - ch) * height) - 2
    local r = math.floor((vim.o.lines - h - 2) * row)
    local c = math.floor((vim.o.columns - w - 2) * col)
    return { width = w, height = h, row = r, col = c }
end

-- backdrop management

local active_config = defaults
local backdrop = { win = nil, buf = nil }

local function close_backdrop()
    if backdrop.win and api.nvim_win_is_valid(backdrop.win) then
        api.nvim_win_close(backdrop.win, true)
    end
    if backdrop.buf and api.nvim_buf_is_valid(backdrop.buf) then
        api.nvim_buf_delete(backdrop.buf, { force = true })
    end
    backdrop.win = nil
    backdrop.buf = nil
end

local function create_backdrop()
    close_backdrop()

    local winopts = require("fzf-lua.config").globals.winopts

    local opacity = winopts.backdrop
    if not opacity or opacity == false then return end
    if type(opacity) == "boolean" then opacity = 60 end

    backdrop.buf = api.nvim_create_buf(false, true)
    backdrop.win = api.nvim_open_win(backdrop.buf, false, {
        relative = "editor",
        width = vim.o.columns,
        height = vim.o.lines,
        row = 0,
        col = 0,
        style = "minimal",
        focusable = false,
        zindex = active_config.zindex,
        border = "none",
    })
    vim.wo[backdrop.win].winhl = "Normal:FzfLuaBackdrop"
    vim.wo[backdrop.win].winblend = opacity
end

-- oil float tracking

local oil_win = nil
local transitioning = false

local function close_oil()
    if oil_win and api.nvim_win_is_valid(oil_win) then
        api.nvim_win_close(oil_win, true)
    end
    oil_win = nil
end

-- oil editor

local function open_editor(config, cwd, on_toggle)
    close_oil()

    local ag = api.nvim_create_augroup("fzf-oil-keymaps", { clear = true })

    local function toggle_back()
        if transitioning then return end
        local dir = require("oil").get_current_dir() or cwd
        api.nvim_clear_autocmds({ group = ag })
        local prev_win = oil_win
        oil_win = nil
        transitioning = true
        local ok, err = pcall(on_toggle, dir)
        -- oil's WinLeave autocmd also tries to close this window;
        -- the nvim_win_is_valid guard in both paths prevents double-close issues
        if prev_win and api.nvim_win_is_valid(prev_win) then
            api.nvim_win_close(prev_win, true)
        end
        vim.schedule(function() transitioning = false end)
        if not ok then vim.notify("fzf-oil: " .. tostring(err), vim.log.levels.ERROR) end
    end

    -- keymaps via OilEnter (fires for every new oil buffer during navigation)
    api.nvim_create_autocmd("User", {
        group = ag,
        pattern = "OilEnter",
        callback = function(args)
            local buf = args.data and args.data.buf or api.nvim_get_current_buf()
            vim.keymap.set("n", config.keys.edit, toggle_back, { buffer = buf, desc = "fzf-oil: toggle fzf" })
            vim.keymap.set("n", config.keys.quit, toggle_back, { buffer = buf, desc = "fzf-oil: quit" })
            vim.keymap.set("n", config.keys.home, function()
                require("oil").open(vim.env.HOME)
            end, { buffer = buf, desc = "fzf-oil: go home" })
        end,
    })

    require("oil").open_float(cwd)
    oil_win = api.nvim_get_current_win()

    -- oil exit detection
    api.nvim_create_autocmd("WinClosed", {
        group = ag,
        pattern = tostring(oil_win),
        once = true,
        callback = function()
            vim.schedule(function()
                if transitioning then return end
                close_backdrop()
            end)
        end,
    })

    -- resize oil float to match fzf-lua dimensions
    local wopts = fzf_win_opts()
    api.nvim_win_set_config(oil_win, {
        relative = "editor",
        width = wopts.width,
        height = wopts.height,
        row = wopts.row,
        col = wopts.col,
    })
end

-- fzf browser

local function browse(config, cwd, find_mode)
    cwd = vim.fn.resolve(eval(cwd) or eval(config.cwd))
    cwd = cwd:gsub("/+$", "")

    local fzf = require("fzf-lua")
    local cmd = find_mode and config.find_cmd or config.cmd

    local opts = vim.tbl_deep_extend("force", {
        _type = "file",
        cwd = cwd,
        prompt = vim.fn.fnamemodify(cwd, ":~") .. "/",
        formatter = false,
        file_icons = true,
        color_icons = true,
        previewer = "builtin",
        winopts = {
            backdrop = false, -- use our own backdrop
            border = config.border,
            on_close = function()
                vim.schedule(function()
                    if transitioning then return end
                    if not oil_win or not api.nvim_win_is_valid(oil_win) then
                        close_backdrop()
                    end
                end)
            end,
        },
        actions = {
            ["default"] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1]).path
                local full = cwd .. "/" .. entry
                if vim.fn.isdirectory(full) == 1 then
                    browse(config, full, find_mode)
                else
                    close_backdrop()
                    vim.cmd("edit " .. vim.fn.fnameescape(full))
                end
            end,
            [vim_to_fzf(config.keys.parent)] = function()
                local parent = vim.fn.fnamemodify(cwd, ":h")
                if parent ~= cwd then browse(config, parent, find_mode) end
            end,
            [vim_to_fzf(config.keys.toggle_find)] = function()
                browse(config, cwd, not find_mode)
            end,
            [vim_to_fzf(config.keys.home)] = function()
                browse(config, vim.env.HOME, find_mode)
            end,
            [vim_to_fzf(config.keys.edit)] = function()
                if transitioning then return end
                transitioning = true
                local ok, err = pcall(open_editor, config, cwd, function(dir)
                    browse(config, dir, find_mode)
                end)
                vim.schedule(function() transitioning = false end)
                if not ok then vim.notify("fzf-oil: " .. tostring(err), vim.log.levels.ERROR) end
            end,
        },
    }, config.fzf_exec_opts)

    fzf.fzf_exec(cmd, opts)
end

-- public api

M.setup = function(opts)
    if not pcall(require, "fzf-lua") then
        vim.notify("fzf-oil: missing required plugin fzf-lua", vim.log.levels.ERROR)
        return
    end
    if not pcall(require, "oil") then
        vim.notify("fzf-oil: missing required plugin oil.nvim", vim.log.levels.ERROR)
        return
    end

    local config = vim.tbl_deep_extend("force", defaults, opts or {})
    active_config = config

    config.browse = function(cwd, find_mode)
        create_backdrop()
        if config.start_mode == "oil" then
            open_editor(config, cwd, function(dir)
                browse(config, dir, find_mode)
            end)
        else
            browse(config, cwd, find_mode)
        end
    end

    return config
end

--- Override function for oil's float config to match fzf-lua dimensions and border.
--- Usage: require("oil").setup({ float = { override = require("fzf-oil").override } })
M.override = function(conf)
    local win = fzf_win_opts()
    conf.width = win.width
    conf.height = win.height
    conf.row = win.row
    conf.col = win.col
    conf.border = active_config.border
    return conf
end

--- Helper float config for oil that matches fzf-lua styling.
--- Usage: require("oil").setup({ float = require("fzf-oil").float })
M.float = {
    border = "rounded", -- fallback for oil's internal checks, override sets actual value
    override = M.override,
    win_options = {
        winhl = "NormalFloat:FzfLuaNormal,FloatBorder:FzfLuaBorder",
    },
}

return M
