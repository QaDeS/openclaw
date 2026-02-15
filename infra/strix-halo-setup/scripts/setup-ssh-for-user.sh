#!/bin/bash
# setup-ssh-for-user — called by adduser.local for new users.
# Creates /etc/ssh/users/<user>/ with an empty authorized_keys file.
# Keys live outside encrypted home so they survive reboots.
# Does NOT populate authorized_keys (no SSH access granted by default).

set -euo pipefail

USER="$1"

[ -n "$USER" ] || exit 0

USER_DIR="/etc/ssh/users/${USER}"

# Idempotent: skip if already exists
[ -f "${USER_DIR}/authorized_keys" ] && exit 0

mkdir -p "$USER_DIR"
chown "${USER}:${USER}" "$USER_DIR"
chmod 700 "$USER_DIR"

# Create empty authorized_keys with correct permissions
touch "${USER_DIR}/authorized_keys"
chown "${USER}:${USER}" "${USER_DIR}/authorized_keys"
chmod 600 "${USER_DIR}/authorized_keys"
