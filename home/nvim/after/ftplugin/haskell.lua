-- Haskell convention: 2-space indent, spaces only (indentation-sensitive syntax)
vim.opt_local.tabstop = 2
vim.opt_local.softtabstop = 2
vim.opt_local.shiftwidth = 2
vim.opt_local.expandtab = true

-- smartindent is C-oriented and fights Haskell's layout rules
vim.opt_local.smartindent = false

-- There is no Haskell 'indentexpr', so `=` can't compute indentation.
-- Route it through the LSP formatter instead (HLS + fourmolu). `gg=G`
-- and visual `=` now reformat via fourmolu, like gq does.
-- Generous timeout: HLS spawns the fourmolu binary per request.
vim.opt_local.formatexpr = 'v:lua.vim.lsp.formatexpr(#{timeout_ms:5000})'
vim.keymap.set({ 'n', 'x' }, '=', 'gq', { buffer = true, remap = true, desc = 'Format via HLS/fourmolu' })
