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
      url = "git+https://github.com/ruben-hutter/nixos-config";
      flake = false;
    };

    # live desktop dotfiles — nvim config single source of truth (remotes get
    # exactly what the fedora machine runs); bump with `nix flake update cfg`
    cfg = {
      url = "git+https://github.com/ruben-hutter/.cfg";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, home-manager, scripts, skills, nixos-config, cfg }:
    let
      mkRemoteHome = system: home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = { inherit scripts skills nixos-config cfg; };
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
