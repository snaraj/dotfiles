local present, catppuccin = pcall(require, "catppuccin")
if not present then return end

catppuccin.setup {
    flavour = "mocha", -- latte, frappe, macchiato, mocha
    term_colors = true,
    transparent_background = false,
    dim_inactive = {
        enabled = true,
        shade = "red",
        percentage = 0.70,
    },
    integrations = {
        cmp = true,
        gitsigns = true,
        nvimtree = true,
        notify = false,
        mini = false,
        lsp_saga = true,
        mason = true,
        telescope = true,
        native_lsp = {
            enabled = true,
            virtual_text = {
                errors = { "italic" },
                hints = { "italic" },
                warnings = { "italic" },
                information = { "italic" },
            },
            underlines = {
                errors = { "underline" },
                hints = { "underline" },
                warnings = { "underline" },
                information = { "underline" },
            },
        },
    },
    styles = {
        comments = {},
        conditionals = {},
        loops = {},
        functions = {},
        keywords = {},
        strings = {},
        variables = {},
        numbers = {},
        booleans = {},
        properties = {},
        types = {},
    },
    color_overrides = {
        latte = {
            base = "#E1EEF5",
        },
        mocha = {
            base = "#000000",
        },
    },
    highlight_overrides = {
        latte = function(_)
            return {
                NvimTreeNormal = { bg = "#D1E5F0" },
            }
        end,
        mocha = function(mocha)
            return {
                TabLineSel = { bg = mocha.pink },
                NvimTreeNormal = { bg = mocha.none },
                CmpBorder = { fg = mocha.surface2 },
            }
        end,
    },
}

-- treesitter fix
require("nvim-treesitter.configs").setup {
    highlight = {
        enable = true,
        additional_vim_regex_highlighting = false
    },
}

-- Bufferline
require("bufferline").setup {
    highlights = require("catppuccin.groups.integrations.bufferline").get()
}

-- Lspsaga integration
require("lspsaga").init_lsp_saga {
    custom_kind = require("catppuccin.groups.integrations.lsp_saga").custom_kind(),
}

-- Lunaline integration
require('lualine').setup {
    options = {
        icons_enabled = true,
        theme = "catppuccin"
    }
}

vim.cmd.colorscheme "catppuccin"
