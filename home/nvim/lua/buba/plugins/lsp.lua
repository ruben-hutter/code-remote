return {
	{'williamboman/mason.nvim', opts = {}},
	{'williamboman/mason-lspconfig.nvim', opts = {
		-- we enable servers explicitly in nvim-lspconfig's config below
		automatic_enable = false,
		ensure_installed = {
			-- NOTE: no 'hls' here — mason's HLS binary is ABI-incompatible with
			-- project GHCs. On nix machines HLS comes from nixpkgs
			-- (home/programs/haskell.nix), ABI-matched with pkgs.ghc and already
			-- on PATH; mason's bindist never enters the picture.
			'bashls',        -- bash
			'pyright',       -- python
			'rust_analyzer', -- rust
			'clangd',        -- c / c++
			'gopls',         -- go
			'lua_ls',        -- lua
			'ts_ls',         -- javascript / typescript
			'html',          -- html
			'cssls',         -- css
			'tinymist',      -- typst (was configured before)
			'nil_ls',        -- nix
		},
	}},

	{
		'neovim/nvim-lspconfig',
		config = function()
			-- nvim-cmp completion capabilities for every server
			vim.lsp.config('*', {
				capabilities = require('cmp_nvim_lsp').default_capabilities(),
			})

			-- On nix machines, haskell-language-server comes from nixpkgs
			-- (home/programs/haskell.nix), built against the same GHC as
			-- pkgs.ghc — the plain PATH binary is already ABI-correct. Nixpkgs
			-- HLS bundles its formatters, so fourmolu needs no PATH setup.
			vim.lsp.config('hls', {
				cmd = { 'haskell-language-server', '--lsp' },
				settings = {
					haskell = { formattingProvider = 'fourmolu' },
				},
			})

			-- make lua_ls aware of the `vim` global
			vim.lsp.config('lua_ls', {
				settings = {
					Lua = { diagnostics = { globals = { 'vim' } } },
				},
			})

			-- dartls: dart comes from the nix flake on PATH inside LiveTogether
			-- (direnv `use flake`), NOT from mason — mason's dart packaging is
			-- unreliable. lspconfig's dartls resolves `dart` from PATH.
			-- jdtls is configured by nvim-java; enabled here
			-- (keymaps live in after/plugin/lsp.lua)
			vim.lsp.enable({
				'hls', 'jdtls', 'bashls', 'pyright', 'rust_analyzer',
				'clangd', 'gopls', 'lua_ls', 'ts_ls', 'html', 'cssls',
				'tinymist', 'fish_lsp', 'nil_ls', 'dartls',
			})
		end,
	},
	{'hrsh7th/cmp-nvim-lsp'},
	{'hrsh7th/nvim-cmp'}
}
