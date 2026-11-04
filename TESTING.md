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
bin/code-remote proxcode bootstrap
```

What happens, in order:

1. **push_data_configs** — rsync from your machine: `~/.bashrc-personal`,
   pi config files (`settings.json`, `keybindings.json`, `AGENTS.md`,
   `trust.json`, `models-store.json`), `extensions/` (minus `gondolin/`,
   `blink1.ts`), `agents/`, `~/.agents/skills/` (dereferenced via `-L`),
   `~/.config/code-remote/passenv` (from `PASS_ENVARS`, resolved locally via
   pass), pi keys resolved into remote `auth.json` (`!pass show …` commands
   executed locally, literal keys written).
   **Never synced:** `sessions/`, `install/`, `npm/`, `bin/`, your local
   `auth.json` (the remote gets resolved keys via the merge above; it keeps
   its own credentials otherwise, `SYNC_PI_AUTH=1` only seeds an empty one).
2. **push_nixos_config** — `~/repos/nixos-config/master/` → `~/nixos-config/`
   (minus `.git`, `result*`, `home/remote-user.nix`), then writes
   `home/remote-user.nix` on the host (its own uid/home).
3. Upload `remote/bootstrap.sh` → `~/.code-remote/`
4. Run it remotely (`all` mode): base check → nix install (sudo, daemon) →
   pre-HM files moved aside (`*.pre-home-manager`) → `nix build
   ~/nixos-config#homeConfigurations.remote.activationPackage` → activate →
   pi + `pi update --extensions` → OSC shims → `nvim --headless "+Lazy! sync"`.

It is idempotent — re-run any time; nix is skipped when present and HM
activation only rewrites what moved.

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

Config edits happen in `~/repos/nixos-config/home/programs/nvim/` (local), then
`code-remote proxcode sync` re-vendors + re-activates. `:Lazy update` in the
remote nvim cannot persist — the store config is read-only.

**bash** — HM-generated, with synced data sourced:

```sh
head -3 ~/.bashrc                          # HM header (read-only store symlink)
grep -n 'bashrc-personal\|passenv' ~/.bashrc   # both sourced in initExtra
grep -n 'direnv hook\|starship init\|fzf --bash' ~/.bashrc   # hooks wired by HM
bash -ic 'alias ll'                        # aliases from .bashrc-personal work
bash -ic 'echo ${OPENROUTER_API_KEY:+set}' # set (passenv file)
```

**tmux** — HM-owned config, OSC52 yank:

```sh
ls ~/.config/tmux/tmux.conf                # store symlink; NO ~/.tmux.conf (moved aside)
tmux -L t -f /dev/null new-session -d && tmux -L t source-file ~/.config/tmux/tmux.conf && echo ok
tmux -L t kill-server
ls ~/scripts/tmux_session_manager.sh       # from the scripts flake input (pinned)
```

Clipboard + notifications (inside the tmux session): `C-a [`, select, `y`,
paste on your **local** machine (OSC52 shim → terminal). `notify-send test`
→ tmux status line + OSC 9/777, never a crash.

**pi** — binaries, config, packages, credentials:

```sh
pi --version
pi list                                # catppuccin-pi-theme installed
grep -c '"!pass' ~/.pi/agent/auth.json # 0 — keys are literal on remotes
ls ~/.agents/skills | wc -l            # skills synced (35-ish)
```

**nix dev shells** (LiveTogether-style):

```sh
cd ~/some-flake-repo && echo 'use flake' > .envrc && direnv allow   # dev shell activates
bash -ic 'command -v nix'         # ~/.nix-profile/bin/nix
```

**migrated v1 remote?** Also check the setaside files survived:

```sh
ls ~/.bashrc.pre-home-manager ~/.tmux.conf.pre-home-manager 2>/dev/null   # old configs
ls ~/.config/tmux/plugins 2>/dev/null                                     # gone (tpm removed)
```

## 3. Update paths

```sh
bin/code-remote proxcode sync          # re-push data + flake, re-activate HM
# bump tools: in ~/repos/nixos-config: nix flake update && commit lock, then sync
# bump nvim plugins: update locally, copy ~/.config/nvim/lazy-lock.json into
#   ~/repos/nixos-config/home/programs/nvim/, commit, then sync
# v1 bash flow (escape hatch): bin/code-remote proxcode bootstrap-legacy
```

## Known rough edges (see README Known limits)

- `ssh host <cmd>` non-interactive: PATH = `~/.local/bin` only (HM bashrc
  interactivity guard); login shells + tmux panes + `connect` are fine.
- SELinux-enforcing hosts may need a nix daemon policy tweak.
- The nix closure needs ~1–2 GB disk on the remote.
