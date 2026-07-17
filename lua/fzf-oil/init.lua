local M = {}

local api = vim.api

local fd = vim.fn.executable("fd") == 0 and vim.fn.executable("fdfind") == 1 and "fdfind" or "fd"

local defaults = {
    cmd = fd .. " --max-depth 1 --hidden --exclude .git --type f --type d --type l",
    find_cmd = fd .. " --hidden --exclude .git --type f --type l",
    cwd = function()
        local dir = vim.fn.expand("%:p:h")
        if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
            return dir
        end
        return vim.fn.getcwd()
    end,
    start_mode = "fzf", -- "fzf" or "oil"
    zindex = 40,
    border = "rounded",
    keys = {
        parent = "<C-h>",
        child = "<C-l>",
        down = "<C-j>",
        up = "<C-k>",
        toggle_find = "<C-f>",
        edit = "<C-e>",
        home = "<C-g>",
        back = "<C-o>",
        quit = "q",
    },
    fzf_exec_opts = {},
}

-- helpers

local function eval(v)
    if type(v) == "function" then return v() end
    return v
end

local function notify_err(err)
    vim.notify("fzf-oil: " .. tostring(err), vim.log.levels.ERROR)
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

-- fzf-lua.config is internal, guard it so a refactor there falls back to defaults
local fzf_winopts_fallback = {
    width = 0.80, height = 0.85, row = 0.35, col = 0.55, backdrop = 60, zindex = 50,
}

local function fzf_winopts()
    local ok, config = pcall(require, "fzf-lua.config")
    if ok and type(config.globals) == "table" and type(config.globals.winopts) == "table" then
        return config.globals.winopts
    end
    return fzf_winopts_fallback
end

