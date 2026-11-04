vim.g.mapleader = " "
vim.g.maplocalleader = ","

vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)

vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

vim.keymap.set("n", "J", "mzJ`z")
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

vim.keymap.set("x", "<leader>p", [["_dP]])

vim.keymap.set({"n", "v"}, "<leader>y", [["+y]])
vim.keymap.set("n", "<leader>Y", [["+Y]])

vim.keymap.set("n", "<leader>d", "\"_d")
vim.keymap.set("v", "<leader>d", "\"_d")

vim.keymap.set("n", "Q", "<nop>")

vim.keymap.set("n", "<leader>f", function()
    vim.lsp.buf.format()
end)

vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]])

-- pi (AI agent) bridge; extension: ~/.pi/agent/extensions/nvim-bridge.ts
-- Visual maps use <Esc><Cmd>... so visual mode exits (committing the '< '>
-- marks) before the Lua callback reads them.
vim.keymap.set("n", "<leader>ie", function() require("buba.pi").explain() end, { desc = "pi: explain buffer" })
vim.keymap.set("v", "<leader>ie", "<Esc><Cmd>lua require('buba.pi').explain(true)<CR>", { desc = "pi: explain selection" })
vim.keymap.set("n", "<leader>ir", function() require("buba.pi").refactor() end, { desc = "pi: refactor buffer" })
vim.keymap.set("v", "<leader>ir", "<Esc><Cmd>lua require('buba.pi').refactor(true)<CR>", { desc = "pi: refactor selection" })
vim.keymap.set("n", "<leader>it", function() require("buba.pi").tests() end, { desc = "pi: write tests for buffer" })
vim.keymap.set("v", "<leader>it", "<Esc><Cmd>lua require('buba.pi').tests(true)<CR>", { desc = "pi: write tests for selection" })
vim.keymap.set("n", "<leader>ia", function() require("buba.pi").ask() end, { desc = "pi: ask about buffer" })
vim.keymap.set("v", "<leader>ia", "<Esc><Cmd>lua require('buba.pi').ask(true)<CR>", { desc = "pi: ask about selection" })
vim.keymap.set("n", "<leader>id", function() require("buba.pi").draft() end, { desc = "pi: paste buffer into pi editor" })
vim.keymap.set("v", "<leader>id", "<Esc><Cmd>lua require('buba.pi').draft(true)<CR>", { desc = "pi: paste selection into pi editor" })
