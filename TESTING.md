# Testing code-remote by hand

The full setup is one command — but testing it means verifying each layer it
creates. This runbook walks the whole path on a fresh VM. Generic host docs:
see README. Commands below assume the local repo root and an ssh alias
(`proxcode` here).

## 0. Baseline: a fresh VM

What the VM needs before you start:

- ssh access with your key (`ssh proxcode whoami` must work)
- **sudo** — nix needs it once (`/nix` + daemon users); everything else
  installs into `~/.nix-profile` and `~/.local` with no root
- git / curl / tar / unzip — bootstrap checks these and sudo-installs missing
  ones

New VM with a new IP? Update `HostName` under the `Host proxcode` block in
`~/.ssh/config`, clear stale keys (`ssh-keygen -R <ip>`), reconnect with
`StrictHostKeyChecking=accept-new`, and **verify the fingerprint out-of-band**
(on the proxmox console: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`)
before trusting it.

Baseline check — home should be clean:

```sh
ssh proxcode 'for t in nix tmux git curl pi; do command -v $t || echo "no $t"; done'
```

## 1. The one command

```sh
bin/code-remote proxcode        # or: just bootstrap proxcode
```

What happens, in order:

1. **clone on the host** — `git clone https://github.com/ruben-hutter/code-remote
   ~/code-remote` (or `git pull --ff-only` if it exists)
2. **push data + config from your machine** — pi config files
   (`settings.json`, `keybindings.json`, `AGENTS.md`, `trust.json`,
   `models-store.json`), `extensions/` (minus `gondolin/`, `blink1.ts`),
   `agents/`, `~/.bashrc-personal`. Happens BEFORE the bootstrap so
   `pi update --extensions` reconciles against the current `settings.json`.
   Also asks here: `seed pi API keys …? [y/N]` (only for hosts with no
   `auth.json` yet).
3. **run `remote/bootstrap.sh` on the host** (plain interactive ssh), which:
   - checks base tools (git, curl, tar, unzip; sudo-installs missing ones)
   - installs nix (official installer, sudo for `/nix`)
   - stages `home/remote-user.nix` in the clone (the host's own uid/home —
     staged because a flake in a git tree is sourced from the git index)
   - `nix build ~/code-remote#homeConfigurations.remote.activationPackage`
     (x86_64; `remote-aarch64` on arm; `scripts` + `skills` flake inputs
     fetched from GitHub, pinned by `flake.lock`) and activates →
     `~/.nix-profile`, XDG configs, store-symlinked nvim/tmux/starship/skills;
     conflicting pre-HM dotfiles are moved aside as `*.pre-home-manager` by
     the activation itself (`HOME_MANAGER_BACKUP_EXT`)
   - installs pi + `pi update --extensions` (reconciles declared packages)
   - `nvim --headless "+Lazy! sync"` (pins from the vendored lazy-lock)
   - enables user linger (tmux ≥ 3.8 spawns panes as systemd user scopes)
4. **push pi keys from your machine** — `!pass show …` commands in local
   `auth.json` are executed locally, literal keys merged into the remote's
   `auth.json` (remote-only credentials preserved; a fresh remote is seeded
   only if you answered `y` to the seed prompt in step 2).
   **Never pushed:** raw local `auth.json` (`!pass` can't work remotely),
   `sessions/`, `install/`, `npm/`, `bin/`.
   **Owned by the HM generation / flake inputs instead:** `~/scripts`,
   `~/.agents/skills`, `~/.config/nvim`, `~/.bashrc`, `~/.tmux.conf`,
   `~/.config/starship.toml`.

It is idempotent — re-run any time; repos fast-forward, nix is skipped when
present, HM activation only rewrites what moved, keys re-resolve.

## 2. Verify each layer by hand

```sh
ssh proxcode
```

**nix + home-manager** (the foundation):

```sh
nix --version                                     # nix (Nix) 2.35.4 (bootstrap-pinned)
readlink ~/.nix-profile                           # …-home-manager-generation (or -<N>-link)
home-manager generations 2>/dev/null || true      # bare activate skips this; fine
grep experimental-features ~/.config/nix/nix.conf # = nix-command flakes
ls -la ~/.config/tmux/tmux.conf ~/.config/nvim ~/.config/starship.toml   # store symlinks
```

**Tools** (paths + versions — all from the HM profile, versions = flake.lock):

```sh
for t in nvim tmux node rg fd fzf lazygit bat starship jq direnv gcc; do
  printf '%-9s' "$t"; command -v "$t" && "$t" --version 2>/dev/null | head -1
done
echo $PATH | tr ':' '\n' | grep -nE 'nix-profile|\.local/bin'   # profile + local bins
```

**nvim** — store-owned config + plugins:

```sh
ls -la ~/.config/nvim              # symlink into /nix/store (hm_nvim)
ls ~/.local/share/nvim/lazy | wc -l    # plugin count > 0 (Lazy! sync ran)
nvim --headless '+checkhealth' +qa     # or just open nvim and :checkhealth
```

Config edits: change the desktop copy in `~/repos/nixos-config` (commit +
push), then run `bin/vendor` in a code-remote checkout (mirrors nvim + assets
into `home/`), commit + push, then `bin/code-remote proxcode`. `:Lazy update`
in the remote nvim cannot persist — the store config is read-only.

**bash** — HM-generated, with synced data sourced:

```sh
head -3 ~/.bashrc                          # HM header (read-only store symlink)
grep -n 'bashrc-personal' ~/.bashrc        # sourced in initExtra
grep -n 'direnv hook\|starship init\|fzf --bash' ~/.bashrc   # hooks wired by HM
bash -ic 'alias ll'                        # aliases from .bashrc-personal work
```

**tmux** — HM-owned config, OSC52 yank:

```sh
ls ~/.config/tmux/tmux.conf                # store symlink; NO ~/.tmux.conf (moved aside)
tmux -L t -f /dev/null new-session -d && tmux -L t source-file ~/.config/tmux/tmux.conf && echo ok
tmux -L t kill-server
ls ~/scripts/tmux_session_manager.sh       # from the scripts flake input (pinned)
```

Clipboard (inside the tmux session): `C-a [`, select, `y` — `y` and mouse-drag
pipe through the OSC52 shim (`copy-pipe "tmux load-buffer -w -"`, configured
in the remote tmux config; the tmux-yank plugin is NOT used — its auto-detect
needs $WAYLAND_DISPLAY, absent on headless hosts). Paste on your **local**
machine; tmux sends the buffer as OSC52 (`terminal-overrides Ms` +
`set-clipboard on` are configured). To verify remotely without a human
terminal, attach with a pty (`script -qec "TERM=xterm-256color tmux attach"`)
and grep the capture for `]52;;<b64>` (canonical 3-field OSC52 — tmux emits
an empty selection param; a `52;c;<b64>` grep gives false negatives).
If paste still fails, it's your LOCAL terminal dropping OSC52 — pi
notifications (notify-send) are intentionally not installed on remotes.

**pi** — binaries, config, packages, credentials:

```sh
pi --version
pi list                                # catppuccin-pi-theme installed
grep -c '"!pass' ~/.pi/agent/auth.json # 0 — keys are literal on remotes
ls ~/.agents/skills | wc -l            # skills = store symlink (flake input)
```

**nix dev shells** (LiveTogether-style):

```sh
cd ~/some-flake-repo && echo 'use flake' > .envrc && direnv allow   # dev shell activates
bash -ic 'command -v nix'         # ~/.nix-profile/bin/nix
```

## 3. Update paths

```sh
bin/code-remote proxcode          # re-run: updates the host + re-syncs keys/config
# bump tools: nix flake update here, commit + push, then re-run
# bump nvim plugins: update desktop copy in ~/repos/nixos-config (commit+push),
#   run bin/vendor here (mirrors into home/nvim/), commit + push, re-run
```

## Known rough edges (see README Known limits)

- `ssh host <cmd>` non-interactive: PATH = `~/.local/bin` only (HM bashrc
  interactivity guard); login shells + tmux panes are fine.
- The nix closure needs ~1–2 GB disk on the remote.
