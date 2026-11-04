-- LSP keymaps + completion
-- (server installation/enabling lives in lua/buba/plugins/lsp.lua)

vim.api.nvim_create_autocmd('LspAttach', {
	callback = function(event)
		local function map(lhs, rhs, desc)
			vim.keymap.set('n', lhs, rhs, { buffer = event.buf, remap = false, desc = 'LSP: ' .. desc })
		end

		map('gd', vim.lsp.buf.definition, 'Goto definition')
		map('K', vim.lsp.buf.hover, 'Hover')
		map('<leader>vws', vim.lsp.buf.workspace_symbol, 'Workspace symbols')
		map('<leader>vd', vim.diagnostic.open_float, 'Diagnostic float')
		map(']d', function() vim.diagnostic.jump({ count = 1, float = true }) end, 'Next diagnostic')
		map('[d', function() vim.diagnostic.jump({ count = -1, float = true }) end, 'Prev diagnostic')
		map('<leader>vca', vim.lsp.buf.code_action, 'Code action')
		map('<leader>vrr', vim.lsp.buf.references, 'References')
		map('<leader>vrn', vim.lsp.buf.rename, 'Rename')
		vim.keymap.set('i', '<C-h>', vim.lsp.buf.signature_help,
			{ buffer = event.buf, remap = false, desc = 'LSP: Signature help' })
	end,
})

-- Set up completion
local cmp = require('cmp')
local cmp_select = { behavior = cmp.SelectBehavior.Select }

cmp.setup({
	sources = {
		{ name = 'path' },
		{ name = 'nvim_lsp' },
	},
	mapping = cmp.mapping.preset.insert({
		['<C-p>'] = cmp.mapping.select_prev_item(cmp_select),
		['<C-n>'] = cmp.mapping.select_next_item(cmp_select),
		['<C-y>'] = cmp.mapping.confirm({ select = true }),
		['<C-Space>'] = cmp.mapping.complete(),
	}),
})
