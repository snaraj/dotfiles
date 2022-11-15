local status, nord = pcall(require, 'nord')
if not status then
    return
end

vim.g.nord_contrast = false
vim.g.nord_borders = true
vim.g.nord_disable_background = true
vim.g.nord_italic = true
vim.g.nord_uniform_diff_background = true
vim.g.nord_bold = false

nord.set()

-- Bufferline support
local highlights = require("nord").bufferline.highlights({
    italic = true,
    bold = true,
})

require("bufferline").setup({
    options = {
        separator_style = "thin",
    },
    highlights = highlights,
})

-- Lualine
require('lualine').setup {
    options = {
        theme = 'nord'
    }
}
vim.cmd [[colorscheme nord]]
