# Task: code-remote v2 — home-manager + nix based provisioning

Decisions (user-confirmed):
- Remote home profile: **bash-first** (v1 philosophy), no fish on remotes.
- `bootstrap` becomes the new HM-based flow; old script stays as `bootstrap-legacy`.
- Base: ~/repos/nixos-config (public scripts input; remotes may fetch it from github).

## Phase 1 — nixos-config (wtree, branch feat/remote-home)
- [x] Survey drift (nvim diverged most: pi.lua, snacks.lua, ftplugin/, nil_ls, lsp map
      helper; starship vendored copy is AHEAD w/ hostname+container — keep; git in sync)
- [x] Commit user's staged packages.nix WIP in master first (small tweak, their AGENTS.md allows)
- [x] Port live ~/.config/nvim → home/programs/nvim (exclude .un~), re-apply lazy.lua
      lockfile patch + keep nix hls-ABI notes in lsp.lua
- [x] home/remote-default.nix: headless bash-first profile (bash, tmux w/ OSC52 yank +
      no walrus, nvim shared, starship, git(gpgSign off), bat/fzf/jq/fd/rg/lazygit/
      btop/htop/lf, direnv+nix flakes conf, nodejs+gcc+unzip+tree-sitter for nvim/pi)
- [x] flake.nix: homeConfigurations."<system>".remote (x86_64+aarch64) via
      homeManagerConfiguration; username/homeDirectory from optional home/remote-user.nix
- [x] Validate: nix build activationPackage locally (Fedora + nix) — build only, never activate

## Phase 2 — code-remote (direct on main, no .bare)
- [x] Read bin/code-remote (sync/auth machinery) before rewiring
- [x] bootstrap v2: ensure_base → install_nix (NIX_CONFIG env for flakes, NOT nix.conf —
      HM owns that file after switch) → rsync nixos-config → write remote-user.nix →
      nix build activationPackage → activate → migration: move aside pre-HM
      ~/.bashrc/~/.tmux.conf/~/.config/nvim/~/.config/starship.toml/~/.config/nix/nix.conf
      → install_pi (node from HM profile) → passenv/auth (reuse v1) → shims → lazy sync
- [x] bin/code-remote dispatch: bootstrap→v2, bootstrap-legacy→old script
- [x] README + TESTING updates

## Gotchas
- HM aborts on conflicting non-store files → migration step must move them aside first
- tmux reads ~/.tmux.conf FIRST — must move it aside or HM's XDG tmux.conf is shadowed
- homeConfigurations attr not system-namespaced in HM convention → use "<system>.remote"
  and pick via uname -m
- vendor sync (live configs → nixos-config) stays manual for now; note in README
