#!/usr/bin/env bash
# code-remote bootstrap v2 — home-manager + nix provisioner.
# Runs ON THE REMOTE host. Idempotent: safe to re-run at any time.
#
# The declarative part lives in ~/nixos-config (rsynced here by
# bin/code-remote from your machine): homeConfigurations.remote is a headless,
# bash-first home-manager profile (nvim + vendored config, tmux with OSC52
# yank, starship, fzf, direnv + flakes, git, bat/lazygit/btop/htop/lf,
# ~/scripts, direnv-managed dev shells). This script is the thin imperative
# residue nix cannot express:
#
#   1. ensure base tools (git, curl, tar, unzip)
#   2. install nix (official installer — sudo; multi-user daemon, or
#      single-user on non-systemd hosts)
#   3. migrate pre-home-manager files out of the way (HM aborts on conflicts)
#   4. nix build + activate the home-manager generation
#   5. pi (official install.sh; not in nixpkgs) + pi extension reconcile
#   6. OSC52/OSC9 shims for headless hosts
#   7. nvim plugin fetch (lazy sync; versions pinned by vendored lazy-lock)
#
# usage: bootstrap.sh [all|hm|pi]
#   all  everything (default)
#   hm   base + nix + home-manager switch
#   pi   pi + shims + lazy sync (assumes hm ran before)
set -euo pipefail

MODE="${1:-all}"

# --- pinned versions ---------------------------------------------------------
NIX_VERSION=2.35.4
# -----------------------------------------------------------------------------

BIN="$HOME/.local/bin"
TMP="$(mktemp -d)"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'rm -rf "$TMP"' EXIT

# nix is needed by hm_switch and (via node) install_pi; profile dirs may not
# exist yet on a fresh host — add what exists, plus ~/.local/bin for pi/shims.
for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin" "$BIN"; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | aarch64) ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

fetch() { curl -fsSL -o "$2" "$1" || die "download failed: $1"; }

# --- base prerequisites (the sudo-ish part) ----------------------------------
wait_pkg_lock() { # fresh Ubuntu boots run apt-daily/unattended-upgrades first
  have apt-get || return 0
  local waited=0
  while :; do
    if have fuser; then
      sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || return 0
    else
      ps -eo comm= | grep -qxE 'apt-get|apt|dpkg|unattended-upgr' || return 0
    fi
    if [ "$waited" -eq 0 ]; then info "apt busy (first-boot unattended-upgrade?) — waiting"; fi
    [ "$waited" -ge 300 ] && { warn "apt lock still held after 5 min — trying anyway"; return 0; }
    sleep 10; waited=$((waited + 10))
  done
}

pkg_install() {
  local pkgs="$1"
  if ! have sudo; then
    warn "no sudo — cannot install: $pkgs"
    return 1
  fi
  if have apt-get; then wait_pkg_lock && sudo apt-get update -qq && sudo apt-get install -y $pkgs
  elif have dnf; then sudo dnf install -y $pkgs
  elif have yum; then sudo yum install -y $pkgs
  elif have pacman; then sudo pacman -S --noconfirm $pkgs
  elif have zypper; then sudo zypper install -y $pkgs
  else warn "no known package manager — install manually: $pkgs"; return 1
  fi
}

ensure_base() {
  local missing="" t
  for t in git curl tar unzip; do
    have "$t" || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    warn "missing base tools:$missing"
    pkg_install "$missing" || die "these are required to bootstrap:$missing"
  fi
  have python3 || warn "python3 not found — some LSP servers want it"
  # NOTE: tmux is NOT a base prerequisite anymore — home-manager installs it.
}

# --- nix (official installer; needs sudo once for /nix) ----------------------
install_nix() {
  local nixbin
  for nixbin in /nix/var/nix/profiles/default/bin/nix "$HOME/.nix-profile/bin/nix"; do
    if [ -x "$nixbin" ]; then
      ok "nix present ($("$nixbin" --version 2>/dev/null))"
      return
    fi
  done
  if ! have sudo; then
    die "no sudo — nix needs to create /nix; give the user sudo or install nix manually"
  fi
  info "installing nix $NIX_VERSION (official installer, multi-user — takes a minute)"
  fetch "https://releases.nixos.org/nix/nix-$NIX_VERSION/install" "$TMP/nix-install"
  if [ -d /run/systemd/system ]; then
    sh "$TMP/nix-install" --daemon || die "nix install failed"
  else
    # no systemd (container): the daemon needs it — single-user install on a
    # /nix we pre-create, so the build user is us instead of root
    sudo mkdir -p /nix && sudo chown "$(id -u):$(id -g)" /nix
    sh "$TMP/nix-install" --no-daemon || die "nix install failed"
  fi
  ok "nix $NIX_VERSION installed"
  export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
}

