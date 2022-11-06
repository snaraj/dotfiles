local status, null_ls = pcall(require, "null-ls")
if not status then
    return
end

null_ls.setup {
    sources = {
        null_ls.builtins.formatting.prettierd.with({
            extra_filetypes = {
                "toml",
                "shell",
                "bash",
                "rust",
                "go",
                "json",
                "yaml",
                "markdown",
                "python",
            },
        }),
        null_ls.builtins.diagnostics.eslint,
        null_ls.builtins.completion.spell,
    },

    on_attach = function(client, bufnr)
        if client.server_capabilities.documentFormattingProvider then
            vim.cmd("nnoremap <silent><buffer> <leader>f :lua vim.lsp.buf.formatting()<CR>")

            -- format on save
            vim.cmd("autocmd BufWritePost <buffer> lua vim.lsp.buf.format { async = true}")
        end

        if client.server_capabilities.documentRangeFormattingProvider then
            vim.cmd("xnoremap <silent><buffer> <leader>f :lua vim.lsp.buf.range_formatting({})<CR>")
        end
    end,
}

local status, prettier = pcall(require, "prettier")
if (not status) then return end

prettier.setup {
    ["null-ls"] = {
        condition = function()
            return prettier.config_exists({
                check_package_json = false,
            })
        end,
        runtime_condition = function(params)
            return true
        end,
        timeout = 5000,
    }
}
