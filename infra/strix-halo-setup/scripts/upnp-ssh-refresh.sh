#!/bin/bash
# upnp-ssh-refresh — Refresh UPnP port mapping for SSH.
# Reads config from /etc/default/upnp-ssh.

set -euo pipefail

CONFIG="/etc/default/upnp-ssh"
[ -f "$CONFIG" ] || { echo "Missing config: $CONFIG"; exit 1; }
source "$CONFIG"

[ -n "${SSH_UPNP_PORT:-}" ] || { echo "SSH_UPNP_PORT not set"; exit 1; }

INTERNAL_PORT=22
LEASE_DURATION=3600  # 1 hour; timer refreshes every 30 min

# Delete existing mapping (ignore errors)
upnpc -d "$SSH_UPNP_PORT" TCP 2>/dev/null || true

# Add new mapping
upnpc -e "SSH Strix Halo" -r "$INTERNAL_PORT" "$SSH_UPNP_PORT" TCP "$LEASE_DURATION"

echo "UPnP: mapped external port ${SSH_UPNP_PORT}/tcp → internal port ${INTERNAL_PORT}/tcp (lease ${LEASE_DURATION}s)"
