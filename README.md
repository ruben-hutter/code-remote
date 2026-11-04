# code-remote

Provision a **userspace** dev environment on a remote host over plain ssh —
powered by **nix + home-manager** (from [`~/repos/nixos-config`](../nixos-config)),
no dotfiles maintained on the remote, no GitHub keys on the remote.

The remote stays dumb: everything is pushed **from your machine** via rsync and
installed by one idempotent script. All remote tooling and shell config is
declared in `homeConfigurations.remote` in the nixos-config flake — code-remote
just syncs that repo, builds the home-manager generation on the host, and
activates it. The imperative residue (nix itself, pi, OSC shims) lives in
`remote/bootstrap.sh`.

```
usage: bin/code-remote <ssh-alias>                 connect (default command)
       bin/code-remote <ssh-alias> bootstrap       nix + home-manager + pi (full setup)
       bin/code-remote <ssh-alias> sync            re-push data, re-run home-manager
       bin/code-remote <ssh-alias> connect [args]  ssh + tmux session picker (or attach)
       bin/code-remote <ssh-alias> bootstrap-legacy  v1 bash bootstrap (pre-home-manager)

Extra args after the command are forwarded to ssh (e.g. port forwards). The
legacy order (`bin/code-remote <command> <ssh-alias>`) still works.
```

`<ssh-alias>` is anything ssh understands — a `user@host` or an alias from
`~/.ssh/config`.

## Architecture

```
local machine                     remote host
─────────────                     ───────────
~/repos/nixos-config/master  ───▶ ~/nixos-config        (rsync; flake + vendored configs)
~/.bashrc-personal            ───▶ ~/.bashrc-personal   (aliases — data, HM sources it)
~/.pi/agent config + keys     ───▶ ~/.pi/agent          (keys resolved from pass LOCALLY)
~/.config/code-remote/passenv ───▶ (same)                (PASS_ENVARS → plain env file)
~/.agents/skills              ───▶ ~/.agents/skills     (dereferenced)
remote/bootstrap.sh           ───▶ ~/.code-remote       (the imperative part)
                                      │
                                      ├─ nix (official installer, sudo for /nix)
                                      ├─ nix build ~/nixos-config#homeConfigurations.remote...
                                      ├─ generation activate  → ~/.nix-profile + home files
                                      ├─ pi (pi.dev install.sh → ~/.local)
                                      ├─ OSC52/OSC9 shims → ~/.local/bin (headless)
                                      └─ nvim "+Lazy! sync" (pins from vendored lazy-lock)
```

`NIXOS_CONFIG_DIR` in `code-remote.conf` points at the local checkout; the
remote writes `~/nixos-config/home/remote-user.nix` (its own username/home)
before activation — see `home/remote-default.nix` in the nixos-config repo.

## What the remote gets (declarative, from the flake)

One `home-manager` profile — `homeConfigurations.remote` (x86_64) /
`remote-aarch64`, headless and **bash-first** (no fish on remotes):

| Area | What |
|---|---|
| nvim | your full config, vendored in `~/repos/nixos-config/home/programs/nvim/`, store-symlinked; plugins pinned by the vendored `lazy-lock.json` |
| tmux | bash panes, C-a prefix, vi mode, catppuccin, yank (OSC52 on headless), resurrect/continuum, cht.sh + session-manager binds — from `~/scripts` |
| shell | bash + starship (+ ssh hostname/container modules), fzf, direnv hook, `~/.bashrc-personal` + `passenv` sourced |
| nix dev shells | direnv + `nix-command flakes`, nix-direnv caching — `use flake` in any `.envrc` (LiveTogether-style) just works after `direnv allow` |
| tools | neovim, nodejs, gcc, tree-sitter (Mason/treesitter), ripgrep, fd, fzf, jq, lazygit, bat, btop, htop, lf, wget/curl/tree/unzip/zip, `~/scripts` (pinned `github:ruben-hutter/scripts`) |
| git | same settings as desktop, **signing off** (no gpg keys on remotes) |

All versions come from the nixos-config `flake.lock` — bump with
`nix flake update` there, commit the lock. Tool churn on the remote is one
`code-remote <host> sync`.

## What gets synced (imperative data, from `code-remote.conf`)

- pi config-level files (`settings.json`, `keybindings.json`, `AGENTS.md`,
  `trust.json`, `models-store.json`, `agents/`, `extensions/` — **excluding**
  `gondolin/` and `blink1.ts`; `sessions/`, `install/`, `npm/`, `bin/` never
  leave the local machine). Declared pi packages (e.g. the catppuccin theme)
  are reconciled on the remote by `pi update --extensions` during bootstrap.
