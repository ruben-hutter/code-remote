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

    # ~/.agents/skills on the remote (agent skills; the skills/ subdir of the repo)
    skills = {
      url = "github:ruben-hutter/skills";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, home-manager, scripts, skills }:
    let
      # The declarative remote environment: headless, bash-first, nvim/tmux/
      # starship/direnv/flakes + lean tool set. Vendored configs live in ./home
      # (nvim/, assets/) — sync them from the desktop with ./bin/vendor.
      mkRemoteHome = system: home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        extraSpecialArgs = { inherit scripts skills; };
        modules = [ ./home/remote-default.nix ];
      };
    in
    {
      # Dot-free attr names: dots in attr names clash with `nix build .#...`
      # attr-path parsing. x86_64 is the common case, so it gets the short name.
      homeConfigurations = {
        remote = mkRemoteHome "x86_64-linux";
        remote-aarch64 = mkRemoteHome "aarch64-linux";
      };
    };
}
