local lspkind = require('lspkind')
local cmp = require 'cmp'

cmp.setup({
    -- Enable LSP snippets
    snippet = {
        expand = function(args)
            -- vim.fn["vsnip#anonymous"](args.body) -- For 'vsnip' users.
            require('luasnip').lsp_expand(args.body) -- For `luasnip` users.
        end,
    },
    mapping = {
        -- Add tab support
        ['<S-Tab>'] = cmp.mapping.select_prev_item(),
        ['<Tab>'] = cmp.mapping.select_next_item(),
        ['<C-S-f>'] = cmp.mapping.scroll_docs(-4),
        ['<C-f>'] = cmp.mapping.scroll_docs(4),
        ['<C-Space>'] = cmp.mapping.complete(),
        ['<C-e>'] = cmp.mapping.close(),
        ['<CR>'] = cmp.mapping.confirm { select = false }
    },
    -- Installed sources:
    sources = {
        { name = 'path' }, -- file paths
        { name = 'nvim_lsp', keyword_length = 1, priority = 10 }, -- from language server
        { name = 'luasnip', keyword_length = 1, priority = 7 }, -- for lua users
        { name = 'nvim_lsp_signature_help', priority = 8 }, -- display function signatures with current parameter emphasized
        { name = 'nvim_lua', keyword_length = 1, priority = 8 }, -- complete neovim's Lua runtime API such vim.lsp.*
        { name = 'buffer', keyword_length = 1, priority = 5 }, -- source current buffer
        -- { name = 'vsnip', keyword_length = 2 },         -- nvim-cmp source for vim-vsnip
        { name = 'calc' }, -- source for math calculation
    },
    window = {
        completion = {
            cmp.config.window.bordered(),
            col_offset = 3,
            side_padding = 1,
        },
        documentation = cmp.config.window.bordered(),

    },
    formatting = {
        fields = { 'menu', 'abbr', 'kind' },
        format = lspkind.cmp_format({
            mode = 'symbol_text', -- show only symbol annotations
            maxwidth = 60, -- prevent the popup from showing more than provided characters
            -- The function below will be called before any actual modifications from lspkind:
            before = function(entry, vim_item)
                local menu_icon = {
                    nvim_lsp = '⇴',
                    luasnip = '⋗ ',
                    buffer = 'Ω ',
                    path = '🖫 ',
                }
                vim_item.menu = menu_icon[entry.source.name]
                return vim_item
            end,
        })

    },
    preselect = cmp.PreselectMode.None,
    confirmation = {
        get_commit_characters = function(commit_characters)
            return {}
        end
    },
})
