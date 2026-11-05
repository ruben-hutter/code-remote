# Wrapper around bin/code-remote (see README.md)
default:
    @just --list

# full setup on a host: repo on host + nix + home-manager + pi + credentials
# (idempotent — re-run to update the host and re-sync keys)
bootstrap host:
    bin/code-remote {{host}}
