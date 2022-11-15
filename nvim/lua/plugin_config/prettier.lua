local status, prettier = pcall(require, 'prettier')
if not status then
    return
end

prettier.setup {
    bin = 'prettierd',
    filetypes = {
        'lua',
        'html',
        'yaml',
        'cfg',
        'toml',
        'python',
        'rust',
        'go',
        'markdown',
        'json'
    }
}
