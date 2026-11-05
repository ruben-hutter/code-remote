# TASK: End-to-end test of code-remote v2 (home-manager bootstrap) — debug & fix until green

**Status: READY.** Ruben creates a fresh VM + ssh alias, then says "go". The
agent runs the whole loop below autonomously, fixing everything that breaks.

## Mission

Prove the v2 home-manager bootstrap works on a fresh VM **and** on a v1-era
remote (migration path). Debug and fix until every check in `TESTING.md` §2
passes. Fixes go into the real repos, not workarounds on the VM.

## Ruben provides before "go"

- Fresh VM (Ubuntu 24.04 server or similar, x86_64, ≥5 GB disk)
- ssh alias in `~/.ssh/config`, key auth working (`ssh <alias> whoami`)
- sudo on the VM (password sudo is fine — bootstrap runs over `ssh -t`;
  NOPASSWD is smoother)
- The alias name (if not said in the "go" message, ask once, then run)

## Context to read first

- `README.md` — architecture (self-contained: own flake + vendored configs),
  known limits
- `TESTING.md` — the runbook = definition of done
- `remote/bootstrap.sh` (v2) / `remote/bootstrap-legacy.sh` (v1 escape hatch)
- `flake.nix` + `home/remote-default.nix` — the declarative remote env
  (homeConfigurations.remote / remote-aarch64); flake inputs: nixpkgs, HM,
  scripts, skills (all locked)
- `bin/vendor` — mirrors desktop-owned configs from ~/repos/nixos-config

Local machine: Fedora, has nix 2.32.4 + pass. Pre-validate config changes
locally with `nix build .#homeConfigurations.remote.activationPackage --no-link`
from this repo (build only — NEVER activate on the local machine).

## Plan

