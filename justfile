# Wrapper around bin/code-remote (see README.md)
default:
    @just --list

# full setup on a host: nix + home-manager + pi
bootstrap host *args:
    bin/code-remote {{host}} bootstrap {{args}}

# push credentials/data (run once after bootstrap)
sync host *args:
    bin/code-remote {{host}} sync {{args}}

# ssh + tmux session picker (default command)
connect host *args:
    bin/code-remote {{host}} connect {{args}}

# re-vendor desktop configs from nixos-config into home/
vendor src="~/repos/nixos-config/master":
    bin/vendor {{src}}
