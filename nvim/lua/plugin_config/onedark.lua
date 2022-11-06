local onedark_status, onedark = pcall(require, 'onedark')
if not onedark_status then
    return
end

onedark.setup {

    style = 'darker',
    transparent = true,
    term_colors = true,
    ending_tildes = false,
    cmp_itemkind_reverse = false,

    toggle_style_key = nil,
    toggle_style_list = { 'dark', 'darker', 'cool', 'deep', 'warm', 'warmer', 'light' },

    code_style = {
        comments = 'none',
        keywords = 'none',
        functions = 'none',
        strings = 'none',
        variables = 'none'
    },

    lualine = {
        transparent = true,
    },

    colors = {},
    highlights = {},

    diagnostics = {
        darker = true,
        undercurl = true,
        background = true,
    },
}

require('lualine').setup {
    options = {
        theme = 'onedark'
    }
}

onedark.load()
vim.cmd("colorscheme onedark")
