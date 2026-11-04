return {
  'nvim-java/nvim-java',
  config = function()
    -- use the system JDK (Temurin 25); avoid nvim-java's own JDK download
    require('java').setup({ jdk = { auto_install = false } })
  end,
  -- nvim-java v4 bundles java-core/test/dap/async itself; the old external
  -- plugins are stale and their java-core copy shadows the bundled one
  -- (caused: attempt to call field 'get_arch')
  dependencies = {
    'MunifTanjim/nui.nvim',
    'neovim/nvim-lspconfig',
    'mfussenegger/nvim-dap',
  },
}
