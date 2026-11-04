#!/usr/bin/env bash
# code-remote bootstrap — userspace dev environment provisioner.
# Runs ON THE REMOTE host. Idempotent: safe to re-run at any time.
#
# usage: bootstrap.sh [all|tools|configs]
#   all      tools + configs (default)
#   tools    binaries only (nvim, node, static CLI tools, direnv, nix, pi)
#   configs  config transforms + tmux/nvim plugin install only
#
# Everything installs into ~/.local — no root required, except tmux and nix
# if the host doesn't already have them (see ensure_base / install_nix).
set -euo pipefail

MODE="${1:-all}"

# --- pinned versions (bump here; match your local machine where it matters) --
NVIM_VERSION=0.11.6
NODE_VERSION=22.22.2
RG_VERSION=15.2.0
FD_VERSION=10.4.2
FZF_VERSION=0.74.5
LAZYGIT_VERSION=0.66.2
BAT_VERSION=0.26.1
STARSHIP_VERSION=1.24.2
JQ_VERSION=1.8.1
DIRENV_VERSION=2.38.2
NIX_VERSION=2.35.4
# -----------------------------------------------------------------------------

BIN="$HOME/.local/bin"
OPT="$HOME/.local/opt"
TMP="$(mktemp -d)"
SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$BIN:$PATH"
mkdir -p "$BIN" "$OPT"

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

# --- version helpers ---------------------------------------------------------
version_of() { "$1" --version 2>/dev/null | head -1 || true; }
uptodate() { # <binary> <version-substring>
  have "$1" && version_of "$1" | grep -qF "$2"
}

# --- base prerequisites (the sudo-ish part) ----------------------------------
wait_pkg_lock() { # fresh Ubuntu boots run apt-daily/unattended-upgrades first
  have apt-get || return 0
  local waited=0
  while :; do
    if have fuser; then
      sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || return 0
    else
      # fuser (psmisc) not installed — heuristic: no apt/dpkg process running
      ps -eo comm= | grep -qxE 'apt-get|apt|dpkg|unattended-upgr' || return 0
    fi
    if [ "$waited" -eq 0 ]; then info "apt busy (first-boot unattended-upgrade?) — waiting"; fi
    [ "$waited" -ge 300 ] && { warn "apt lock still held after 5 min — trying anyway"; return 0; }
    sleep 10; waited=$((waited + 10))
  done
}

pkg_install() { # best-effort system packages; userspace is the default, this is rescue only
  local pkgs="$1"
  if ! have sudo && ! have doas; then
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
  if ! have tmux; then
    warn "tmux is missing — the one tool userspace cannot provide"
    if pkg_install tmux; then ok "tmux installed via system package"; fi
  fi
  have tmux || die "tmux is required; install it (needs root) and re-run"
}

# --- installers ---------------------------------------------------------------
install_from_archive() { # <url-x86_64> <url-aarch64> <inner-glob> <dest-name>
  local url inner dest hit f
  case "$ARCH" in x86_64) url="$1" ;; aarch64) url="$2" ;; esac
  inner="$3" dest="$4"
  f="$TMP/$dest.dl"
  fetch "$url" "$f"
  case "$url" in
    *.tar.gz) tar -xzf "$f" -C "$TMP" ;;
    *.tar.xz) tar -xJf "$f" -C "$TMP" ;;
    *.tbz) tar -xjf "$f" -C "$TMP" ;;
    *) die "unknown archive type: $url" ;;
  esac
  hit="$(find "$TMP" -maxdepth 4 -path "*/$inner" -type f | head -1)"
  [ -n "$hit" ] || die "inner path '$inner' not found in $url"
  install -m 755 "$hit" "$BIN/$dest"
  ok "$dest"
}

install_raw() { # <url> <dest-name>   (plain static binary, no archive)
  fetch "$1" "$BIN/$2"
  chmod 755 "$BIN/$2"
  ok "$2"
}

install_nvim() {
  if uptodate nvim "NVIM v$NVIM_VERSION"; then ok "nvim $NVIM_VERSION present"; return; fi
  local nvimarch; case "$ARCH" in x86_64) nvimarch=x86_64 ;; aarch64) nvimarch=arm64 ;; esac
  local f="$TMP/nvim.tar.gz"
  fetch "https://github.com/neovim/neovim/releases/download/v$NVIM_VERSION/nvim-linux-$nvimarch.tar.gz" "$f"
  rm -rf "$OPT/nvim-linux-$nvimarch"
  tar -xzf "$f" -C "$OPT"
  ln -sfn "$OPT/nvim-linux-$nvimarch/bin/nvim" "$BIN/nvim"
  ok "nvim $NVIM_VERSION"
}

