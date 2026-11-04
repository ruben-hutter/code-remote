# Testing code-remote by hand

The full setup is one command — but testing it means verifying each layer it
creates. This runbook walks the whole path on a fresh VM. Generic host docs:
see README. Commands below assume the local repo root and an ssh alias
(`proxcode` here).

## 0. Baseline: a fresh VM

What the VM needs before you start:

- ssh access with your key (`ssh proxcode whoami` must work)
- **tmux** (userspace can't provide it) — or sudo rights so bootstrap can
  `apt install tmux` for you
- git / curl / tar / unzip — bootstrap checks these and sudo-installs missing
  ones; everything else installs into `~/.local` with **no root**

New VM with a new IP? Update `HostName` under the `Host proxcode` block in
`~/.ssh/config`, clear stale keys (`ssh-keygen -R <ip>`), reconnect with
`StrictHostKeyChecking=accept-new`, and **verify the fingerprint out-of-band**
(on the proxmox console: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`)
before trusting it.

Baseline check — home should be clean:

```sh
ssh proxcode 'for t in nvim tmux git curl pi; do command -v $t || echo "no $t"; done; ls ~/.pi ~/.config/nvim ~/.tmux.conf 2>/dev/null'
```

## 1. The one command

```sh
bin/code-remote proxcode bootstrap
```

What happens, in order:

1. **push_configs** — rsync from your machine:
   `~/.config/nvim/` (--delete), `~/.tmux.conf` (raw, transformed later),
   `~/.config/tmux/plugins/` (--delete), `~/.bashrc` + `~/.bashrc-personal`
   (raw, transformed later), `~/.config/starship.toml`,
   pi config files (`settings.json`, `keybindings.json`, `AGENTS.md`,
   `trust.json`, `models-store.json`), `extensions/` (minus `gondolin/`,
   `blink1.ts`), `agents/`, `~/.agents/skills/` (dereferenced via `-L`),
   `~/scripts/{tmux_session_manager.sh,wtree.sh}`, `~/.config/code-remote/passenv`
   (from `PASS_ENVARS`, resolved locally via pass), pi keys resolved into
   remote `auth.json` (`!pass show …` commands executed locally, literal keys
   written).
   **Never synced:** `sessions/`, `install/`, `npm/`, `bin/`, your local
   `auth.json` (the remote gets resolved keys via the merge above; it keeps
   its own credentials otherwise, `SYNC_PI_AUTH=1` only seeds an empty one).
2. Upload `remote/bootstrap.sh` → `~/.code-remote/bootstrap.sh`
3. Run it remotely (`all` mode): base tools → nvim → node → static CLI tools →
   pi (`pi update --extensions` reconciles declared packages) → tmux.conf
   transform (local-only bits + unsupported options stripped) + managed blocks →
   tpm + tmux plugins → `nvim --headless "+Lazy! sync"` (plugins pinned by
   `lazy-lock.json`)

It is idempotent — re-run any time; already-current tools are skipped.

## 2. Verify each layer by hand

```sh
ssh proxcode
```

**Tools** (paths + versions):

```sh
export PATH="$HOME/.local/bin:$PATH"
for t in nvim node rg fd fzf lazygit bat starship jq pi; do
  printf '%-9s' "$t"; command -v "$t" && "$t" --version | head -1
done
```

Expected: everything found under `~/.local/bin`, versions matching the pins at
the top of `remote/bootstrap.sh`.

**nvim** — config + plugins:

```sh
ls ~/.config/nvim                      # your config
ls ~/.local/share/nvim/lazy | wc -l    # plugin count > 0 (Lazy! sync ran)
nvim --headless '+checkhealth' +qa     # or just open nvim and :checkhealth
```

**tmux** — transform + plugins:

```sh
head -1 ~/.tmux.conf                   # "# transformed by code-remote: …"
grep -nE '^set -g (default-command|.*scripts/)' ~/.tmux.conf   # no hits (comments ok)
tmux -L t -f /dev/null new-session -d && tmux -L t source-file ~/.tmux.conf   # no warnings
tmux -L t kill-server
tmux list-keys | grep 'copy-mode-vi y ' | grep -q wl-copy && echo yank-ok     # OSC52 shim bound, not the error binding
ls ~/.local/bin/wl-copy                                # shim present (headless hosts only)
ls ~/.local/bin/notify-send                            # OSC shim present (headless hosts only)
notify-send "test" "from $(hostname)"                  # exit 0; tmux status line / OSC escapes, never a crash
ls ~/.tmux/plugins                     # tpm, tmux-yank, catppuccin, …
tmux                                   # start: prefix is C-a, catppuccin bar, truecolor
```

**bash** — pushed config + managed blocks:

```sh
grep -nE 'fastfetch|direnv' ~/.bashrc           # no hits (local-only, stripped)
tail ~/.bashrc                                   # "# >>> code-remote >>>" block
ls ~/.bashrc-personal                            # your aliases, pushed as-is
bash -ic 'echo $PATH; alias ll'                  # ~/.local/bin first; alias works
grep -c '"!pass' ~/.pi/agent/auth.json           # 0 — keys are literal on remotes
pi auth check --provider zai                     # ready
pi auth check --provider fhnw-cybersec           # ready
pi --list-models | grep -c '^zai '               # 7-ish, not 0
bash -ic 'echo ${OPENROUTER_API_KEY:+set}'       # set (passenv file)
```

**pi** — binaries, config, packages, credentials:

```sh
pi --version
pi list                                # catppuccin-pi-theme installed
ls ~/.pi/agent/                        # settings.json, AGENTS.md, skills? no —
ls ~/.agents/skills | wc -l            # skills live here (35-ish)
ls ~/.pi/agent/auth.json               # absent on purpose — see next step
pi                                     # → /login → authenticate (zai)
```

**Clipboard** — inside that tmux session: `C-a [`, select text, `y`, then
paste on your **local** machine. Works via tmux-yank's OSC52 fallback (no X
on the VM). Note: nvim's own `y` stays remote (README, Known limits).

## 3. The continuity test (the whole point)

1. `bin/code-remote proxcode connect` (or just `bin/code-remote proxcode`) → tmux session `home`
2. start `pi` on a long task (or just `nvim`, some split panes)
3. close your laptop / kill the local terminal
4. reconnect from any machine, `tmux attach` — session intact, pi still working

## 4. Drift: `sync`

Change something locally (nvim config line, a skill, pi setting), then:

```sh
bin/code-remote proxcode sync
```

Re-pushes configs (same rsync set), re-applies the tmux transform. Verify the
change landed remotely. Re-running `bootstrap` instead also **upgrades tools**
to the pinned versions (edit pins in `remote/bootstrap.sh` first).

## 5. Reset a VM to zero

```sh
ssh proxcode 'rm -rf ~/.local/bin ~/.local/opt ~/.pi ~/.agents \
  ~/.config/nvim ~/.config/tmux ~/.tmux.conf ~/.tmux ~/.code-remote'
ssh proxcode "sed -i '/^# >>> code-remote >>>/,/^# <<< code-remote <<</d' ~/.bashrc"
```

Then start again at step 1.

## Known pitfalls (learned the hard way)

- **Fresh host without tmux and without sudo** → bootstrap dies with a clear
  message; install tmux first.
- **debconf noise** during apt (unzip etc.) is harmless — passwordless sudo
  hosts install silently, others need the `ssh -t` tty bootstrap already uses.
- **Mason / tree-sitter builds** need gcc/make — not provisioned (README).
- **pi credentials are never synced onto an existing remote** — `/login` there.
- Don't run `sync` against a host whose tmux.conf you hand-tuned: it gets
  replaced by the transformed local one.