-- window sizing (reads from fzf-lua's resolved config)

local function fzf_win_opts()
    local winopts = fzf_winopts()
    local width = winopts.width or 0.80
    local height = winopts.height or 0.85
    local row = winopts.row or 0.35
    local col = winopts.col or 0.55

    local ch = vim.o.cmdheight
    local w = math.floor(vim.o.columns * width) - 2
    local h = math.floor((vim.o.lines - ch) * height) - 2
    local r = math.floor((vim.o.lines - h - 2) * row)
    local c = math.floor((vim.o.columns - w - 2) * col)
    -- oil floats above the fzf window during transitions
    return { width = w, height = h, row = r, col = c, zindex = (winopts.zindex or 50) + 1 }
end

-- session state

local state = {
    config = defaults,
    backdrop = nil,   -- { win, buf } dimming the editor for the whole session
    oil_win = nil,    -- oil float window while in oil mode
    hidden_cwd = nil, -- cwd of the hidden fzf picker while in oil mode
    source_win = nil, -- window that opened the browser
    fzf_panes = nil,  -- fzf list/preview rects captured when toggling to oil
    history = {},     -- visited directories for back navigation
}

local function remember_dir(dir)
    state.history[#state.history + 1] = dir
end

local function restore_source()
    if state.source_win and api.nvim_win_is_valid(state.source_win) then
        api.nvim_set_current_win(state.source_win)
    end
end

local function close_backdrop()
    local b = state.backdrop
    state.backdrop = nil
    if not b then return end
    if api.nvim_win_is_valid(b.win) then api.nvim_win_close(b.win, true) end
    if api.nvim_buf_is_valid(b.buf) then api.nvim_buf_delete(b.buf, { force = true }) end
end

local function ensure_backdrop()
    if state.backdrop and api.nvim_win_is_valid(state.backdrop.win) then return end

    local opacity = fzf_winopts().backdrop
    if not opacity or opacity == false then return end
    if type(opacity) == "boolean" then opacity = 60 end
    if not api.nvim_get_hl(0, { name = "Normal", link = false }).bg then return end

    local buf = api.nvim_create_buf(false, true)
    local win = api.nvim_open_win(buf, false, {
        relative = "editor",
        width = vim.o.columns,
        height = vim.o.lines,
        row = 0,
        col = 0,
        style = "minimal",
        focusable = false,
        zindex = state.config.zindex,
        border = "none",
    })
    vim.wo[win].winhl = "Normal:FzfLuaBackdrop"
    vim.wo[win].winblend = opacity
    state.backdrop = { win = win, buf = buf }
end

local function discard_hidden()
    if not state.hidden_cwd then return end
    state.hidden_cwd = nil
    require("fzf-lua").win.close()
end

local function oil_preview_win()
    for _, w in ipairs(api.nvim_list_wins()) do
        if vim.w[w].oil_preview then return w end
    end
end

local function win_rect(win)
    local c = api.nvim_win_get_config(win)
    return { relative = "editor", row = c.row, col = c.col, width = c.width, height = c.height }
end

-- place oil's panes exactly where the fzf panes were and match the preview style
local function open_oil_preview()
    local panes = state.fzf_panes
    local oil_float = require("oil.config").float
    local saved = oil_float.preview_split
    oil_float.preview_split = panes.preview.col > panes.list.col and "right" or "below"
    require("oil").open_preview({}, function(err)
        local pw = oil_preview_win()
        if err or not pw or not (state.oil_win and api.nvim_win_is_valid(state.oil_win)) then
            return
        end
        api.nvim_win_set_config(state.oil_win, panes.list)
        api.nvim_win_set_config(pw, vim.tbl_extend("force", panes.preview, {
            title = api.nvim_win_get_config(pw).title,
            title_pos = "center",
        }))
        vim.wo[pw].winhl = "NormalFloat:FzfLuaNormal,FloatBorder:FzfLuaBorder,FloatTitle:FzfLuaPreviewTitle"
    end)
    oil_float.preview_split = saved
end

local browse

-- resume the hidden picker when oil stayed in the same directory, else start fresh
local function toggle_fzf(config, dir, find_mode)
    local same = state.hidden_cwd and state.hidden_cwd == dir:gsub("/+$", "")
    state.hidden_cwd = nil
    if not (same and require("fzf-lua").unhide()) then
        browse(config, dir, find_mode)
    end
end

-- oil editor

local function open_editor(config, cwd, find_mode)
    local ag = api.nvim_create_augroup("fzf-oil", { clear = true })

    local maps
    local mapped = {}
    local previewed = false

    -- oil reapplies its own keymaps when it reinitializes a buffer, so always
    -- set ours again and only capture the originals once
    local function set_maps(buf)
        mapped[buf] = mapped[buf] or {}
        for k, fn in pairs(maps) do
            if mapped[buf][k] == nil then
                mapped[buf][k] = vim.fn.maparg(k, "n", false, true)
            end
            vim.keymap.set("n", k, fn, { buffer = buf, desc = "fzf-oil" })
        end
        -- opening the preview mid-render trips oil's cursor constraining
        if not previewed and state.fzf_panes and require("oil").get_cursor_entry() then
            previewed = true
            vim.schedule(function() pcall(open_oil_preview) end)
        end
    end

    local function teardown()
        api.nvim_clear_autocmds({ group = ag })
        -- oil only closes its preview when focus leaves oil for a non-oil buffer
        local pw = oil_preview_win()
        if pw then api.nvim_win_close(pw, true) end
        for buf, saved in pairs(mapped) do
            if api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "oil" then
                api.nvim_buf_call(buf, function()
                    for k, m in pairs(saved) do
                        pcall(vim.keymap.del, "n", k, { buffer = buf })
                        if m.buffer == 1 then vim.fn.mapset("n", false, m) end
                    end
                end)
            end
        end
        mapped = {}
    end

    local oil = require("oil")

    local function toggle_back(find)
        if api.nvim_get_current_win() ~= state.oil_win then return end
        if find == nil then find = find_mode end
        if find ~= find_mode then state.hidden_cwd = nil end
        local dir = oil.get_current_dir() or cwd
        -- oil only records cursor memory when navigating within oil, not on close
        local entry = oil.get_cursor_entry()
        if entry then
            pcall(require("oil.view").set_last_cursor, api.nvim_buf_get_name(0), entry.name)
        end
        teardown()
        local win = state.oil_win
        state.oil_win = nil
        local ok, err = pcall(toggle_fzf, config, dir, find)
        if win and api.nvim_win_is_valid(win) then
            api.nvim_win_close(win, true)
        end
        if not ok then notify_err(err) end
    end

    maps = {
        [config.keys.edit] = toggle_back,
        [config.keys.quit] = function()
            if api.nvim_get_current_win() == state.oil_win then
                api.nvim_win_close(0, true)
            end
        end,
        [config.keys.toggle_find] = function() toggle_back(true) end,
        [config.keys.home] = function()
            local dir = oil.get_current_dir()
            if vim.fs.normalize(dir) == vim.fs.normalize(vim.env.HOME) then return end
            remember_dir(dir)
            oil.open(vim.env.HOME)
        end,
        [config.keys.back] = function()
            local dir = table.remove(state.history)
            if dir then oil.open(dir) end
        end,
        [config.keys.down] = "j",
        [config.keys.up] = "k",
        [config.keys.parent] = function()
            local dir = oil.get_current_dir()
            if vim.fn.fnamemodify(dir, ":h") ~= dir then remember_dir(dir) end
            require("oil.actions").parent.callback()
        end,
        [config.keys.child] = function()
            local dir = oil.get_current_dir()
            local entry = oil.get_cursor_entry()
            if entry and vim.fn.isdirectory(dir .. entry.name) == 1 then
                remember_dir(dir)
                require("oil.actions").select.callback()
            end
        end,
    }

    -- OilEnter only fires on first render (after oil sets its own keymaps),
    -- reused cached buffers are covered by BufEnter + b.oil_ready
    api.nvim_create_autocmd("User", {
        group = ag,
        pattern = "OilEnter",
        callback = function(args)
            local buf = args.data and args.data.buf or api.nvim_get_current_buf()
            if api.nvim_win_get_config(0).relative ~= "" then set_maps(buf) end
        end,
    })
    api.nvim_create_autocmd("BufEnter", {
        group = ag,
        pattern = "oil://*",
        callback = function(args)
            if api.nvim_win_get_config(0).relative ~= "" and vim.b[args.buf].oil_ready then
                set_maps(args.buf)
            end
        end,
    })

    require("oil").open_float(cwd)
    state.oil_win = api.nvim_get_current_win()

    -- oil closed without toggling back (":q", opening a file, ...)
    api.nvim_create_autocmd("WinClosed", {
        group = ag,
        pattern = tostring(state.oil_win),
        once = true,
        callback = function()
            teardown()
            state.oil_win = nil
            close_backdrop()
            discard_hidden()
            restore_source()
        end,
    })

    -- fallback sizing for setups without the float helper below
    if require("oil.config").float.override ~= M.override then
        api.nvim_win_set_config(state.oil_win,
            vim.tbl_extend("force", { relative = "editor" }, fzf_win_opts()))
    end
end

-- fzf browser

local function title(dir)
    return " " .. vim.fn.fnamemodify(dir, ":~"):gsub("/+$", "") .. "/ "
end

-- the in-process producer re-reads opts.cwd, so reload actions re-list in place
local function reload(fn)
    return { fn = fn, reload = true, postfix = "clear-query" }
end

browse = function(config, cwd, find_mode)
    cwd = vim.fn.resolve(eval(cwd) or eval(config.cwd)):gsub("/+$", "")

    local fzf = require("fzf-lua")
    local session = { cwd = cwd, find = find_mode }

    local function nav(o, dir, remember)
        dir = vim.fn.resolve(dir):gsub("/+$", "")
        if dir == session.cwd then return end
        if remember ~= false then remember_dir(session.cwd) end
        o.cwd = dir
        session.cwd = dir
        local win = fzf.win.__SELF()
        if win then pcall(win.update_main_title, win, title(dir)) end
    end

    local function sel_path(o, selected)
        if not selected or #selected == 0 then return end
        return o.cwd .. "/" .. fzf.path.entry_to_file(selected[1]).path
    end

    local opts = vim.tbl_deep_extend("force", {
        _type = "file",
        __stringify_cmd = true,
        multiprocess = false,
        cwd = cwd,
        formatter = false,
        previewer = "builtin",
        winopts = {
            title = title(cwd),
            title_pos = "left",
            backdrop = false,
            border = config.border,
            on_close = function()
                if not (state.oil_win and api.nvim_win_is_valid(state.oil_win)) then
                    close_backdrop()
                    restore_source()
                end
            end,
        },
        keymap = {
            fzf = {
                [vim_to_fzf(config.keys.down)] = "down",
                [vim_to_fzf(config.keys.up)] = "up",
            },
        },
        actions = {
            ["enter"] = reload(function(selected, o)
                local full = sel_path(o, selected)
                if not full then return end
                if vim.fn.isdirectory(full) == 1 then
                    nav(o, full)
                else
                    fzf.win.close()
                    vim.cmd("edit " .. vim.fn.fnameescape(full))
                end
            end),
            [vim_to_fzf(config.keys.parent)] = reload(function(_, o)
                nav(o, vim.fn.fnamemodify(o.cwd, ":h"))
            end),
            [vim_to_fzf(config.keys.child)] = reload(function(selected, o)
                local full = sel_path(o, selected)
                if full and vim.fn.isdirectory(full) == 1 then nav(o, full) end
            end),
            [vim_to_fzf(config.keys.home)] = reload(function(_, o)
                nav(o, vim.env.HOME)
            end),
            [vim_to_fzf(config.keys.back)] = reload(function(_, o)
                local dir = table.remove(state.history)
                if dir then nav(o, dir, false) end
            end),
            [vim_to_fzf(config.keys.toggle_find)] = {
                fn = function() session.find = not session.find end,
                reload = true,
            },
            [vim_to_fzf(config.keys.edit)] = {
                fn = function()
                    state.hidden_cwd = session.cwd
                    local W = fzf.win.__SELF()
                    state.fzf_panes = W and W.preview_winid
                        and api.nvim_win_is_valid(W.preview_winid)
                        and { list = win_rect(W.fzf_winid), preview = win_rect(W.preview_winid) }
                        or nil
                    local ok, err = pcall(open_editor, config, session.cwd, session.find)
                    if ok then
                        fzf.hide()
                        -- hide() restores focus to the pre-fzf window
                        api.nvim_set_current_win(state.oil_win)
                    else
                        state.hidden_cwd = nil
                        notify_err(err)
                    end
                end,
                exec_silent = true,
            },
        },
    }, config.fzf_exec_opts)

    fzf.fzf_exec(function()
        return session.find and config.find_cmd or config.cmd
    end, opts)
end

-- public api

M.setup = function(opts)
    for _, dep in ipairs({ "fzf-lua", "oil" }) do
        if not pcall(require, dep) then
            return notify_err("missing required plugin " .. dep)
        end
    end

    local config = vim.tbl_deep_extend("force", defaults, opts or {})
    state.config = config

    config.browse = function(cwd, find_mode)
        state.source_win = api.nvim_get_current_win()
        ensure_backdrop()
        state.history = {}
        state.fzf_panes = nil
        if config.start_mode == "oil" then
            state.hidden_cwd = nil
            open_editor(config, cwd and eval(cwd), find_mode)
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
    conf.zindex = win.zindex
    conf.border = state.config.border
    return conf
end

--- Helper float config for oil that matches fzf-lua styling.
--- Usage: require("oil").setup({ float = require("fzf-oil").float })
M.float = {
    border = "rounded", -- fallback for oil's internal checks, override sets actual value
    override = M.override,
    get_win_title = function(winid)
        return title(require("oil").get_current_dir(api.nvim_win_get_buf(winid)) or "")
    end,
    win_options = {
        winhl = "NormalFloat:FzfLuaNormal,FloatBorder:FzfLuaBorder,FloatTitle:FzfLuaTitle",
        fillchars = "eob: ",
    },
}

--- Helper preview config for oil that matches fzf-lua's previewer styling.
--- Usage: require("oil").setup({ preview_win = require("fzf-oil").preview_win })
M.preview_win = {
    win_options = {
        number = true,
        relativenumber = false,
        winhl = "NormalFloat:FzfLuaNormal,FloatBorder:FzfLuaBorder,FloatTitle:FzfLuaPreviewTitle",
    },
}

return M
