# Declarative remote environment for NON-NixOS coding VMs, provisioned by
# this repo's bootstrap. Self-contained: no dependency on the nixos-config
# repo — shared configs (nvim, starship.toml, lfrc, btop/htop) are vendored
# into ./home (sync from the desktop checkout with ./bin/vendor).
#
# Headless and bash-first (no fish on remotes). Host identity (username/
# homeDirectory) comes from home/remote-user.nix, written by the bootstrap
# on the target host and STAGED there — a flake in a git tree is sourced
# from the git index, so an untracked file would be invisible to nix:
#   { name = "ruben"; home = "/home/ruben"; }
# Falls back to ruben so the flake still evaluates on the dev box.
{
  config,
  pkgs,
  lib,
  # flake inputs, passed via extraSpecialArgs from flake.nix
  scripts,
  skills,
  ...
}:

let
  remoteUser =
    if builtins.pathExists ./remote-user.nix
    then import ./remote-user.nix
    else
      {
        name = "ruben";
        home = "/home/ruben";
      };
in
{
  home.username = remoteUser.name;
  home.homeDirectory = remoteUser.home;
  home.stateVersion = "25.11";

  home.sessionVariables.EDITOR = "nvim";

  # Remotes run pi (installed by bootstrap into ~/.pi/agent/bin) and need its
  # runtime on PATH; shims (wl-copy/notify-send OSC) also live in ~/.local/bin
  # and MUST shadow the profile's real wl-copy (headless: no Wayland).
  # ~/.nix-profile/bin: the HM generation is registered there by activation
  # (nix-env --profile); explicit here so PATH never depends on the system
  # nix profile.d script (absent on single-user nix installs). Explicit full
  # order instead of home.sessionPath — sessionPath would prepend the profile
  # AFTER this, putting real wl-copy ahead of the shim again.
  home.sessionVariables.PATH =
    "$HOME/.local/bin:$HOME/.pi/agent/bin:$HOME/.nix-profile/bin:$PATH";

  # === GIT — same settings as the desktop, except: no signing on remotes ===
  # (no gpg agent / secret keys provisioned there, by design)
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Ruben Hutter";
        email = "ruben.hutter@rubenhutter.ch";
      };
      commit.gpgSign = false;
      init.defaultBranch = "main";
      pull.rebase = false;
    };
    ignores = [
      "**/.claude/settings.local.json"
    ];
  };

  # === NVIM — full config vendored in ./nvim, store-symlinked; plugins are
  # resolved at runtime by lazy.nvim, pinned by the vendored lazy-lock.json.
  programs.neovim.enable = true;
  # headless remotes: no embedded interpreters (also silences the nixpkgs
  # eval warnings about these defaults having flipped)
  programs.neovim.withRuby = false;
  programs.neovim.withPython3 = false;

  # Runtime deps for the vendored config:
  # - gcc: nvim-treesitter compiles parsers; mason builds some LSP servers
  # - unzip: mason package installs
  # - wl-clipboard: nvim clipboard registers (headless remotes use the OSC52
  #   shim for tmux yank; inside nvim it just stays a no-op binary)
  # === HM-MANAGED FILES (one home.file definition — same-module duplicates are
  # a module-system error) ===
  # nvim: full config vendored in ./nvim, store-symlinked; plugins resolved at
  # runtime by lazy.nvim, pinned by the vendored lazy-lock.json.
  # ~/scripts: flat executables from the scripts flake input (cht.sh, tmux
  # session manager, wtree, ...). The walrus hook script is installed too but
  # NOT wired anywhere — remotes have no pass/walrus.
  # ~/.agents/skills: the skills/ subtree of the skills flake input — one
  # store symlink, read-only by design (skills are data; update via
  # `nix flake update` + re-run bootstrap).
  home.file = {
    ".config/nvim".source = ./nvim;
    ".config/starship.toml".source = ./assets/starship.toml;
    ".agents/skills".source = "${skills}/skills";
  } // builtins.listToAttrs (
    map (script: {
      name = "scripts/${script}";
      value = {
        source = scripts + "/${script}";
        executable = true;
      };
    }) (builtins.attrNames (builtins.readDir scripts))
  );

  # === BASH — the interactive shell on remotes (v1 philosophy: no fish) ===
  programs.bash = {
    enable = true;
    enableCompletion = true;
    historyControl = [ "ignoreboth" "erasedups" ];

    shellAliases = {
      ll = "ls -la";
      la = "ls -a";
      l = "ls";
      "cd.." = "cd ..";
      grep = "grep --color=auto";
      clera = "clear";
      nv = "nvim";

      # Scripts (desktop ports — same name as the fish shellAliases on the laptop)
      tm = "$HOME/scripts/tmux_session_manager.sh";
    };

    initExtra = ''
      # HM session vars (PATH incl. ~/.local/bin + ~/.pi/agent/bin, EDITOR…):
      # hm-session-vars.sh is only sourced by ~/.profile (LOGIN shells), but
      # tmux panes and `ssh host cmd` run INTERACTIVE NON-LOGIN shells that
      # never see it — without this, shims and pi are missing from PATH there.
      [ -r "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ] && \
        . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"

      # Ignore upper and lowercase when TAB completion
      bind "set completion-ignore-case on"

      # Personal aliases, synced by code-remote sync (data, not logic — outside HM)
      [ -r "$HOME/.bashrc-personal" ] && . "$HOME/.bashrc-personal"

      # API keys synced by code-remote sync (plain env file)
      [ -r "$HOME/.config/code-remote/passenv" ] && . "$HOME/.config/code-remote/passenv"
    '';
  };

  # === STARSHIP + FZF (bash integration; HM wires the evals into bashrc) ===
  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = false;
  };
  # starship.toml ported verbatim from the desktop (includes the ssh
  # hostname/container modules, which matter even more on remotes)

  programs.fzf.enable = true;

  # === DIRENV + NIX FLAKES (LiveTogether-style dev shells via `use flake`) ===
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    # cache flake dev shells so a VPS doesn't re-evaluate on every cd
    nix-direnv.enable = true;
  };

  # User-level nix settings — written to ~/.config/nix/nix.conf. The nix
  # daemon itself is installed by the bootstrap (official installer);
  # pkgs.nix here is just the HM-managed CLI in the profile (required by the
  # module, and keeps `nix` on PATH independent of it).
  nix = {
    enable = true;
    package = pkgs.nix;
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  # === TMUX — bash panes, OSC52 yank for headless hosts, no walrus ===
  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    baseIndex = 1;
    escapeTime = 0;
    keyMode = "vi";
    mouse = true;
    prefix = "C-a";

    plugins = with pkgs.tmuxPlugins; [
      sensible
      vim-tmux-navigator
      # yank: copy-mode `y` pipes into wl-copy — on headless hosts that is
      # code-remote's OSC52 shim (~/.local/bin/wl-copy), which forwards the
      # selection to the local machine's clipboard through the terminal.
      yank
      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavour 'mocha'
          set -g @catppuccin_window_status_style "rounded"
        '';
      }
      resurrect
      continuum
    ];

    extraConfig = ''
      # Terminal colors
      set -ga terminal-overrides ",xterm-256color*:Tc"
      set-window-option -g window-style bg=terminal
      set-window-option -g window-active-style bg=terminal

      # OSC52 clipboard: tmux only sends copy-buffer escapes when the OUTER
      # terminal advertises the Ms capability — stock xterm-256color terminfo
      # does not, so `tmux load-buffer -w` (our wl-copy shim) would silently
      # do nothing. Declare Ms for every outer terminal; terminals that can't
      # paste OSC52 just ignore it.
      set -as terminal-overrides ',*:Ms=\E]52;c;%p1%s;%p2%s\7'
      # set-clipboard=external (default) only forwards OSC52 from apps INSIDE
      # tmux; with "on" tmux also pushes its own buffer changes (load-buffer
      # -w, i.e. the wl-copy shim) as OSC52 to the attached terminal.
      set -s set-clipboard on
      # OSC 9/777 notifications: the notify-send shim DCS-wraps its escapes
      # for tmux; passthrough is off by default (tmux >= 3.3) and would drop
      # them. Local terminals without notification support discard these.
      set -g allow-passthrough on

      set-environment -g COLORTERM truecolor
      # pi + OSC shims in ~/.local/bin (pi runtime in ~/.pi/agent/bin), then
      # the HM profile; $PATH here is the server's startup PATH (login shell,
      # profile sourced) — same order as sessionVariables.PATH above
      set-environment -g PATH "$HOME/.local/bin:$HOME/.pi/agent/bin:$HOME/.nix-profile/bin:$PATH"

      # Remotes are bash-first: pin both, whatever the login shell says
      set -g default-shell /bin/bash
      set -g default-command /bin/bash

      # Renumber windows
      set -g renumber-windows on

      # pass modified keys (Alt+Enter etc.) through to TUIs like pi
      set -s extended-keys on
      set -s extended-keys-format csi-u

      # Send prefix
      bind C-a send-prefix

      # Splitting panes
      unbind %
      bind | split-window -h -c "#{pane_current_path}"
      unbind '"'
      bind - split-window -v -c "#{pane_current_path}"

      # Reload config
      unbind r
      bind r source-file ~/.config/tmux/tmux.conf

      # Resize panes
      bind -r j resize-pane -D 5
      bind -r k resize-pane -U 5
      bind -r l resize-pane -R 5
      bind -r h resize-pane -L 5

      bind -r m resize-pane -Z

      # Vi copy mode bindings
      bind -T copy-mode-vi 'v' send -X begin-selection
      bind -T copy-mode-vi 'y' send -X copy-selection
      unbind -T copy-mode-vi MouseDragEnd1Pane

      # Custom scripts (installed to ~/scripts from the scripts flake input)
      bind i run-shell "tmux neww $HOME/scripts/cht.sh"
      bind -n M-f display-popup -E -w 60% -h 60% $HOME/scripts/tmux_session_manager.sh

      # NO walrus session hooks here — remotes have no pass/walrus.

      # Status bar configuration
      set -g status-right-length 100
      set -g status-left-length 100
      set -g status-left ""
      set -g status-right "#{E:@catppuccin_status_application}"
      set -ag status-right "#{E:@catppuccin_status_session}"
      set -ag status-right "#{E:@catppuccin_status_uptime}"
      set -g status on

      # Resurrect and continuum settings
      set -g @resurrect-capture-pane-contents 'on'
      set -g @continuum-restore 'on'
    '';
  };

  # === FILE-MANAGER + SYSTEM MONITORS (desktop parity, small configs) ===
  programs.lf.enable = true;
  programs.lf.extraConfig = builtins.readFile ./assets/lfrc;
  programs.bat.enable = true;
  programs.bat.config.theme = "Catppuccin Mocha";
  programs.lazygit = {
    enable = true;
    settings = {
      gui.skipRewordInEditorWarning = true;
      promptToReturnFromSubprocess = false;
    };
  };

  # btop/htop rewrite their configs on every in-TUI change, so the files are
  # seeded from the vendored versions and then owned by the tools.
  programs.btop.enable = true;
  home.activation.btopConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CONFIG="$HOME/.config/btop/btop.conf"
    if [ ! -f "$CONFIG" ]; then
      $DRY_RUN_CMD mkdir -p "$HOME/.config/btop"
      $DRY_RUN_CMD install -m 644 ${./assets/btop.conf} "$CONFIG"
    fi
  '';

  home.activation.htopConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    RC="$HOME/.config/htop/htoprc"
    if [ ! -f "$RC" ]; then
      $DRY_RUN_CMD mkdir -p "$HOME/.config/htop"
      $DRY_RUN_CMD install -m 644 ${./assets/htoprc} "$RC"
    fi
  '';

  # === ~/.agents/skills — the skills/ subtree of the skills flake input ===
  # One store symlink; read-only by design (skills are data, updated via
  # nix flake update + re-run bootstrap).

  # === PACKAGES (one list — same-module duplicates are a module-system error;
  # lean, GUI-heavy desktop stuff stays in nixos-config) ===
  home.packages = with pkgs; [
    # nvim runtime deps
    gcc # nvim-treesitter compiles parsers; mason builds some LSP servers
    unzip # mason package installs
    wl-clipboard
    tree-sitter # nvim treesitter parser compilation
    htop

    # pi coding agent runtime (pi itself is installed imperatively by the
    # bootstrap: official install.sh → ~/.pi/agent/bin)
    nodejs

    # utilities
    wget
    curl
    tree
    ripgrep
    fd
    jq
    unzip
    zip
  ];
}
