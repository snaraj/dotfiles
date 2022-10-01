local markdown_preview_status, markdown_preview = pcall(require, 'markdown-preview')

if not markdown_preview_status then
    return
end

markdown_preview.setup {
    function() vim.fn["mkdp#util#install"]() end
}
