# remove-user / restore-user TODO

## Idempotent restore (--merge / --overwrite)

Currently restore fails if the user, uid, or gid already exists. A
`--merge` or `--overwrite` mode would handle partial restores (e.g.
user exists but home dir is gone, or uid was reused and needs force).

## Archive encryption

The tarball contains shadow hashes (with `--save-shadow`) and SSH keys.
Encrypting at rest with `gpg --symmetric` or `age` would protect
sensitive data in `/var/backups/removed-users/`.

## Retention policy

`/var/backups/removed-users/` accumulates tarballs indefinitely. Add a
`--prune-older-than 90d` flag to `restore-user.sh --list` (or a
standalone cleanup mode) to delete stale archives.

## Audit log

A single append-only log (`/var/log/user-lifecycle.log`) recording all
remove/restore operations with timestamps, operator, and outcome would
be useful for compliance and forensics.

## Shell completion

Bash/zsh completion scripts for all flags. Low priority but nice for
discoverability.
