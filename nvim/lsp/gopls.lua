return {
    cmd = { "gopls" },
    filetypes = { "go", "gomod", "gowork", "gotmpl" },
    root_markers = { "go.mod", "go.work", ".git" },
    settings = {
        gopls = {
            gofumpt = true,
            staticcheck = true,
            usePlaceholders = true,
            completeUnimported = true,
            analyses = {
                unusedparams = true,
                unusedwrite = true,
                nilness = true,
            },
        },
    },
}
