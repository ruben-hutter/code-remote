#!/usr/bin/env bash
# code-remote bootstrap — runs ON THE REMOTE host, from the cloned repo
# (~/code-remote). Idempotent: safe to re-run at any time. Everything
# declarative lives in flake.nix + home/; this script is the thin imperative
# residue nix cannot express: git identity seed, base tools, nix install,
# HM activation, pi, nvim plugin fetch + warm-up, user linger.
set -euo pipefail

NIX_VERSION=2.35.4

BIN="$HOME/.local/bin"
TMP="$(mktemp -d)"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'rm -rf "$TMP"' EXIT

# profile dirs may not exist yet on a fresh host — add what does, for the
# tools this script itself needs (nix, pi) and the shims
for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin" "$HOME/.pi/agent/bin" "$BIN"; do
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

# --- per-host identity for the HM profile -------------------------------------
# The identity file must be STAGED (git add): a flake in a git tree is sourced
# from the git index — an untracked file is invisible to nix.
REPO_ROOT=""
stage_remote_user() {
  REPO_ROOT="$(cd "$SRCDIR/.." && pwd)"
  [ -d "$REPO_ROOT/.git" ] || die "bootstrap must run from a code-remote git clone (got: $REPO_ROOT)"
  printf '{ name = "%s"; home = "%s"; }\n' "$(id -un)" "$HOME" \
    > "$REPO_ROOT/home/remote-user.nix"
  git -C "$REPO_ROOT" add -f home/remote-user.nix
  ok "host identity staged ($(id -un) @ $HOME)"
}

# --- git identity (pre-HM) ----------------------------------------------------
# HM puts the same identity into ~/.config/git/config, but only ~10 min into a
# fresh bootstrap (nix install + closure downloads) — commits made before that
# would get git's fallback identity ("Ubuntu <user@host>"). Seed the exact
# file HM will take over; keep name/email in sync with home/remote-default.nix.
GIT_NAME="Ruben Hutter"
GIT_EMAIL="ruben.hutter@rubenhutter.ch"
seed_git_identity() {
  local cfg="$HOME/.config/git/config"
  [ -f "$cfg" ] && return 0 # exists (HM-managed or user-provided) — leave it
  mkdir -p "$(dirname "$cfg")"
  printf '[user]\n\tname = %s\n\temail = %s\n' "$GIT_NAME" "$GIT_EMAIL" > "$cfg"
  ok "git identity seeded ($GIT_NAME <$GIT_EMAIL>)"
}

# --- base prerequisites -------------------------------------------------------
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
  have apt-get || { warn "no apt-get — Debian/Ubuntu only; install manually: $pkgs"; return 1; }
  wait_pkg_lock && sudo apt-get update -qq && sudo apt-get install -y $pkgs
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
}

# --- nix (official installer; needs sudo once for /nix) -----------------------
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
  [ -d /run/systemd/system ] || die "no systemd — the nix multi-user install needs it (VM/server, not a bare container)"
  info "installing nix $NIX_VERSION (official installer, multi-user — takes a minute)"
  fetch "https://releases.nixos.org/nix/nix-$NIX_VERSION/install" "$TMP/nix-install"
  sh "$TMP/nix-install" --daemon --yes || die "nix install failed" # --yes: unattended
  ok "nix $NIX_VERSION installed"
  export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
}

# --- home-manager -------------------------------------------------------------
hm_switch() {
  [ -n "$REPO_ROOT" ] || stage_remote_user
  # flakes must be on for the build; via env, NOT nix.conf — home-manager owns
  # ~/.config/nix/nix.conf after activation and aborts on conflicts
  export NIX_CONFIG="experimental-features = nix-command flakes"
  # conflicting pre-HM dotfiles are moved to <path>.pre-home-manager by
  # activation instead of aborting (all the standalone CLI's `-b` flag does)
  export HOME_MANAGER_BACKUP_EXT=pre-home-manager
  have nix || die "nix not on PATH — install failed?"
  local cfg=remote
  [ "$ARCH" = "aarch64" ] && cfg=remote-aarch64
  info "building home-manager generation ($cfg) — mostly cache.nixos.org downloads"
  local out gen
  out="$(nix build "$REPO_ROOT#homeConfigurations.$cfg.activationPackage" \
    --no-link --print-out-paths)" || die "home-manager build failed (see error above)"
  gen="$(printf '%s\n' "$out" | tail -1)"
  info "activating generation"
  "$gen/activate" || die "activation failed (see conflicting-file errors above)"
  export PATH="$HOME/.nix-profile/bin:$PATH" # created by THIS activation — the early loop missed it
  ok "home-manager active ($(readlink "$HOME/.nix-profile" 2>/dev/null | grep -oE 'home-manager-generation|[0-9]+-link' || echo 'generation set'))"
}

