return {
    "folke/snacks.nvim",
    lazy = false,
    priority = 1000,
    opts = {
        -- only enable what we actually use: the notifier (replaces noice + nui + nvim-notify).
        -- more modules (dashboard, terminal, picker, lazygit, ...) can be opted into later.
        notifier = {
            enabled = true,
            -- keep the old nvim-notify feel
            timeout = 3000,
            style = "compact",
        },
        -- everything else off, so nothing changes behind our back
        animate = { enabled = false },
        bigfile = { enabled = false },
        dashboard = { enabled = false },
        indent = { enabled = false },
        input = { enabled = false },
        picker = { enabled = false },
        quickfile = { enabled = false },
        scope = { enabled = false },
        scroll = { enabled = false },
        statuscolumn = { enabled = false },
        terminal = { enabled = false },
        toggle = { enabled = false },
        words = { enabled = false },
        zen = { enabled = false },
    },
}
