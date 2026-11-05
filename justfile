# Wrapper around bin/code-remote (see README.md)
default:
    @just --list

# full setup on a host (idempotent — re-run to update and re-sync keys)
bootstrap host:
    bin/code-remote {{host}}