install_node() {
  if uptodate node "v$NODE_VERSION"; then ok "node v$NODE_VERSION present"; return; fi
  local narch b
  case "$ARCH" in x86_64) narch=x64 ;; aarch64) narch=arm64 ;; esac
  fetch "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$narch.tar.xz" "$TMP/node.tar.xz"
  rm -rf "$OPT/node-v$NODE_VERSION-linux-$narch"
  tar -xJf "$TMP/node.tar.xz" -C "$OPT"
  for b in "$OPT/node-v$NODE_VERSION-linux-$narch/bin/"*; do
    ln -sfn "$b" "$BIN/$(basename "$b")"
  done
  ok "node v$NODE_VERSION"
}

install_direnv() {
  if uptodate direnv "$DIRENV_VERSION"; then ok "direnv $DIRENV_VERSION present"; return; fi
  local a; case "$ARCH" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; esac
  install_raw "https://github.com/direnv/direnv/releases/download/v$DIRENV_VERSION/direnv.linux-$a" direnv
}

enable_nix_flakes() {
  # flake dev shells (`use flake` in .envrc) need the experimental opt-in;
  # keep whatever experimental-features are already set, append ours if missing
  local conf="$HOME/.config/nix/nix.conf"
  mkdir -p "$HOME/.config/nix"
  [ -f "$conf" ] || touch "$conf"
  if grep -qE '^experimental-features[[:space:]]*=' "$conf"; then
    grep -q 'nix-command' "$conf" ||
      sed -i -E 's|^experimental-features([[:space:]]*=.*)$|& nix-command flakes|' "$conf"
  else
    printf 'experimental-features = nix-command flakes\n' >> "$conf"
  fi
}

install_nix() {
  local nixbin
  for nixbin in /nix/var/nix/profiles/default/bin/nix "$HOME/.nix-profile/bin/nix"; do
    if [ -x "$nixbin" ]; then
      ok "nix present ($("$nixbin" --version 2>/dev/null))"
      enable_nix_flakes
      return
    fi
  done
  if ! have sudo; then
    warn "no sudo — cannot install nix (it owns /nix); skipping"
    return 0
  fi
  info "installing nix $NIX_VERSION (official installer, multi-user — takes a minute)"
  fetch "https://releases.nixos.org/nix/nix-$NIX_VERSION/install" "$TMP/nix-install"
  if [ -d /run/systemd/system ]; then
    sh "$TMP/nix-install" --daemon || { warn "nix install failed (continuing without it)"; return 0; }
  else
    # no systemd (container): the daemon needs it — do a single-user install on
    # a /nix we pre-create, so the build user is us instead of root
    sudo mkdir -p /nix && sudo chown "$(id -u):$(id -g)" /nix
    sh "$TMP/nix-install" --no-daemon || { warn "nix install failed (continuing without it)"; return 0; }
  fi
  enable_nix_flakes
  ok "nix $NIX_VERSION (flakes via ~/.config/nix/nix.conf)"
}

