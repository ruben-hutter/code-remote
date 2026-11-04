# code-remote

Provision a **userspace** nvim dev environment on a remote host over plain ssh —
no root needed (one exception: tmux), no dotfiles maintained on the remote, no
GitHub keys on the remote.

The remote stays dumb: everything is pushed **from your machine** via rsync and
installed by one idempotent script. Re-running `sync` reconciles config drift.

```
usage: bin/code-remote <ssh-alias>                 connect (default command)
       bin/code-remote <ssh-alias> bootstrap       tools + configs + plugins (full setup)
       bin/code-remote <ssh-alias> sync            re-push configs, re-apply transforms
       bin/code-remote <ssh-alias> connect [args]  ssh + tmux session picker (or attach)

Extra args after the command are forwarded to ssh (e.g. port forwards). The
legacy order (`bin/code-remote <command> <ssh-alias>`) still works.
```

`<ssh-alias>` is anything ssh understands — a `user@host` or an alias from
`~/.ssh/config`.

## What gets installed on the remote (all in `~/.local`)

| Tool | Version (pinned) | Source |
|---|---|---|
| nvim | 0.11.6 | official GitHub tarball → `~/.local/opt`, symlink in `~/.local/bin` |
| node | 22.22.2 | official tarball → `~/.local/opt`, bins symlinked |
| pi | latest | official `pi.dev/install.sh` |
| ripgrep | 15.2.0 | static musl binary |
| fd | 10.4.2 | static gnu binary |
| fzf | 0.74.5 | static binary |
| lazygit | 0.66.2 | static binary |
| bat | 0.26.1 | static musl binary |
| starship | 1.24.2 | static musl binary |
| jq | 1.8.1 | raw static binary |

Base prerequisites (git, curl, tar, unzip) are checked and only installed via
the system package manager if missing. **tmux** is the one tool userspace
cannot provide: if the host lacks it, the script tries `sudo` once and fails
with a clear message otherwise. Supports x86_64 and aarch64; Debian/Ubuntu,
Fedora, Arch, openSUSE for the base-package path.

Versions are pinned at the top of `remote/bootstrap.sh` — bump them there to
match your local machine.

## What gets synced and how it is adapted

Pushed via rsync (chosen over git-cloning `~/.cfg` so the remote never needs
your GitHub credentials):

- `~/.config/nvim/` → remote, then `nvim --headless "+Lazy! sync"` restores
  plugins pinned by `lazy-lock.json`
- `~/.tmux.conf` → remote, **then transformed**:
  - `set -g default-command /usr/bin/fish` deleted → panes run bash
    (`default-shell` was already bash)
  - every line referencing local `scripts/` (cht.sh bind, session-manager
    popup) deleted
  - walrus `set-hook` session-lifecycle lines deleted
  - options the host tmux doesn't support (probed live, e.g.
    `extended-keys-format`, removed in tmux ≥ 3.4) deleted
- `~/.config/tmux/plugins/` (catppuccin) → remote; tpm + `@plugin` list cloned
  fresh from GitHub
- `~/.agents/skills/` → remote, dereferenced (`-L`): your local symlink farm
  into `~/repos/skills` becomes real files, so the remote needs no repo
- `~/scripts/{tmux_session_manager.sh,wtree.sh}` → remote `~/scripts/` (list:
  `REMOTE_SCRIPTS` in `code-remote.conf`); the managed `.bashrc` block puts
  `~/scripts` on PATH so `wtree` works out of the box, and `connect` picks up
  the session picker
- `~/.bashrc` (+ `~/.bashrc-personal` with your aliases) → remote, **then
  transformed**: local-only bits deleted (`fastfetch`, direnv hook, plain
  starship/fzf evals — the managed block re-adds those with `2>/dev/null`
  fallbacks)
- `~/.config/starship.toml` → remote (your `.bashrc` already evals starship)
- pi **API keys** → remote, resolved locally: `auth.json` stores keys as
  `!pass show …` commands here; at sync time those commands run **on your
  machine** and the literal keys are merged into the remote's `auth.json`
  (remote-only credentials, e.g. OAuth logins done there, are preserved).
  No pass, no gpg on the remote.
- `~/.config/code-remote/passenv` (resolved from `PASS_ENVARS` in
  `code-remote.conf` via local `pass show`) → remote as a plain env file;
  the managed `.bashrc` block sources it, for providers whose auth reads the
  environment instead of auth.json (e.g. `OPENROUTER_API_KEY`)
- pi, config-level only: `settings.json`, `keybindings.json`, `AGENTS.md`,
  `trust.json`, `models-store.json`, `agents/`, `extensions/` — **excluding**
  `gondolin/` and `blink1.ts` (local-only; edit `PI_EXCLUDES` in
  `code-remote.conf`). `sessions/`, `install/`, `npm/`, `bin/` never leave the
  local machine; declared pi packages (e.g. the catppuccin theme) are
  reconciled on the remote by `pi update --extensions` during bootstrap.
- pi `auth.json`: **a remote keeps its own credentials**. It is only pushed
  when the remote has none (`SYNC_PI_AUTH=1` to opt in — existing remote
  credentials are still never overwritten).
- fish config: not synced — remote keeps bash, fed by your pushed `~/.bashrc`
  (see above). Two managed blocks are injected idempotently: a PATH block at
  line 1 (`~/.local/bin`, `~/scripts` — above the interactivity guard so
  non-interactive ssh works) and a `# >>> code-remote >>>` block at the end
  (synced API-key env file, starship, fzf).

## First run

```sh
bin/code-remote myserver bootstrap   # few minutes, mostly downloads
bin/code-remote myserver             # → tmux session, nvim ready (connect is the default)
```

Bootstrap is idempotent — re-run anytime to bump/reinstall tools.

## Known limits

- No C compiler toolchain provisioned (Mason packages that build from source
  will need distro build tools on that host).
- First `nvim` launch may still install a few Mason LSP servers lazily.
- **Clipboard**: tmux copy-mode `y` reaches your local clipboard on headless
  hosts via an OSC52 shim: bootstrap installs `~/.local/bin/wl-copy` when no
  real clipboard tool exists; tmux-yank pipes selections into it and
  `tmux load-buffer -w` forwards them to your terminal (needs an OSC52-capable
  terminal). nvim's own `y`/`yy` stays inside the remote nvim unless you add
  an OSC52 clipboard provider to the nvim config.
- **Notifications**: pi's notify extension calls `notify-send`; headless hosts
  have no notification daemon (and pi used to crash on the missing binary —
  the extension now probes once and skips silently). bootstrap installs a
  `~/.local/bin/notify-send` OSC shim there: notifications surface as a tmux
  status-line message in your session plus OSC 9/777 escapes to the terminal
  (desktop notification on your local machine if your terminal supports it;
  through tmux they need `allow-passthrough on`, otherwise tmux eats them).
- **API keys live on remotes in plaintext** (by design): resolved from your
  local pass at sync time and written into the remote's `auth.json` +
  `~/.config/code-remote/passenv`. Fine for your own VMs — skip syncing to a
  host you don't trust by removing the provider from `auth.json` and
  `PASS_ENVARS`.
- Distro nvim/node packages are never used — intentionally; LTS releases ship
  versions too old for current plugins.
