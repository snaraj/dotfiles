local treesitter_status, treesitter = pcall(require, 'nvim-treesitter.configs')
if not treesitter_status then
    return
end

treesitter.setup {
    auto_install = true,
    highlight = {
        enable = true,
        additional_vim_regex_highlighting=true,
    },
    ident = { enable = true },
    rainbow = {
        enable = true,
        extended_mode = true,
        max_file_lines = nil,
    },
    ensure_installed = {
        "rust",
        "go",
        "sql",
        "python",
        "markdown",
        "graphql",
        "toml",
        "json",
        "yaml",
        "css",
        "html",
        "lua",
        "dockerfile",
        "dot",
        "d",
        "gitignore",
        "gomod",
        "graphql",
        "json5",
    },
}