# --- migration: get pre-home-manager files out of HM's way -------------------
# HM aborts activation on conflicting files it doesn't manage, and tmux reads
# ~/.tmux.conf BEFORE ~/.config/tmux/tmux.conf (which would shadow HM's).
adopt_or_setaside() { # <path>
  local p="$1"
  [ -e "$p" ] || return 0
  case "$(readlink "$p" 2>/dev/null)" in
    /nix/store/*) return 0 ;; # already HM-managed
    *)
      mv "$p" "$p.pre-home-manager"
      info "moved aside: $p → $(basename "$p").pre-home-manager"
      ;;
  esac
}

migrate_to_hm() {
  local f
  for f in .bashrc .bash_profile .profile .tmux.conf \
    .config/nvim .config/starship.toml .config/nix/nix.conf; do
    adopt_or_setaside "$HOME/$f"
  done
  # v1 leftovers: tpm + cloned plugins are unused now (plugins come from
  # nixpkgs); old pinned binaries/opt dirs would only waste disk
  rm -rf "$HOME/.config/tmux/plugins" "$HOME/.tmux/plugins"
  local b
  for b in nvim node npm npx corepack rg fd fzf lazygit bat starship jq direnv; do
    rm -f "$BIN/$b"
  done
  rm -rf "$HOME/.local/opt"/nvim-* "$HOME/.local/opt"/node-v* 2>/dev/null || true
  ok "migration check done"
}

# --- home-manager -------------------------------------------------------------
hm_switch() {
  local nixcfg="$HOME/nixos-config"
  [ -d "$nixcfg" ] || die "~/nixos-config not found — bin/code-remote syncs it before bootstrap"
  # flakes must be on for the build itself; via env, NOT nix.conf — home-manager
  # owns ~/.config/nix/nix.conf after activation and aborts on conflicts
  export NIX_CONFIG="experimental-features = nix-command flakes"
  have nix || die "nix not on PATH — install failed?"
  local cfg=remote
  [ "$ARCH" = "aarch64" ] && cfg=remote-aarch64
  info "building home-manager generation ($cfg) — mostly cache.nixos.org downloads"
  local out gen
  # stdout (out-paths) captured; build progress/errors stream to the terminal
  out="$(nix build "$nixcfg#homeConfigurations.$cfg.activationPackage" \
    --no-link --print-out-paths)" || die "home-manager build failed (see error above)"
  gen="$(printf '%s\n' "$out" | tail -1)"
  info "activating generation"
  "$gen/activate" || die "activation failed (see conflicting-file errors above)"
  # the profile dir was created by THIS activation — the early PATH loop ran
  # before it existed; re-export so pi/node/nvim see the HM tools
  export PATH="$HOME/.nix-profile/bin:$PATH"
  ok "home-manager active ($(readlink "$HOME/.nix-profile" 2>/dev/null | grep -oE 'home-manager-generation|[0-9]+-link' || echo 'generation set'))"
}

# --- pi (not in nixpkgs — official install.sh into ~/.local) ------------------
install_pi() {
  if have pi && pi --version >/dev/null 2>&1; then
    if pi update </dev/null >/dev/null 2>&1; then
      ok "pi updated ($(pi --version 2>/dev/null | head -1))"
    else
      ok "pi present ($(pi --version 2>/dev/null | head -1))"
    fi
  elif curl -fsSL https://pi.dev/install.sh | sh; then
    ok "pi installed"
  else
    warn "pi install failed (continuing without it)"
    return 0
  fi
  # settings.json may declare packages (themes, extensions) — reconcile them
  pi update --extensions </dev/null >/dev/null 2>&1 \
    || warn "pi package reconcile failed (run manually: pi update --extensions)"
}

# --- OSC shims for headless hosts (reused from v1) ----------------------------
install_clipboard_shim() {
  for t in pbcopy clip.exe wl-copy xsel xclip; do
    have "$t" && return 0
  done
  install -m 755 "$SRCDIR/bin/wl-copy" "$BIN/wl-copy"
  ok "wl-copy OSC52 shim (tmux-yank on headless host)"
}

install_notify_shim() {
  have notify-send && return 0
  install -m 755 "$SRCDIR/bin/notify-send" "$BIN/notify-send"
  ok "notify-send OSC shim (pi notifications via terminal)"
}

# --- nvim plugins (versions pinned by the vendored lazy-lock.json) ------------
nvim_lazy_sync() {
  have nvim || { warn "nvim not on PATH — skipping lazy sync"; return 0; }
  if nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
    ok "nvim plugins (lazy sync, pinned by lazy-lock.json)"
  else
    warn "lazy sync failed — run inside nvim: :Lazy! sync"
  fi
}

# --- main ---------------------------------------------------------------------
case "$MODE" in
  hm)
    ensure_base
    install_nix
    migrate_to_hm
    hm_switch
    ;;
  pi)
    install_pi
    install_clipboard_shim
    install_notify_shim
    nvim_lazy_sync
    ;;
  all)
    ensure_base
    install_nix
    migrate_to_hm
    hm_switch
    install_pi
    install_clipboard_shim
    install_notify_shim
    nvim_lazy_sync
    ;;
  *)
    die "usage: bootstrap.sh [all|hm|pi]"
    ;;
esac

info "bootstrap ($MODE) done."
