-- [[ Options to customize experience. Functionally + Aesthetics ]]
local opt = vim.opt
--local cmd = vim.api.nvim_command

-- [[ Context ]] 
opt.number = true                -- bool: Show line numbers
opt.scrolloff = 4                -- int:  Min num lines of context
-- opt.signcolumn = "yes"           -- str:  Show the sign column
opt.relativenumber = true


-- [[ Filetypes ]]
opt.encoding = 'utf8'            -- str:  String encoding to use
opt.fileencoding = 'utf8'        -- str:  File encoding to use
opt.clipboard:append {'unnamedplus'}  -- enable clipboard macos
-- vim.o.background = "dark"
-- vim.cmd([[colorscheme gruvbox]])

-- [[ Theme ]]
opt.syntax = "ON"                -- str:  Allow syntax highlighting
vim.opt.termguicolors = true  -- enable 256 color

-- [[ Search ]]
opt.hlsearch = true		         -- bool: Highlight search matches

-- [[ Whitespace ]]
opt.expandtab = true             -- bool: Use spaces instead of tabs
opt.shiftwidth = 4               -- num:  Size of an indent
opt.softtabstop = 4              -- num:  Number of spaces tabs count for in insert mode
opt.tabstop = 4                  -- num:  Number of spaces tabs count for
opt.wrap = true                 -- bool: No text wrapping into new line 
