# Declarative remote environment for non-NixOS coding VMs: headless,
# bash-first, shared configs (nvim, starship.toml, lfrc, btop/htop) from the
# nixos-config flake input — one canonical copy, pinned by flake.lock.
#
# Host identity (username/homeDirectory) comes from home/remote-user.nix,
# written and STAGED by the bootstrap on the target host — a flake in a git
# tree is sourced from the git index, so an untracked file would be invisible
# to nix. Falls back to ruben so the flake still evaluates locally.
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
    else {
      name = "ruben";
      home = "/home/ruben";
    };

  # judge model for the glm-auto.ts pi extension (synced from the local
  # machine's ~/.pi/agent/extensions by bin/code-remote) — must match the
  # extension's PI_AUTO_JUDGE_MODEL default; change both together
  glmJudgeModel = "qwen2.5:1.5b-instruct";
in
{
  home.username = remoteUser.name;
  home.homeDirectory = remoteUser.home;
  home.stateVersion = "25.11";

  home.sessionVariables.EDITOR = "nvim";

  # Explicit PATH order (not sessionPath): ~/.local/bin must stay FIRST so
  # the wl-copy OSC52 shim shadows the profile's real wl-copy on headless
  # hosts; ~/.nix-profile/bin is spelled out so PATH never depends on the
  # system nix profile.d script (absent on single-user nix installs).
  home.sessionVariables.PATH =
    "$HOME/.local/bin:$HOME/.pi/agent/bin:$HOME/.nix-profile/bin:$PATH";

  # git — same settings as the desktop, except signing off (no gpg keys on
  # remotes). bootstrap.sh seeds the same identity pre-activation; keep the
  # two in sync.
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

  # nvim: full config from the nixos-config input (below, in home.file),
  # store-symlinked; plugins resolved at runtime by lazy.nvim, pinned by its
  # lazy-lock.json. No embedded interpreters on headless remotes.
  programs.neovim = {
    enable = true;
    withRuby = false;
    withPython3 = false;
  };

  # HM-managed files (one home.file definition — same-module duplicates are
  # a module-system error):
  # - nvim config + starship.toml from the nixos-config input
  # - ~/scripts: executables from the scripts input (cht.sh, tmux session
  #   manager, wtree, ...)
  # - ~/.agents/skills: the skills/ subtree — one store symlink, read-only
  #   by design (update via `nix flake update` + re-run bootstrap)
  # - ~/.local/bin/wl-copy: OSC52 clipboard shim (see inside)
  home.file = {
    ".config/nvim".source = nixos-config + "/home/programs/nvim";
    ".config/starship.toml".source = nixos-config + "/home/programs/assets/starship.toml";
    ".agents/skills".source = "${skills}/skills";
    ".local/bin/wl-copy" = {
      text = ''
        #!/bin/sh
        # Headless hosts have no clipboard — pipe selections to tmux, which
        # forwards them to the attached terminal as OSC52 (load-buffer -w).
        # On a real Wayland session, defer to the real wl-copy (looked up in
        # fixed dirs, NOT via PATH — that would recurse onto this shim).
        if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
            for d in "$HOME/.nix-profile/bin" /usr/bin /usr/local/bin /bin; do
                [ -x "$d/wl-copy" ] && exec "$d/wl-copy" "$@"
            done
        fi
        exec tmux load-buffer -w -
      '';
      executable = true;
    };
    # `wtree` as a plain command: ~/.local/bin is first on PATH, so agents'
    # non-interactive shells (which don't source the alias layer) and humans
    # get it alike. Points at the same store file as ~/scripts/wtree.sh.
    ".local/bin/wtree".source = scripts + "/wtree.sh";
  } // builtins.listToAttrs (
    map (script: {
      name = "scripts/${script}";
      value = {
        source = scripts + "/${script}";
        executable = true;
      };
    }) (builtins.attrNames (builtins.readDir scripts))
  );

  # bash — the interactive shell on remotes (no fish)
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
      # hm-session-vars.sh (PATH incl. the shims + pi, EDITOR, ...) is only
      # sourced by ~/.profile (login shells); tmux panes run interactive
      # NON-LOGIN shells and would never see it — source it here too.
      [ -r "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ] && \
        . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"

      bind "set completion-ignore-case on"

      # personal aliases, pushed by bin/code-remote (data, not logic — outside HM)
      [ -r "$HOME/.bashrc-personal" ] && . "$HOME/.bashrc-personal"

      # tm — tmux session picker, no-op inside tmux. Must be a FUNCTION, not
      # an alias: an alias tm=… expands while this very definition line is
      # parsed, mangling it into an invalid identifier — which kills the
      # inside-tmux guard and runs the picker on every pane.
      tm() { [ -n "''${TMUX:-}" ] || "$HOME/scripts/tmux_session_manager.sh" "$@"; }

      # drop new plain ssh shells straight into the session picker; inside
      # tmux the guard makes this a no-op, and `ssh host cmd` never loads
      # the interactive bashrc at all
      tm
    '';
  };

  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = false;
  };

  programs.fzf.enable = true;

  # direnv + nix-direnv: `use flake` dev shells, cached so a VPS doesn't
  # re-evaluate on every cd
  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  # the nix daemon is installed by the bootstrap; this is just the HM-managed
  # CLI in the profile (required by the module, keeps `nix` on PATH)
  nix = {
    enable = true;
    package = pkgs.nix;
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  # tmux — bash panes, OSC52 yank for headless hosts (see wl-copy shim)
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

      # OSC52 clipboard: tmux only forwards buffers when the OUTER terminal
      # advertises the Ms capability — stock terminfo does not, so declare it
      # (canonical xterm format; do NOT hardcode "c;" in the middle: strict
      # terminals misparse the resulting 4-field sequence). set-clipboard on
      # makes tmux also push its own buffer changes (the wl-copy shim's
      # load-buffer -w) as OSC52 to the attached terminal.
      set -as terminal-overrides ',*:Ms=\E]52;%p1%s;%p2%s\7'
      set -s set-clipboard on

      # OSC52 yank — explicit, NOT the tmux-yank plugin: the plugin detects
      # wl-copy via $WAYLAND_DISPLAY/$DISPLAY, which a headless host never
      # has, so its `y` binding would pipe to nothing. Pipe copy-mode y and
      # mouse drag through the shim instead (~/.local/bin/wl-copy).
      set -g copy-command "tmux load-buffer -w -"
      bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -"
      bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "tmux load-buffer -w -"

      set-environment -g COLORTERM truecolor
      # same order as sessionVariables.PATH above; $PATH here is the login
      # shell's startup PATH (profile already sourced)
      set-environment -g PATH "$HOME/.local/bin:$HOME/.pi/agent/bin:$HOME/.nix-profile/bin:$PATH"

      # bash-first, whatever the login shell says
      set -g default-shell /bin/bash
      set -g default-command /bin/bash

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

      # Vi copy mode — keep `y`/mouse-drag on the OSC52 pipe (rebinding them
      # to plain copy-selection silently disables clipboard forwarding)
      bind -T copy-mode-vi 'v' send -X begin-selection

      # Custom scripts (~/scripts, from the scripts flake input)
      bind i run-shell "tmux neww $HOME/scripts/cht.sh"
      bind -n M-f display-popup -E -w 60% -h 60% $HOME/scripts/tmux_session_manager.sh

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

  # small desktop-parity tools
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

  # btop/htop rewrite their configs on every in-TUI change — seed the shared
  # versions once, then the tools own them
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

  # --- ollama: local judge for the glm-auto.ts pi extension --------------------
  # The extension (synced by bin/code-remote) routes zai/auto prompts;
  # ambiguous-length ones are judged by this local model — free, private, no
  # API round-trip. Without the service the extension still works, via a
  # remote glm-5.3-flash judge call. CPU-only ollama build: the 1.5B judge
  # needs no GPU. Mirrors the extension's documented manual Ollama setup.
  systemd.user.services.ollama = {
    Unit.Description = "Ollama LLM server (local judge for the glm-auto pi extension)";
    Service = {
      ExecStart = "${pkgs.ollama}/bin/ollama serve";
      Environment = [
        "OLLAMA_HOST=127.0.0.1:11434"
        "OLLAMA_MODELS=%h/.local/share/ollama/models"
      ];
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Enable/start the service and pull the judge model once (~1GB, Q4 —
  # cached afterwards, so re-running bootstrap is a cheap no-op). Ordered
  # after reloadSystemD so the unit is live before we poke systemctl.
  # Best-effort: a missing user systemd session or a failed pull warns
  # instead of aborting the whole activation.
  home.activation.ollamaJudgeModel = lib.hm.dag.entryAfter [ "reloadSystemD" ] ''
    if command -v systemctl >/dev/null; then
      systemctl --user enable --now ollama.service >/dev/null 2>&1 || true
    fi
    for _ in 1 2 3 4 5; do # give a fresh service a moment to listen
      $DRY_RUN_CMD ${pkgs.ollama}/bin/ollama list >/dev/null 2>&1 && break
      sleep 1
    done
    if ! $DRY_RUN_CMD ${pkgs.ollama}/bin/ollama list 2>/dev/null | grep -q '^${glmJudgeModel}'; then
      if $DRY_RUN_CMD ${pkgs.ollama}/bin/ollama pull ${glmJudgeModel}; then
        printf '  ✓ judge model pulled (%s)\n' "${glmJudgeModel}"
      else
        printf '  ! judge model pull failed (is ollama.service up? run: ollama pull ${glmJudgeModel})\n' >&2
      fi
    fi
  '';

  # lean, headless set — GUI-heavy desktop stuff stays in nixos-config
  home.packages = with pkgs; [
    # nvim runtime deps: gcc (treesitter parser + mason builds), unzip
    # (mason installs), wl-clipboard (clipboard registers; OSC52 shim for
    # tmux yank), tree-sitter
    gcc
    unzip
    wl-clipboard
    tree-sitter

    # pi runtime (pi itself is installed imperatively by the bootstrap)
    nodejs

    # local judge server for the glm-auto extension (systemd user service +
    # activation hook above); CPU-only build — the judge model needs no GPU
    ollama

    # LSPs mason can NOT build on lean hosts (no go/cargo on PATH); the
    # nvim config's ensure_installed deliberately omits them
    gopls
    nil

    # utilities
    wget
    curl
    tree
    ripgrep
    fd
    jq
    zip
    htop

    # pure HTTPS API client — auth provisioned by bin/code-remote (PAT from
    # local pass → `gh auth login --with-token`)
    gh
  ];
}