- pi **API keys**, resolved locally: `auth.json` stores keys as `!pass show …`
  commands here; at sync time those commands run **on your machine** and the
  literal keys are merged into the remote's `auth.json` (remote-only
  credentials, e.g. OAuth logins done there, are preserved). No pass, no gpg
  on the remote. A remote keeps its own credentials — `auth.json` is only
  pushed when the remote has none (`SYNC_PI_AUTH=1`).
- `~/.config/code-remote/passenv` — env vars from `PASS_ENVARS` (resolved via
  local `pass`), sourced by the HM bashrc; for providers that read the
  environment (e.g. `OPENROUTER_API_KEY`).
- `~/.bashrc-personal` (aliases) and `~/.agents/skills/` (dereferenced).
- The nixos-config repo itself (see Architecture above).

Not synced since v2: `~/.bashrc`, `~/.tmux.conf`, `~/.config/nvim/`,
`~/.config/starship.toml`, `~/scripts` — **home-manager owns those**; edit
them in the nixos-config repo, not on the remote.

## First run

```sh
bin/code-remote myserver bootstrap   # ~10 min: nix installer + closure downloads
bin/code-remote myserver             # → tmux session, nvim ready (connect is the default)
```

Bootstrap is idempotent — re-run anytime (nix is skipped if present, HM
activation only rewrites what moved).

**Migrating an existing v1 remote:** bootstrap moves the old `~/.bashrc`,
`~/.tmux.conf`, `~/.config/nvim`, `~/.config/starship.toml`,
`~/.config/nix/nix.conf`, `~/.profile*` aside as `*.pre-home-manager`, removes
the v1 pinned binaries from `~/.local/bin` and the tpm plugin clones. Escape
hatch: `bootstrap-legacy` restores the v1 flow (old script kept as
`remote/bootstrap-legacy.sh`).

## Known limits

- **sudo** is needed once, for nix (`/nix` + daemon users). tmux is no longer
  a root exception — it comes from the HM profile. Without sudo, bootstrap
  dies with a clear message (install nix manually, re-run).
- **SELinux-enforcing hosts** (Fedora/RHEL server): the nix daemon historically
  needs a policy tweak there. Ubuntu/Debian/Arch VMs are unaffected.
- **Non-interactive ssh** (`ssh host <cmd>`): the HM bashrc has an
  interactivity guard, so PATH comes from `.profile` — login shells and tmux
  panes are fine, but a bare non-login command only sees `~/.local/bin`.
  `code-remote connect` exports the full PATH explicitly. This is the one v1
  regression (v1 put a PATH block above the guard).
- Disk: the nix closure is ~1–2 GB (vs ~200 MB for v1's static binaries) —
  fine for normal VMs, tight below ~5 GB disks.
- **nvim plugin updates** on remotes: bump the vendored `lazy-lock.json` in
  `~/repos/nixos-config` (`:Lazy update` locally, copy the lock over,
  commit), then `code-remote <host> sync`. `:Lazy update` inside the remote
  nvim cannot persist (store config is read-only by design).
- First `nvim` launch / bootstrap may still fetch a few Mason LSP servers
  lazily (nodejs/gcc from the HM profile cover their build needs).
- **Clipboard**: tmux copy-mode `y` reaches your local clipboard on headless
  hosts via an OSC52 shim: bootstrap installs `~/.local/bin/wl-copy` when no
  real clipboard tool exists; tmux-yank pipes selections into it and
  `tmux load-buffer -w` forwards them to your terminal (needs an OSC52-capable
  terminal). nvim's own `y`/`yy` stays inside the remote nvim unless you add
  an OSC52 clipboard provider to the nvim config.
- **Notifications**: pi's notify extension calls `notify-send`; headless hosts
  have no notification daemon. bootstrap installs a `~/.local/bin/notify-send`
  OSC shim: notifications surface as a tmux status-line message in your
  session plus OSC 9/777 escapes to the terminal (desktop notification on your
  local machine if your terminal supports it; through tmux they need
  `allow-passthrough on`, otherwise tmux eats them).
- **API keys live on remotes in plaintext** (by design): resolved from your
  local pass at sync time and written into the remote's `auth.json` +
  `~/.config/code-remote/passenv`. Fine for your own VMs — skip syncing to a
  host you don't trust by removing the provider from `auth.json` and
  `PASS_ENVARS`.
