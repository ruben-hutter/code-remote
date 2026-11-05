# Declarative remote environment for NON-NixOS coding VMs, provisioned by
# this repo's bootstrap. Self-contained: no dependency on the nixos-config
# repo — shared configs (nvim, starship.toml, lfrc, btop/htop) come from the
# nixos-config flake input, pinned by flake.lock (one canonical copy, no
# duplication; bump with `nix flake update nixos-config`).
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
  nixos-config,
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
  # runtime on PATH; shims (wl-copy OSC) also live in ~/.local/bin
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

  # === NVIM — full config from the nixos-config flake input, store-symlinked;
  # plugins are resolved at runtime by lazy.nvim, pinned by its lazy-lock.json.
  programs.neovim.enable = true;
  # headless remotes: no embedded interpreters (also silences the nixpkgs
  # eval warnings about these defaults having flipped)
  programs.neovim.withRuby = false;
  programs.neovim.withPython3 = false;

  # Runtime deps for the shared config:
  # - gcc: nvim-treesitter compiles parsers; mason builds some LSP servers
  # - unzip: mason package installs
  # - wl-clipboard: nvim clipboard registers (headless remotes use the OSC52
  #   shim for tmux yank; inside nvim it just stays a no-op binary)
  # === HM-MANAGED FILES (one home.file definition — same-module duplicates are
  # a module-system error) ===
  # nvim: full config from the nixos-config input, store-symlinked; plugins
  # resolved at runtime by lazy.nvim, pinned by its lazy-lock.json.
  # ~/scripts: flat executables from the scripts flake input (cht.sh, tmux
  # session manager, wtree, ...). The walrus hook script is installed too but
  # NOT wired anywhere — remotes have no pass/walrus.
  # ~/.agents/skills: the skills/ subtree of the skills flake input — one
  # store symlink, read-only by design (skills are data; update via
  # `nix flake update` + re-run bootstrap).
  # ~/.local/bin/wl-copy: OSC52 clipboard shim, declared here (not installed
  # by the bootstrap) so the whole remote env stays in the flake. PATH puts
  # ~/.local/bin first, so on headless hosts this shadows the profile's real
  # wl-copy and tmux pipes copies through it. Runtime behavior: on a real
  # Wayland session defer to the real wl-copy (checked in the profile dir,
  # NOT via PATH — that would recurse onto this shim), else feed tmux.
  home.file = {
    ".config/nvim".source = nixos-config + "/home/programs/nvim";
    ".config/starship.toml".source = nixos-config + "/home/programs/assets/starship.toml";
    ".agents/skills".source = "${skills}/skills";
    ".local/bin/wl-copy" = {
      text = ''
        #!/bin/sh
        # code-remote: OSC52 clipboard shim (HM-managed). Inside tmux on a
        # headless host there is no usable clipboard, so pipe selections to
        # `tmux load-buffer -w -` and let tmux forward them to the attached
        # terminal as OSC52 (tmux >= 3.3, Ms override + set-clipboard on).
        if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
            for d in "$HOME/.nix-profile/bin" /usr/bin /usr/local/bin /bin; do
                [ -x "$d/wl-copy" ] && exec "$d/wl-copy" "$@"
            done
        fi
        exec tmux load-buffer -w -
      '';
      executable = true;
    };
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

      # Personal aliases, pushed by bin/code-remote (data, not logic — outside HM)
      [ -r "$HOME/.bashrc-personal" ] && . "$HOME/.bashrc-personal"

      # tm — tmux session picker, no-op inside tmux (same as the fish `tm` on
      # the laptop). Defined as a function, not a shellAlias, so the guard is
      # part of the name.
      tm() { [ -n "''${TMUX:-}" ] || "$HOME/scripts/tmux_session_manager.sh" "$@"; }

      # Drop new plain shells (ssh logins) straight into the tmux session
      # picker — inside tmux `tm` is a no-op, so tmux panes/windows are
      # unaffected. bashrc only loads for interactive shells (HM guard), so
      # `ssh host cmd` never triggers this.
      tm
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
      # do nothing. Declare Ms for every outer terminal using the canonical
      # xterm format `ESC]52;<selection>;<base64>` — do NOT hardcode "c;" in
      # the middle (produces 4-field `52;c;;<b64>`, which strict terminals
      # misparse into the wrong selection).
      set -as terminal-overrides ',*:Ms=\E]52;%p1%s;%p2%s\7'
      # set-clipboard=external (default) only forwards OSC52 from apps INSIDE
      # tmux; with "on" tmux also pushes its own buffer changes (load-buffer
      # -w, i.e. the wl-copy shim) as OSC52 to the attached terminal.
      set -s set-clipboard on

      # OSC52 yank — explicit, NOT the tmux-yank plugin: the plugin detects
      # wl-copy via $WAYLAND_DISPLAY/$DISPLAY, which a headless host never
      # has, so its `y` binding pipes to nothing. Here copy-mode `y` and the
      # mouse drag-end pipe through the shim (~/.local/bin/wl-copy → tmux
      # load-buffer -w → OSC52 above).
      set -g copy-command "tmux load-buffer -w -"
      bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -"
      bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -"

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

      # Vi copy mode bindings — `y` and mouse-drag copy-pipe through the
      # OSC52 shim (see copy-command/binds at the top of this file; do NOT
      # rebind them to plain copy-selection here — that silently disables
      # clipboard forwarding on headless hosts)
      bind -T copy-mode-vi 'v' send -X begin-selection
      bind -T copy-mode-vi 'y' send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -"
      bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -"

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
  programs.lf.extraConfig = builtins.readFile (nixos-config + "/home/programs/assets/lfrc");
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
  # seeded from the shared versions (nixos-config input) and then owned by
  # the tools.
  programs.btop.enable = true;
  home.activation.btopConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CONFIG="$HOME/.config/btop/btop.conf"
    if [ ! -f "$CONFIG" ]; then
      $DRY_RUN_CMD mkdir -p "$HOME/.config/btop"
      $DRY_RUN_CMD install -m 644 ${nixos-config + "/home/programs/assets/btop.conf"} "$CONFIG"
    fi
  '';

  home.activation.htopConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    RC="$HOME/.config/htop/htoprc"
    if [ ! -f "$RC" ]; then
      $DRY_RUN_CMD mkdir -p "$HOME/.config/htop"
      $DRY_RUN_CMD install -m 644 ${nixos-config + "/home/programs/assets/htoprc"} "$RC"
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

    # LSPs mason can NOT install on lean hosts (it builds them with go/cargo,
    # neither on PATH here) — from nixpkgs instead; the nvim config's mason
    # ensure_installed list deliberately omits them (see nixos-config
    # lsp.lua)
    gopls
    nil

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
