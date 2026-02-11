<p align="center">
  <h1 align="center">fzf-oil.nvim</h1>
</p>

![Neovim](https://badgen.net/badge/Neovim/0.11%2B/green)
![Lua](https://badgen.net/badge/language/Lua/blue)
![License](https://badgen.net/static/license/MIT/blue)

<p align="center">
  A tiny (<300 LOC) plugin combining <a href="https://github.com/ibhagwan/fzf-lua">fzf-lua</a>
  and <a href="https://github.com/stevearc/oil.nvim">oil.nvim</a> for finding and
  file browsing, with seamless toggling between them.
</p>

## Features
- Browse directories with fzf-lua, navigate into subdirectories or up to parent.
- Toggle into oil.nvim for full directory editing, toggle back to fzf.
- Window sizing, backdrop, and border are inherited from your fzf-lua config.
- Recursive find mode to search across all subdirectories.
- All keybindings are configurable.

## Requirements
- Neovim 0.11+
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)
- [oil.nvim](https://github.com/stevearc/oil.nvim)
- [fd](https://github.com/sharkdp/fd)

## Installation

With vim.pack:
```lua
vim.pack.add({
    "https://github.com/ibhagwan/fzf-lua",
    "https://github.com/stevearc/oil.nvim",
    "https://github.com/ingur/fzf-oil.nvim",
})
```

With lazy.nvim:
```lua
{
    "ingur/fzf-oil.nvim",
    dependencies = {
        "ibhagwan/fzf-lua",
        "stevearc/oil.nvim",
    },
}
```

## Quickstart
```lua
-- use fzf-oil's float helper so oil matches fzf-lua's dimensions
require("oil").setup({
    float = require("fzf-oil").float,
})

local browser = require("fzf-oil").setup()

vim.keymap.set("n", "<leader>fb", browser.browse, { desc = "File browser" })
```

> [!TIP]
> `require("fzf-oil").float` provides an override that syncs oil's floating
> window size and border with your fzf-lua config. You can also use
> `require("fzf-oil").override` directly in your own oil float config.

## Defaults
```lua
local defaults = {
    cmd = "fd --max-depth 1 --hidden --exclude .git --type f --type d --type l",
    find_cmd = "fd --hidden --exclude .git --type f --type l",
    cwd = function() return vim.fn.expand("%:p:h") end,
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
```

## Keybindings

### fzf mode

| Key | Action |
|-----|--------|
| `<CR>` | Open file or enter directory |
| `<C-h>` | Go to parent directory |
| `<C-f>` | Toggle recursive find mode |
| `<C-e>` | Switch to oil |
| `<C-g>` | Jump to home directory |

### oil mode

| Key | Action |
|-----|--------|
| `<C-e>` | Switch back to fzf |
| `q` | Switch back to fzf |
| `<C-g>` | Jump to home directory |

All keys are configurable through `setup({ keys = { ... } })`.
