local status, nvim_tree = pcall(require, 'nvim-tree')
local keymap = vim.keymap.set
if not status then
    return
end

nvim_tree.setup {
    sort_by = "case_sensitive",
    view = {
        adaptive_size = true,
        mappings = {
            list = {
                { key = "u", action = "dir_up" },
            },
        },
    },
    renderer = {
        group_empty = true,
    },
    filters = {
        dotfiles = true,
    },
}

-- disable netrw at the very start of your init.lua (strongly advised)
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- set termguicolors to enable highlight groups
vim.opt.termguicolors = true

-- usage
keymap("n", ",<space>", "<cmd>NvimTreeToggle<CR>", { silent = true })

-- empty setup using defaults
require("nvim-tree").setup()
