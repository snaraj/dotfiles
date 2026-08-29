-- Minimal, plugin-free Neovim config.
-- LSP servers are configured in lsp/<name>.lua and enabled below.

-- Options
vim.opt.number = false
vim.opt.relativenumber = true
vim.opt.cursorline = true
vim.opt.signcolumn = "yes"
vim.opt.termguicolors = true

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smartindent = true

vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.splitright = true
vim.opt.splitbelow = true

vim.opt.undofile = true
vim.opt.swapfile = false
vim.opt.clipboard = "unnamedplus"
vim.opt.scrolloff = 6
vim.opt.updatetime = 300
vim.opt.completeopt = { "menuone", "noselect", "popup" }

-- Keymaps
vim.g.mapleader = " "
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })
vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Show diagnostic" })
vim.keymap.set("n", "<leader>f", vim.lsp.buf.format, { desc = "Format buffer" })
vim.keymap.set("n", "grn", vim.lsp.buf.rename, { desc = "Rename symbol" })
vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to definition" })

-- Diagnostics
vim.diagnostic.config({
    virtual_text = true,
    severity_sort = true,
})

-- LSP (servers installed via brew: gopls, lua-language-server, pyright)
vim.lsp.enable({ "gopls", "lua_ls", "pyright" })

-- Autocompletion: trigger the native LSP completion menu as you type.
-- <C-y> accepts, <C-n>/<C-p> navigate.
vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client:supports_method("textDocument/completion") then
            vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
        end
    end,
})

-- Go: organize imports and format on save (gopls)
vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = "*.go",
    callback = function()
        local params = vim.lsp.util.make_range_params(0, "utf-8")
        params.context = { only = { "source.organizeImports" } }
        local result = vim.lsp.buf_request_sync(0, "textDocument/codeAction", params, 1000)
        for _, res in pairs(result or {}) do
            for _, action in pairs(res.result or {}) do
                if action.edit then
                    vim.lsp.util.apply_workspace_edit(action.edit, "utf-8")
                end
            end
        end
        vim.lsp.buf.format({ timeout_ms = 1000 })
    end,
})