install_statics() {
  local musl_x="x86_64-unknown-linux-musl" musl_a="aarch64-unknown-linux-musl"
  local gnu_x="x86_64-unknown-linux-gnu" gnu_a="aarch64-unknown-linux-gnu"

  if ! uptodate rg "$RG_VERSION"; then
    # x86_64 ships musl, aarch64 ships gnu
    install_from_archive \
      "https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/ripgrep-$RG_VERSION-$musl_x.tar.gz" \
      "https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/ripgrep-$RG_VERSION-$gnu_a.tar.gz" \
      "ripgrep-*/rg" rg
  fi
  if ! uptodate fd "$FD_VERSION"; then
    install_from_archive \
      "https://github.com/sharkdp/fd/releases/download/v$FD_VERSION/fd-v$FD_VERSION-$gnu_x.tar.gz" \
      "https://github.com/sharkdp/fd/releases/download/v$FD_VERSION/fd-v$FD_VERSION-$gnu_a.tar.gz" \
      "fd-v*/fd" fd
  fi
  if ! uptodate fzf "$FZF_VERSION"; then
    install_from_archive \
      "https://github.com/junegunn/fzf/releases/download/v$FZF_VERSION/fzf-$FZF_VERSION-linux_amd64.tar.gz" \
      "https://github.com/junegunn/fzf/releases/download/v$FZF_VERSION/fzf-$FZF_VERSION-linux_arm64.tar.gz" \
      "fzf" fzf
  fi
  if ! uptodate lazygit "$LAZYGIT_VERSION"; then
    install_from_archive \
      "https://github.com/jesseduffield/lazygit/releases/download/v$LAZYGIT_VERSION/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
      "https://github.com/jesseduffield/lazygit/releases/download/v$LAZYGIT_VERSION/lazygit_${LAZYGIT_VERSION}_Linux_arm64.tar.gz" \
      "lazygit" lazygit
  fi
  if ! uptodate bat "$BAT_VERSION"; then
    install_from_archive \
      "https://github.com/sharkdp/bat/releases/download/v$BAT_VERSION/bat-v$BAT_VERSION-$musl_x.tar.gz" \
      "https://github.com/sharkdp/bat/releases/download/v$BAT_VERSION/bat-v$BAT_VERSION-$musl_a.tar.gz" \
      "bat-v*/bat" bat
  fi
  if ! uptodate starship "$STARSHIP_VERSION"; then
    install_from_archive \
      "https://github.com/starship/starship/releases/download/v$STARSHIP_VERSION/starship-$musl_x.tar.gz" \
      "https://github.com/starship/starship/releases/download/v$STARSHIP_VERSION/starship-$musl_a.tar.gz" \
      "starship" starship
  fi
  if ! uptodate jq "$JQ_VERSION"; then
    local jq_a; case "$ARCH" in x86_64) jq_a=amd64 ;; aarch64) jq_a=arm64 ;; esac
    install_raw "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-linux-$jq_a" jq
  fi
}

install_clipboard_shim() {
  # tmux-yank needs a clipboard tool; on headless hosts install an OSC52 shim
  # so copy-mode y reaches the local machine's clipboard via the terminal
  for t in pbcopy clip.exe wl-copy xsel xclip; do
    have "$t" && return 0
  done
  install -m 755 "$SRCDIR/bin/wl-copy" "$BIN/wl-copy"
  ok "wl-copy OSC52 shim (tmux-yank on headless host)"
}

install_notify_shim() {
  # pi's notify extension calls notify-send; headless hosts have neither the
  # binary nor a notification daemon. Install an OSC 9/777 shim (plus a tmux
  # status-line message) so "pi needs a choice" still reaches your terminal
  for t in notify-send; do
    have "$t" && return 0
  done
  install -m 755 "$SRCDIR/bin/notify-send" "$BIN/notify-send"
  ok "notify-send OSC shim (pi notifications via terminal)"
}

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
  # so e.g. npm:catppuccin-pi-theme actually installs on a fresh host
  pi update --extensions </dev/null >/dev/null 2>&1 \
    || warn "pi package reconcile failed (run manually: pi update --extensions)"
}

# --- config transforms --------------------------------------------------------
configure_tmux() {
  [ -f "$HOME/.tmux.conf" ] || { warn "no ~/.tmux.conf synced — skipping"; return; }
  # local-only bits: fish as interactive default, hard-coded local scripts, walrus hooks
  sed -i -E \
    -e '/^set -g default-command/d' \
    -e '/scripts\//d' \
    -e '/set-hook -g /d' \
    "$HOME/.tmux.conf"
  grep -q 'transformed by code-remote' "$HOME/.tmux.conf" ||
    sed -i '1i # transformed by code-remote: fish default-command, local scripts/ and session hooks removed' \
      "$HOME/.tmux.conf"
  # drop options this host's tmux doesn't know (tmux >= 3.4 removed
  # extended-keys-format); probe each on a throwaway server
  if have tmux; then
    TERM=xterm tmux -L nvrprobe -f /dev/null new-session -d -x 1 -y 1 >/dev/null 2>&1 || true
    for opt in extended-keys extended-keys-format; do
      if ! tmux -L nvrprobe show-options -s "$opt" >/dev/null 2>&1; then
        sed -i -E "/^[[:space:]]*set[^#]*[[:space:]]-s[[:space:]]${opt}([[:space:]]|$)/d" "$HOME/.tmux.conf"
        info "tmux: dropped unsupported option: $opt"
      fi
    done
    tmux -L nvrprobe kill-server >/dev/null 2>&1 || true
  fi
  ok "tmux.conf (bash default, local-only bits stripped)"
}

