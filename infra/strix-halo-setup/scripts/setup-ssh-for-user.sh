#!/bin/bash
# setup-ssh-for-user — called by adduser.local for new users.
# Creates /etc/ssh/users/<user>/.ssh/ directory structure.
# Does NOT populate authorized_keys (no SSH access granted by default).

set -euo pipefail

USER="$1"

[ -n "$USER" ] || exit 0

SSH_BASE="/etc/ssh/users/${USER}/.ssh"

# Idempotent: skip if already exists
[ -d "$SSH_BASE" ] && exit 0

mkdir -p "$SSH_BASE"
chown "${USER}:${USER}" "/etc/ssh/users/${USER}" "$SSH_BASE"
chmod 700 "/etc/ssh/users/${USER}" "$SSH_BASE"

# Create empty authorized_keys with correct permissions
touch "${SSH_BASE}/authorized_keys"
chown "${USER}:${USER}" "${SSH_BASE}/authorized_keys"
chmod 600 "${SSH_BASE}/authorized_keys"
