local mason_status, mason = pcall(require, "mason")

if not mason_status then
    return end

local lspconfig_status, lspconfig = pcall(require, "mason-lspconfig")

if not lspconfig_status then
    return end

mason.setup({
    ui = {
        icons = {
            package_installed = "✓",
            package_pending = "➜",
            package_uninstalled = "✗"
        }
    }
})

lspconfig.setup {
    ensure_installed = {"sumneko_lua"}
}
