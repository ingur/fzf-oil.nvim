<p align="center">
  <h1 align="center">fzf-oil.nvim</h1>
</p>

<img width="1988" height="1232" alt="fzf-oil-demo" src="https://github.com/user-attachments/assets/b581b14b-44ec-4ce3-abfd-d32579bb5009" />

![Neovim](https://badgen.net/badge/Neovim/0.11%2B/green)
![Lua](https://badgen.net/badge/language/Lua/blue)
![License](https://badgen.net/static/license/MIT/blue)

<p align="center">
  A tiny (~400 LOC) plugin combining <a href="https://github.com/ibhagwan/fzf-lua">fzf-lua</a>
  and <a href="https://github.com/stevearc/oil.nvim">oil.nvim</a> for finding and
  file browsing, with seamless toggling between them.
</p>

## Features
- Browse directories with fzf-lua, navigate into subdirectories or up to parent.
- Toggle into oil.nvim for full directory editing, toggle back to fzf.
- Seamless transitions, query and position are preserved when toggling.
- Fuzzy find files across all subdirectories with a single toggle.
- Sizing, backdrop, border, and preview are inherited from your fzf-lua config.
- The same navigation keys work in both modes, all of them configurable.

## Requirements
- Neovim 0.11+
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)
- [oil.nvim](https://github.com/stevearc/oil.nvim)
- [fd](https://github.com/sharkdp/fd)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or
  [mini.icons](https://github.com/echasnovski/mini.icons) (optional)

## Installation

With vim.pack (Neovim 0.12+):
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
-- use fzf-oil's helpers so oil matches fzf-lua's styling
require("oil").setup({
    float = require("fzf-oil").float,
    preview_win = require("fzf-oil").preview_win,
})

local browser = require("fzf-oil").setup()

vim.keymap.set("n", "<leader>fb", browser.browse, { desc = "File browser" })
```

> [!TIP]
> The `float` and `preview_win` helpers sync oil's floating windows with your
> fzf-lua config (size, border, title, preview styling). You can also use
> `require("fzf-oil").override` directly in your own oil float config.

## Defaults
```lua
local defaults = {
    cmd = "fd --max-depth 1 --hidden --exclude .git --type f --type d --type l",
    find_cmd = "fd --hidden --exclude .git --type f --type l",
    cwd = function()        -- falls back to getcwd() for non-file buffers
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
        quit = "q",
        home = "<C-g>",
    },
    fzf_exec_opts = {},
}
```

> [!NOTE]
> `fzf_exec_opts` is deep-merged into the options passed to fzf-lua's `fzf_exec`,
> so you can override any fzf-lua picker option (previewer, layout, actions, ...).

## Keybindings

### fzf mode

| Key | Action |
|-----|--------|
| `<CR>` | Open file or enter directory |
| `<C-h>` | Go to parent directory |
| `<C-l>` | Enter directory |
| `<C-j>` / `<C-k>` | Move down / up |
| `<C-f>` | Toggle find mode |
| `<C-e>` | Switch to oil |
| `<C-g>` | Jump to home directory |

### oil mode

| Key | Action |
|-----|--------|
| `<C-h>` | Go to parent directory |
| `<C-l>` | Enter directory |
| `<C-j>` / `<C-k>` | Move down / up |
| `<C-f>` | Switch to fzf in find mode |
| `<C-e>` | Switch back to fzf |
| `q` | Quit the browser |
| `<C-g>` | Jump to home directory |

All keys are configurable through `setup({ keys = { ... } })`.
