{
  description = "code-remote — self-contained home-manager env for remote coding VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ~/scripts on the remote (cht.sh, tmux session manager, wtree)
    scripts = {
      url = "github:ruben-hutter/scripts";
      flake = false;
    };

    # ~/.agents/skills on the remote
    skills = {
      url = "github:ruben-hutter/skills";
      flake = false;
    };

    # shared desktop configs (starship.toml, lfrc, btop/htop) — headless
    # variants of the desktop ones; bump with `nix flake update nixos-config`
    nixos-config = {
      url = "github:ruben-hutter/nixos-config";
      flake = false;
    };

    # nvim 0.11 for remotes: nvim-treesitter `master` (pinned by .cfg's
    # lazy-lock.json) crashes on nvim >= 0.12 (languagetree 'range' nil),
    # and the fedora desktop runs 0.11.x — keep remotes on the same major.
    # 25.11 ships 0.11.7 and substitutes from cache.nixos.org (25.05's
    # expression misses the cache and can't build under nix >= 2.3x).
    nixpkgs-nvim.url = "github:NixOS/nixpkgs/nixos-25.11";

    # live desktop dotfiles — nvim config single source of truth (remotes get
    # exactly what the fedora machine runs); bump with `nix flake update cfg`
    cfg = {
      url = "github:ruben-hutter/.cfg";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, home-manager, scripts, skills, nixos-config, cfg
    , nixpkgs-nvim }:
    let
      mkRemoteHome = system: home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = { inherit scripts skills nixos-config cfg nixpkgs-nvim; };
        modules = [ ./home/remote-default.nix ];
      };
    in
    {
      # no dots in attr names — they clash with `nix build .#...` attr-path
      # parsing; x86_64 is the common case, so it gets the short name
      homeConfigurations = {
        remote = mkRemoteHome "x86_64-linux";
        remote-aarch64 = mkRemoteHome "aarch64-linux";
      };
    };
}
