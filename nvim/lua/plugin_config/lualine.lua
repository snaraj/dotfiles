local lualine_status, lualine = pcall(require, 'lualine')
if not lualine_status then
    return
end

-- local gruvbox = require'lualine.themes.gruvbox_dark'

lualine.setup {
    options = {
        icons_enabled = true,
        theme = require'lualine.themes.onedark',
        section_separators = '',
    }
}
