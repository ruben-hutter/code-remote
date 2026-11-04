return {
    "iamcco/markdown-preview.nvim",
    cmd = { "MarkdownPreviewToggle", "MarkdownPreview", "MarkdownPreviewStop" },
    build = "cd app && npm install",
    init = function()
        vim.g.mkdp_filetypes = { "markdown" }
        vim.g.mkdp_page_title = "${name}.md"
        vim.cmd([[
            function! OpenMarkdownPreview(url)
                call jobstart(['brave-browser', '--new-window', a:url])
            endfunction
        ]])
        vim.g.mkdp_browserfunc = "OpenMarkdownPreview"
    end,
    ft = { "markdown" },
}
