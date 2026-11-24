if vim.g.loaded_lsp_profiles then
    return
end
vim.g.loaded_lsp_profiles = true

if vim.fn.has('nvim-0.12') == 0 then
    vim.notify('lsp-profiles.nvim needs Neovim 0.12 or newer', vim.log.levels.WARN)
    return
end

require('lsp-profiles')._install()