configure_bashrc() {
  local rc="$HOME/.bashrc"
  local pbegin="# >>> code-remote: path >>>" pend="# <<< code-remote: path <<<"
  local begin="# >>> code-remote >>>" end="# <<< code-remote <<<"
  # strip every previous managed block (legacy single block + both new ones)
  [ -f "$rc" ] || touch "$rc"
  # NB: $pend must NOT appear in the begin-rule — it would re-arm skip and eat
  # everything after the path block on the next run
  awk -v pbs="$pbegin" -v pes="$pend" -v bs="$begin" -v es="$end" \
    '$0 == pbs || $0 == bs { skip = 1; next }
     skip && ($0 == pes || $0 == es) { skip = 0; next }
     !skip { print }' "$rc" > "$rc.nvr" && mv "$rc.nvr" "$rc"
  # local-only bits from the pushed ~/.bashrc: fastfetch is not provisioned
  # on remotes; direnv/starship/fzf eval lines are stripped here and re-added
  # by the managed block below (with 2>/dev/null fallbacks). Patterns
  # deliberately require the closing paren so the managed block lines never
  # match.
  sed -i -E \
    -e '/^fastfetch$/d' \
    -e '/^# Start fastfetch$/d' \
    -e '/eval "\$\(direnv hook bash\)"/d' \
    -e '/^# Enable direnv/d' \
    -e '/eval "\$\(starship init bash\)"/d' \
    -e '/^# Start Starship$/d' \
    -e '/eval "\$\(fzf --bash\)"/d' \
    -e '/^# Set up fzf key bindings and fuzzy completion$/d' \
    "$rc"
  # PATH block goes on line 1, BEFORE the distro "return unless interactive"
  # guard: non-interactive ssh commands (code-remote connect, ssh host tool)
  # read .bashrc but bail at that guard, so PATH must be set above it
  local tmp="$rc.nvr"
  {
    printf '%s\nexport PATH="$HOME/.local/bin:$HOME/scripts:$PATH"\n%s\n' "$pbegin" "$pend"
    cat -s "$rc"
    printf '%s\n# API keys synced by code-remote (plain env file)\n[ -r "$HOME/.config/code-remote/passenv" ] && . "$HOME/.config/code-remote/passenv"\n# nix (flakes) + direnv — provisioned by bootstrap; dev shells via .envrc `use flake`\n[ -r /etc/profile.d/nix.sh ] && . /etc/profile.d/nix.sh\n[ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ] && . "$HOME/.nix-profile/etc/profile.d/nix.sh"\neval "$(direnv hook bash 2>/dev/null)"\neval "$(starship init bash 2>/dev/null)"\neval "$(fzf --bash 2>/dev/null)"\n%s\n' "$begin" "$end"
  } > "$tmp" && mv "$tmp" "$rc"
  ok "bashrc managed blocks written"
}

install_tmux_plugins() {
  local tpm="$HOME/.tmux/plugins/tpm" conf="$HOME/.tmux.conf" line plug name dir
  if [ ! -d "$tpm" ]; then
    git clone -q https://github.com/tmux-plugins/tpm "$tpm"
  fi
  if [ -f "$conf" ]; then
    while IFS= read -r line; do
      plug="$(printf '%s' "$line" | sed -E "s/^set -g @plugin ['\"]([^'\"]+)['\"].*/\1/")"
      [ "$plug" = "tmux-plugins/tpm" ] && continue
      name="${plug##*/}"
      dir="$HOME/.tmux/plugins/$name"
      [ -d "$dir" ] || git clone -q "https://github.com/$plug" "$dir"
    done < <(grep -E "^set -g @plugin" "$conf" || true)
  fi
  ok "tmux plugins"
}

install_nvim_plugins() {
  if [ ! -d "$HOME/.config/nvim" ]; then warn "no nvim config synced — skipping"; return; fi
  if nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
    ok "nvim plugins (lazy sync, pinned by lazy-lock.json)"
  else
    warn "lazy sync failed — check network, run manually: nvim --headless '+Lazy! sync'"
  fi
}

# --- main ---------------------------------------------------------------------
case "$MODE" in
  tools)
    ensure_base
    install_nvim
    install_node
    install_statics
    install_direnv
    install_nix
    install_pi
    ;;
  configs)
    install_clipboard_shim
    install_notify_shim
    configure_tmux
    configure_bashrc
    install_tmux_plugins
    install_nvim_plugins
    ;;
  all)
    ensure_base
    install_nvim
    install_node
    install_statics
    install_direnv
    install_nix
    install_clipboard_shim
    install_notify_shim
    install_pi
    configure_tmux
    configure_bashrc
    install_tmux_plugins
    install_nvim_plugins
    ;;
  *)
    die "usage: bootstrap.sh [all|tools|configs]"
    ;;
esac

info "bootstrap ($MODE) done."
