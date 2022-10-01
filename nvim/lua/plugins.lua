local packer_status, packer = pcall(require, 'packer')

-- Check and install packer automatically if it isn't installed.

local install_path = vim.fn.stdpath('data') .. '/site/pack/packer/start/packer.nvim'
local install_plugins = false

if not packer_status then
    print('Packer is not installed.')
    print('Installing Packer...')
    local packer_url = 'https://github.com/wbthomason/packer.nvim'
    vim.fn.system({'git', 'clone', '--depth', '1', packer_url, install_path})
    print('Done.')

    vim.cmd('packadd packer.nvim')
    install_plugins = true
end

vim.cmd [[packadd packer.nvim ]]

packer.startup(function(use)
    -- Packer can manage itself
    use 'wbthomason/packer.nvim'

    -- Mason + LSP servers
    use 'williamboman/mason.nvim'
    use 'williamboman/mason-lspconfig.nvim'
    use 'neovim/nvim-lspconfig'

    -- Rust Tools
    use 'simrat39/rust-tools.nvim'

    -- Theme
    use 'Mofiqul/dracula.nvim'
    use 'navarasu/onedark.nvim'
    use 'tanvirtin/monokai.nvim'
    use 'folke/tokyonight.nvim'

    -- Completion framework:
    use 'hrsh7th/nvim-cmp'

    -- LSP completion source:
    use 'hrsh7th/cmp-nvim-lsp'
    use 'onsails/lspkind.nvim'

    -- Useful completion sources:
    use 'hrsh7th/cmp-nvim-lua'
    use 'hrsh7th/cmp-nvim-lsp-signature-help'
    use 'hrsh7th/cmp-vsnip'
    use 'hrsh7th/cmp-path'
    use 'hrsh7th/cmp-buffer'
    use 'hrsh7th/vim-vsnip'

    -- Snippet 
    use ({"L3MON4D3/LuaSnip", tag = "v<CurrentMajor>.*"})
    -- Lualine
    use {
        'nvim-lualine/lualine.nvim',
        requires = { 'kyazdani42/nvim-web-devicons', opt = true }
    }

    -- telescope
    use {
        'nvim-telescope/telescope.nvim', tag = '0.1.0',
        requires = {
            {'nvim-lua/plenary.nvim'}
        }
    }
    use {
        'nvim-treesitter/nvim-treesitter',
        run = function() require('nvim-treesitter.install').update({ with_sync = true }) end,
    }
    -- telescope-file-browser
    use {'nvim-telescope/telescope-file-browser.nvim'}

   -- bufferline
    use {'akinsho/bufferline.nvim', tag = "v2.*", requires = 'kyazdani42/nvim-web-devicons'}

    -- Autotag and Autopair
    use 'windwp/nvim-autopairs'
    
    -- vim-fugitive: adds :G or :git on command
    use 'tpope/vim-fugitive'

    -- vim-markdown: supports folds and generating table of contents
    use 'preservim/vim-markdown'
    use 'iamcco/markdown-preview.nvim'

    if install_plugins then
        require('packer').sync()
    end
end)
