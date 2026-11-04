local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable", -- latest stable release
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

-- lockfile is vendored in the repo, kept in sync with the live
-- ~/.config/nvim/lazy-lock.json. The config dir is a read-only nix store
-- symlink, so lazy can READ the lock but ':Lazy update' cannot persist a new
-- one — plugin updates happen by bumping the lockfile in this repo (same
-- philosophy as every other pin in the flake).
require("lazy").setup("buba.plugins", {
	lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",
})
