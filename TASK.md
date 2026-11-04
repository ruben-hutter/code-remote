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

- `README.md` — v2 architecture, known limits
- `TESTING.md` — the runbook = definition of done
- `remote/bootstrap.sh` (v2) / `remote/bootstrap-legacy.sh` (v1 escape hatch)
- `code-remote.conf` — `NIXOS_CONFIG_DIR` points at `~/repos/nixos-config/master`
- `~/repos/nixos-config/master/flake.nix` + `home/remote-default.nix` — the
  declarative remote env (homeConfigurations.remote / remote-aarch64)

Local machine: Fedora, has nix 2.32.4 + pass. Pre-validate config changes
locally with `nix build ~/repos/nixos-config/master#homeConfigurations.remote.activationPackage --no-link`
(build only — NEVER activate on the local machine).

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