1. **Pre-flight**: ping the VM (`ssh <alias> 'uname -m; id -un; sudo -n true 2>&1'`),
   note arch (picks homeConfigurations.remote vs remote-aarch64), whether user
   is root (no `sudo` binary → `install_nix` needs a fix: run installer directly
   as root — likely bug #0 if the image is root-only).
2. **v1 first (OPTIONAL — migration setup only)**: `bin/code-remote <alias>
   bootstrap-legacy` manufactures a realistic v1 state (pinned binaries,
   tpm clones, managed bashrc blocks). Skip for a plain v2 test.
3. **Manual ssh-first flow (the new primary path)**: `ssh <alias>`, then
   `git clone https://github.com/ruben-hutter/code-remote && cd code-remote
   && ./bootstrap`. Expect ~10 min (nix installer + closure downloads). Watch
   for: sudo prompts, nix install failure, HM activation aborts (conflicting
   files not covered by the migration list), pi install, lazy sync.
4. **Local one-liner**: `bin/code-remote <alias> bootstrap` from the laptop —
   must detect the existing clone, pull, and re-run (idempotency across both
   entry points).
5. **`bin/code-remote <alias> sync`** — pi keys + passenv + aliases from the
   laptop (the ONLY step that carries credentials).
6. **Walk `TESTING.md` §2** layer by layer: nix+HM, tools, nvim, bash, tmux,
   clipboard/notifications (inside tmux — needs OSC52-capable local terminal),
   pi, nix dev shells. For the dev-shell test make a tiny flake on the VM
   (`~/devshell-test` with `pkgs.mkShell { packages = [ pkgs.hello ]; }`) +
   `.envrc` `use flake` + `direnv allow`, confirm `command -v hello`.
7. **Migration artifacts** (only if step 2 ran): `ls *.pre-home-manager` in
   `$HOME`, tpm gone, `~/.local/bin` reduced to pi + shims,
   `~/.nix-profile/bin` authoritative; `~/nixos-config` is now a git clone.
8. **Idempotency**: re-run `./bootstrap` on the host and
   `bin/code-remote <alias> bootstrap` — repos fast-forward, nix skips,
   HM rewrites only what moved; `connect` must land in tmux with session
   picker.
9. **Fix loop** until all green: reproduce → diagnose (read the failing
   command's output on the VM) → fix in the right repo → re-run.

## Where bugs are likely (check here first)

- **Test order**: a fresh VM can go straight to v2 bootstrap; legacy is only
  run to simulate an existing v1 remote before migrating it.
- `install_nix` as root-only image (no `sudo` binary) — fix: root runs the
  installer directly.
- HM activation abort on files the migration list misses (check the full
  conflict error; add the path to `migrate_to_hm` in `remote/bootstrap.sh`).
- apt/dpkg lock on first boot (wait loop exists — verify it actually works).
- pi install.sh + node ordering (PATH re-export after activate was added —
  verify node really resolves from `~/.nix-profile`).
- lazy sync: force-pushed upstream pins → if `+Lazy! sync` fails, use
  `+Lazy! restore` semantics via the vendored lock (match legacy behavior).
- tmux OSC52 yank end-to-end depends on Ruben's local terminal — if it fails,
  verify the shim + `load-buffer -w` wiring before blaming the terminal.
- flake eval on the VM: `~/nixos-config` has no `.git` (plain rsync dir) —
  path flake should work; if nix demands git-tracked files, fix the rsync or
  the flake ref.
- direnv `use flake` first activation compiles/evaluates — slow on small VMs;
  nix-direnv caching should make the second cd instant.

## Iteration etiquette

- Quick loop: edit local file → `rsync -az <file> <alias>:<path>` → re-run the
  failing step on the VM. BUT every fix must land in the local repos before
  finishing (local is the source of truth); re-push via `bin/code-remote`
  commands when in doubt.
- Keep a findings log at the bottom of this file (one line per issue:
  symptom → cause → fix → commit).
- Update `README.md`/`TESTING.md` when behavior differs from the docs.

## Repo/commit rules

- `code-remote`: work directly on `main` (no wtree layout), small focused
  commits.
- `~/repos/nixos-config`: per its `AGENTS.md` — one-line config tweaks can go
  direct to `master`; structural fixes need a feature worktree
  (`wtree feature <name>`, `wtree finish <name>`). Never `nixos-rebuild` from
  a worktree.
- Never activate home-manager on the LOCAL machine. Build only.

## Definition of done

- All `TESTING.md` §2 checks pass on the VM, in order.
- Migration artifacts verified (step 5).
- `sync` idempotent, `connect` works, dev-shell test passes.
- All fixes committed (both repos), docs updated, findings log written here.
- End with a short report: what broke, what was fixed, what's still shaky.

---

## Findings log

(work in progress — agent fills this during the run)

All fixed and verified end-to-end on a fresh Ubuntu 24.04 VM (2026-11-05):

- bootstrap aborted before nvim lazy sync → fresh VMs have no `~/.local/bin`; `install` of shims failed under `set -e` → `mkdir -p "$BIN"` in both shim functions (c7cccdf)
- `pi update --extensions` failed right after install + pi unusable in shells → pi's managed installer moved to `~/.pi/agent/bin`, which was on no PATH → exported in `install_pi`, added to script PATH loop, sessionVariables.PATH and tmux PATH env (c7cccdf)
- wl-copy shim skipped on headless host → HM profile ships real wl-clipboard, so `have wl-copy && return 0` misfired → skip only when `WAYLAND_DISPLAY` is set (c7cccdf)
- first sync left raw `!pass` keys in remote auth.json (unusable — no pass on remotes) → seeding path pushed the raw file because `sync_pi_keys` bails when the remote has none → resolve first, seed resolved (7f23bcd)
- tmux panes / interactive non-login shells had no `~/.local/bin` + `~/.pi/agent/bin` on PATH (hm-session-vars.sh only reachable via `~/.profile`) → shims shadowed by profile wl-copy, pi missing → source `hm-session-vars.sh` at top of bash initExtra (b9ee456)
- sessionPath prepended nix-profile AFTER sessionVariables.PATH → real wl-copy ahead of the shim in interactive shells/panes → replaced with one explicit sessionVariables.PATH order: local/bin, pi/agent/bin, nix-profile/bin, system (1e36f53)
- tmux yank: `load-buffer -w` emitted no OSC52 → tmux only sends it when the outer terminal advertises Ms (stock terminfo doesn't) and `set-clipboard` defaults to external (only forwards app-internal OSC52) → `terminal-overrides ',*:Ms=…'` + `set -s set-clipboard on` (f997d3d, 18363ab). Verified with an attached pty client: outer terminal receives OSC52 from copy-mode `y` — for future greps: empty selections emit `Cg==` (a newline)
- tmux notifications: notify-send shim's DCS-wrapped OSC 9/777 were dropped → `allow-passthrough` off by default → `set -g allow-passthrough on` (f997d3d). Verified: escape reaches outer terminal. **Later removed entirely** at Ruben's request (d77d655/7e5813e): pi's notify.ts extension probes notify-send and skips gracefully when absent (ENOENT-safe, verified), shim + `allow-passthrough` dropped from v2 and legacy
- copy-mode `y` did nothing end-to-end (buffer only, no OSC52) — TWO stacked causes: (a) the tmux-yank plugin detects wl-copy via $WAYLAND_DISPLAY, absent headless → no pipe target → replaced with explicit copy-pipe binds (d77d655); (b) the vendored desktop "Vi copy mode bindings" section re-bound `y` to plain copy-selection AFTER those binds (and unbound MouseDragEnd1Pane) → later bind wins → the vendored block now uses the copy-pipe variants itself (4749acc). Verified: attached pty client receives OSC52 payloads from copy-mode `y` — empty selections emit `Cg==` (a newline)
- the OSC52 emission format was 4-field (`52;c;;<b64>`) because the Ms override hardcoded `c;` — strict terminals misparse the empty middle field into the wrong selection ("yank pastes into another clipboard"). Fixed to canonical xterm format `ESC]52;<selection>;<base64>` (82defc9) — byte-parity with the working v1/proxcode emission (terminal-native Ms on tmux 3.4). Future greps: match `]52;;<b64>`
- test-environment ghost, not a product bug: synthetic tmux panes (spawned headlessly via `script`) intermittently came up blank/hung on this VM — tmux 3.8's systemd scope spawn racing something locally. Ruben's real interactive session was unaffected (his y captured real text). Headless OSC52 verification: drive `-X` commands and accept that selection content may be empty (`Cg==` proves the emission chain; real selection content is core tmux)
- tmux 3.8 spawns panes as systemd user scopes (tmux-spawn-*.scope); with Linger=no the user manager stops when the spawning ssh session closes, killing detached servers and all sessions → bootstrap enables linger (d597a78). Testing note: transient "server died during test" observations were this same mechanism racing cold user managers, plus a stale default-socket server joining tests; not config bugs
- cosmetic, by design: "Git tree is dirty" nix-build warning (staged `home/remote-user.nix`), useradd SYS_UID_MAX warnings from the nix installer, HM eval warnings about neovim withRuby/withPython3 defaults (now pinned)
- process note: a debug strace wrapper was briefly set as the VM's login shell with broken quoting, killing all ssh access (fixed via console: `usermod -s /bin/bash device-admin`). Lesson: never mutate login shells for tracing — strace inline commands instead