# --- user linger ---------------------------------------------------------------
# tmux >= 3.8 spawns panes as systemd user scopes; without linger, the user
# manager stops when the ssh session closes and kills detached tmux servers.
enable_linger() {
  loginctl show-user "$(id -un)" --property=Linger 2>/dev/null | grep -q yes && return 0
  if have sudo && sudo loginctl enable-linger "$(id -un)" 2>/dev/null; then
    ok "user linger enabled (tmux survives ssh disconnects)"
  else
    warn "could not enable linger — detached tmux sessions die on disconnect"
  fi
}

# --- pi (not in nixpkgs — official install.sh into ~/.pi/agent/bin) -----------
install_pi() {
  if have pi && pi --version >/dev/null 2>&1; then
    if pi update </dev/null >/dev/null 2>&1; then
      ok "pi updated ($(pi --version 2>/dev/null | head -1))"
    else
      ok "pi present ($(pi --version 2>/dev/null | head -1))"
    fi
  # setsid: no controlling tty → pi's installer skips its [y/n] menus and
  # takes the default action — keeps this flow unattended
  elif curl -fsSL https://pi.dev/install.sh | setsid sh; then
    ok "pi installed"
  else
    warn "pi install failed (continuing without it)"
    return 0
  fi
  export PATH="$HOME/.pi/agent/bin:$PATH" # so the reconcile below and later steps see it
  # settings.json may declare packages (themes, extensions) — reconcile them
  pi update --extensions </dev/null >/dev/null 2>&1 \
    || warn "pi package reconcile failed (run manually: pi update --extensions)"
}

# --- nvim plugins (versions pinned by the desktop lazy-lock.json) -------------
# :Lazy restore installs exactly the commits from lazy-lock.json. :Lazy sync
# would instead UPDATE plugins to their spec branch HEAD — nvim-treesitter's
# default branch is the rewritten `main` (no nvim-treesitter.configs), which
# breaks the config's legacy-API after/plugin files. (lazy's trailing attempt
# to rewrite the read-only store lockfile errors harmlessly; nothing to write.)
nvim_lazy_restore() {
  have nvim || { warn "nvim not on PATH — skipping lazy restore"; return 0; }
  if nvim --headless "+Lazy! restore" +qa >/dev/null 2>&1; then
    ok "nvim plugins (lazy restore, pinned by lazy-lock.json)"
  else
    warn "lazy restore failed — run inside nvim: :Lazy! restore"
  fi
}

# --- nvim warm-up -------------------------------------------------------------
# First config load triggers async installs (mason LSP servers, treesitter
# parsers, copilot) — do them HERE, headlessly, so the first interactive open
# (possibly pi's ctrl+g editor) isn't eaten by install popups. mason-lspconfig
# SKIPS ensure_installed in headless mode, so drive its settings directly.
# Two passes — single-attempt races (observed with tinymist) retry here.
nvim_warmup() {
  have nvim || { warn "nvim not on PATH — skipping warm-up"; return 0; }
  local scratch warm pass
  scratch="$(mktemp --suffix=.md)"
  warm="$(mktemp)"
  cat >"$warm" <<'EOF'
local mappings = require("mason-lspconfig.mappings")
local settings = require("mason-lspconfig.settings")
local reg = require("mason-registry")
local function install_missing()
  local n = 0
  for _, server in ipairs(settings.current.ensure_installed) do
    local ok, pkg = pcall(function()
      local name = mappings.get_mason_map().lspconfig_to_package[server] or server
      local p = reg.get_package(name)
      if not p:is_installed() then p:install() end
      return true
    end)
    if ok then n = n + 1 end
  end
  return n
end
reg.refresh(function() install_missing() end)
local last, stable, waited = -1, 0, 0
while stable < 5 and waited < 420 do
  local ok, count = pcall(function() return #reg.get_installed_package_names() end)
  if ok then
    if count == last then stable = stable + 1 else stable = 0 end
    last = count
  end
  vim.wait(3000)
  waited = waited + 3
end
print(("warmup: %d mason packages (%ds)"):format(last, waited))
vim.cmd("qa!")
EOF
  for pass in 1 2; do
    info "nvim warm-up pass $pass — first-ever run takes a few minutes"
    if nvim --headless "$scratch" -c "luafile $warm" >/dev/null 2>&1; then
      ok "warm-up pass $pass done"
    else
      warn "warm-up pass $pass incomplete — first interactive open finishes the rest"
    fi
  done
  rm -f "$scratch" "$warm"
}

# --- main ---------------------------------------------------------------------
seed_git_identity # before the long steps: closes the no-identity window
ensure_base
install_nix
stage_remote_user
hm_switch
install_pi
nvim_lazy_restore
nvim_warmup
enable_linger

info "bootstrap done."
