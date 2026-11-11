# code-remote

Provision a **userspace** dev environment on a remote host over plain ssh —
powered by **nix + home-manager**, no dotfiles maintained on the remote, no
GitHub SSH keys on the remote. **Self-contained**: the host clones exactly
**one** repo (this one) and builds its own environment; your machine only
ever sends credentials.

Everything declarative lives in this repo's `flake.nix` + `home/`: a headless,
bash-first home-manager profile. Desktop-shared configs come from two repos as
**flake inputs** — one canonical copy each, no duplication, pinned by
`flake.lock`: nvim from the [`~/.cfg`](https://github.com/ruben-hutter/.cfg)
live dotfiles, starship/lf/btop/htop headless variants from the
[`nixos-config`](https://github.com/ruben-hutter/nixos-config) desktop repo;
scripts and agent skills are flake inputs the same way (public,
fetched read-only into the nix store — no clones, no submodules).

```
usage: bin/code-remote <ssh-alias>    full setup: repo on host + nix/HM/pi + keys

One command. Idempotent — re-run to update the host and re-sync credentials.
Connect to the machine afterwards with plain ssh or your own tool (pxc).
```

`<ssh-alias>` is anything ssh understands — a `user@host` or an alias from
`~/.ssh/config` (`just bootstrap <alias>` is a wrapper).

## The flow (one command, from your machine)

```sh
# one-time: create the VM, then add a Host block to ~/.ssh/config
bin/code-remote myserver        # ~10 min: nix installer + closure downloads
```

That's it. `bin/code-remote` (or `just bootstrap myserver`):

1. **clones this repo on the host** (`~/code-remote`, public https — or
   fast-forwards it if it exists) — the flake must physically exist there to
   build
2. **pushes your data + config**: pi config files, `extensions/`, `agents/`,
   `~/.bashrc-personal`; and asks once whether to seed pi API keys on a host
   that has none (resolved locally from `pass`)
3. **runs `remote/bootstrap.sh` on the host** (plain ssh, interactive):
   1. seeds git identity into `~/.config/git/config` — the file HM will own,
      but ~10 min before it exists: without it, commits made during the
      bootstrap (or before its first run) get git's fallback identity
      (`Ubuntu <user@host>`)
   2. checks base tools (git, curl, tar, unzip; sudo-installs missing ones)
   3. installs **nix** (official installer; sudo needed once for `/nix`)
   4. stages your username into `home/remote-user.nix` (per-host identity;
      staged because a flake in a git tree is sourced from the git index)
   5. builds + activates the home-manager generation (`~/.nix-profile`, XDG
      configs, store-symlinked nvim/tmux/starship; `~/scripts` +
      `~/.agents/skills` come from the locked `scripts`/`skills` flake
      inputs). Pre-existing dotfiles (`~/.bashrc`, `~/.tmux.conf`,
      `~/.config/nvim`, …) are moved aside as `*.pre-home-manager` by the
      activation itself
   6. installs **pi** (official install.sh → `~/.pi/agent/bin`) and reconciles
      declared pi packages, fetches nvim plugins (pinned by the desktop
      `lazy-lock.json`), warms up nvim (headless scratch-file open so the
      one-time mason/treesitter/copilot installs finish during bootstrap,
      not during your first editor open — e.g. pi's ctrl+g), enables user
      linger (tmux survives ssh disconnects)
4. **resolves + pushes credentials**: pi API keys (local `!pass show …`
   commands run on your machine; literal keys land in the remote's
   `auth.json`) and the **gh token** (resolved from `pass show github/pat`,
   piped to `gh auth login --with-token` on the host — gh is a pure HTTPS
   API client, so the remote's SSH key does nothing for it)

Updates: re-run `bin/code-remote myserver` — repos fast-forward, nix skips
unchanged deps, HM only rewrites what moved, keys are re-resolved.

(The host-side script can also be driven by hand — ssh in, `git clone`,
`bash remote/bootstrap.sh` — useful from a machine without this checkout.)

## Architecture

```
local machine                     remote host (one git clone: this repo)
─────────────                     ───────────
github:ruben-hutter/code-remote ◀─ git clone → ~/code-remote (flake + bootstrap)

   its flake inputs (public, pinned by flake.lock, fetched into the nix store —
   no clones, no submodules):
   ├─ github:NixOS/nixpkgs + home-manager          → the HM generation
   ├─ github:ruben-hutter/nixos-config             → starship/lf/btop/htop configs (headless variants)
   ├─ github:ruben-hutter/.cfg                    → nvim config (the live fedora dotfiles)
   ├─ github:ruben-hutter/scripts → ~/scripts      (cht.sh, session manager, wtree)
   └─ github:ruben-hutter/skills  → ~/.agents/skills (store symlink)

sync + bootstrap (one command, from your machine):
~/.pi/agent config + keys     ───▶ ~/.pi/agent          (keys resolved from pass LOCALLY)
pass github/pat               ───▶ gh auth login        (token resolved LOCALLY, after bootstrap)
~/.bashrc-personal            ───▶ ~/.bashrc-personal   (aliases — data, HM sources it; `upal` rewritten dnf→apt for the host)

then ON the host, bootstrap.sh:
│
├─ nix (official installer, sudo for /nix)
├─ nix build ~/code-remote#homeConfigurations.remote...
├─ generation activate  → ~/.nix-profile + home files (conflicts → *.pre-home-manager)
├─ pi (pi.dev install.sh → ~/.pi/agent/bin)
└─ nvim "+Lazy! sync" (pins from lazy-lock.json) + user linger
```

The host writes `~/code-remote/home/remote-user.nix` (its own username/home)
before activation and stages it — a flake in a git tree is sourced from the
git index, so an untracked file would be invisible to nix. The shared desktop
configs come from two flake inputs: nvim from the `cfg` input (the live
`~/.cfg` fedora dotfiles — edit them there), starship/lf/btop/htop headless
variants from the nixos-config input. Pin newer states with
`nix flake update cfg` / `nix flake update nixos-config` here.

## What the remote gets (declarative, from the flake)

One `home-manager` profile — `homeConfigurations.remote` (x86_64) /
`remote-aarch64`, headless and **bash-first** (no fish on remotes):

| Area | What |
|---|---|
| nvim | your full config, from the `cfg` flake input (live `~/.cfg` dotfiles), store-symlinked; plugins pinned by its `lazy-lock.json` |
| tmux | bash panes, C-a prefix, vi mode, catppuccin, OSC52 yank on headless, resurrect/continuum, cht.sh + session-manager binds — from `~/scripts` |
| shell | bash + starship (+ ssh hostname/container modules), fzf, direnv hook, `~/.bashrc-personal` sourced; new interactive shells drop straight into the tmux session picker (`tm` — no-op inside tmux) |
| nix dev shells | direnv + `nix-command flakes`, nix-direnv caching — `use flake` in any `.envrc` (LiveTogether-style) just works after `direnv allow` |
| tools | neovim, nodejs, gcc, tree-sitter (Mason/treesitter), ripgrep, fd, fzf, jq, lazygit, gh, bat, btop, htop, lf, gopls, nil, wget/curl/tree/unzip/zip, `~/scripts` (locked `scripts` flake input) |
| git | same settings as desktop, **signing off** (no gpg keys on remotes) |
| local AI router | ollama (CPU build) as a systemd user service + a pulled `qwen2.5:1.5b-instruct` judge model — serves the local routing judge of the `zai/auto` pi extension (`glm-auto.ts`, synced from your machine's `extensions/`); without it the extension falls back to a remote judge call |

All versions come from this repo's `flake.lock` — bump with `nix flake update`
here, commit the lock, then re-run `bin/code-remote myserver`.

## What gets synced (imperative data)

Pushed by `bin/code-remote` before the bootstrap runs (re-pushed on every
run):

- pi config-level files (`settings.json`, `keybindings.json`, `AGENTS.md`,
  `trust.json`, `models-store.json`, `agents/`, `extensions/` — **excluding**
  `gondolin/` and `blink1.ts`; `sessions/`, `install/`, `npm/`, `bin/` never
  leave the local machine). Declared pi packages (e.g. the catppuccin theme)
  are reconciled on the remote by `pi update --extensions` during bootstrap.
- pi **API keys**, resolved locally: `auth.json` stores keys as `!pass show …`
  commands here; those commands run **on your machine** and the literal keys
  are merged into the remote's `auth.json` (remote-only credentials, e.g.
  OAuth logins done there, are preserved). No pass, no gpg on the remote.
  Seeding a fresh remote (which has no `auth.json` at all) happens only if
  you answer `y` at the prompt `bin/code-remote` asks up front; an existing
  one is always merge-updated.
- `~/.bashrc-personal` (aliases).

Pushed by `bin/code-remote` **after** the bootstrap (the tools must exist
first):

- **gh token**: resolved locally from `pass show github/pat` and pushed with
  `gh auth login --with-token`. Missing/empty pass entry → skipped with a
  warning (create it with `pass insert github/pat`; use a classic PAT with
  `repo`/`read:org` or a fine-grained one covering your repos). Re-running
  re-pushes, so token rotations propagate.

Not synced at all anymore: `~/.bashrc`, `~/.tmux.conf`, `~/.config/nvim/`,
`~/.config/starship.toml`, `~/scripts`, `~/.agents/skills`, `~/nixos-config` —
**home-manager owns the first five** (edit nvim in `~/.cfg`, the headless
variants in the nixos-config repo), the
last two are plain git clones on the host that the bootstrap script updates.

## First run

```sh
bin/code-remote myserver   # or: just bootstrap myserver — that's the whole flow
```

Bootstrap is idempotent — re-run any time (repos fast-forward, nix is skipped
if present, HM activation only rewrites what moved, keys re-resolve).

**Existing pre-home-manager remotes:** the HM activation moves old
`~/.bashrc`, `~/.tmux.conf`, `~/.config/nvim`, `~/.config/starship.toml`,
`~/.config/nix/nix.conf` aside as `*.pre-home-manager` (it would otherwise
abort on them) — the HM generation then owns everything.

## Known limits

- **Debian/Ubuntu only**: base tools install via apt; the nix multi-user
  install needs systemd. Fedora/Arch/container hosts are out of scope (the
  script dies with a clear message there).
- **sudo** is needed once, for nix (`/nix` + daemon users). Without sudo,
  bootstrap dies with a clear message (install nix manually, re-run).
- **Non-interactive ssh** (`ssh host <cmd>`): the HM bashrc has an
  interactivity guard, so PATH comes from `.profile` — login shells and tmux
  panes are fine, but a bare non-login command only sees `~/.local/bin`.
  Connect with plain ssh (interactive login) or your own tool.
- Disk: the nix closure is ~1–2 GB, plus ~1 GB for the ollama judge model
  (pulled once on first activation) — fine for normal VMs, tight below
  ~5 GB disks.
- **nvim plugin updates** on remotes: update locally (`:Lazy update`), commit
  the lock in `~/.cfg` (push), then in THIS repo run
  `nix flake update cfg`, commit the lock, and re-run
  `bin/code-remote myserver`. `:Lazy update` inside the remote nvim cannot
  persist (store config is read-only by design).
- **Java on remotes**: no JDK in the profile — nvim-java lazy-loads on
  `ft=java` and only then wants one. If you code Java on a remote, add a
  JDK to `home.packages` first.
- First `nvim` launch / bootstrap may still fetch a few Mason LSP servers
  lazily (nodejs/gcc from the HM profile cover their build needs).
- **Clipboard**: tmux copy-mode `y` (and mouse drag) reaches your local
  clipboard on headless hosts via OSC52 — a HM-managed
  `~/.local/bin/wl-copy` shim that pipes into `tmux load-buffer -w`, which
  forwards the buffer to your terminal (needs an OSC52-capable terminal;
  `Ms` override + `set-clipboard on` are configured in the remote tmux
  config). nvim's own `y`/`yy` stays inside the remote nvim unless you add
  an OSC52 clipboard provider to the nvim config.
- **API keys live on remotes in plaintext** (by design): resolved from your
  local pass and written into the remote's `auth.json` (pi) and
  `~/.config/gh/hosts.yml` (gh). Fine for your own VMs — decline the seed
  prompt on a host you don't trust, or remove the provider from `auth.json`.
