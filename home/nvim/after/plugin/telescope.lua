local builtin = require('telescope.builtin')

-- File Pickers
vim.keymap.set('n', '<leader>pf', builtin.find_files, { desc = 'Find files' })
vim.keymap.set('n', '<leader>pg', builtin.git_files, { desc = 'Git files' })
vim.keymap.set('n', '<leader>ps', builtin.grep_string, { desc = 'Grep string' })
vim.keymap.set('n', '<leader>pl', builtin.live_grep, { desc = 'Live grep' })

-- Neovim Pickers
vim.keymap.set('n', '<leader>pb', builtin.buffers, { desc = 'Buffers' })
vim.keymap.set('n', '<leader>ph', builtin.help_tags, { desc = 'Help tags' })
vim.keymap.set('n', '<leader>pd', builtin.diagnostics, { desc = 'Document diagnostics' })

-- LSP Pickers
vim.keymap.set('n', '<leader>pr', builtin.lsp_references, { desc = 'LSP references' })

-- Treesitter Pickers
vim.keymap.set('n', '<leader>pt', builtin.treesitter, { desc = 'Treesitter' })

-- Other Pickers
--vim.keymap.set('n', '<leader>pc', builtin.commands, { desc = 'Commands' })
--vim.keymap.set('n', '<leader>pk', builtin.keymaps, { desc = 'Keymaps' })
vim.keymap.set('n', '<leader>pm', builtin.man_pages, { desc = 'Man pages' })
vim.keymap.set('n', '<leader>pp', builtin.current_buffer_fuzzy_find, { desc = 'Current buffer fuzzy find' })
