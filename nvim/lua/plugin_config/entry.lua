-- Load Plugins
require('mason').setup()
require('mason-lspconfig').setup()
require('plugin_config.lualine')
require('plugin_config.bufferline')
require('plugin_config.lspconfig')
require('plugin_config.lspkind_cmp')
--require('plugin_config.treesitter')
require('plugin_config.telescope')
require('plugin_config.autopairs')
require('plugin_config.markdown_preview')
require('plugin_config.vim_floaterm')
require('plugin_config.lspsaga')
require('plugin_config.nvim_web_devicons')
require('plugin_config.null_ls')

-- Themes
-- Currently Using:
--require('plugin_config.dracula') 
require('plugin_config.onedark')
--require('plugin_config.gruvbox')
