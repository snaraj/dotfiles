local lualine_status, lualine = pcall(require, 'lualine')
if not lualine_status then
    return
end

lualine.setup {
    options = {
        icons_enabled = true,
        theme = 'auto',
        section_separators = '',
    }
}
