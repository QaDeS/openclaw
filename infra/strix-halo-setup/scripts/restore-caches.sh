#!/bin/bash
# restore-caches.sh — Restore apt debs from CACHE_DIR to the system cache.
#
# Usage: sudo ./scripts/restore-caches.sh [CACHE_DIR]
#        Default CACHE_DIR: .cache/ (alongside provision script)
#
# Everything else in CACHE_DIR is used directly by the provision script:
#   UV_CACHE_DIR / PIP_CACHE_DIR → uv/pip read from CACHE_DIR/{uv,pip}/
#   cached_git_clone             → reads from CACHE_DIR/repos/
#   cached_podman_ensure         → reads from CACHE_DIR/podman/
#   cached_apt_install           → reads from CACHE_DIR/apt/
#
# So this script only needs to pre-seed the system apt cache (which lives
# outside CACHE_DIR at /var/cache/apt/archives/).

set -eo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${1:-${INFRA_DIR}/.cache}"

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0 [CACHE_DIR]"; exit 1; }

log() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

# Validate cache directory
if [ ! -d "$CACHE_DIR" ]; then
    echo "ERROR: Cache directory not found: $CACHE_DIR"
    exit 1
fi

if [ -f "$CACHE_DIR/manifest.txt" ]; then
    log "Cache manifest:"
    grep "^#" "$CACHE_DIR/manifest.txt" | sed 's/^# /  /'
    echo ""
fi

# Restore apt debs to system cache
if [ -d "$CACHE_DIR/apt" ] && [ -n "$(ls -A "$CACHE_DIR/apt"/*.deb 2>/dev/null)" ]; then
    count=$(ls -1 "$CACHE_DIR/apt"/*.deb | wc -l)
    log "Restoring $count apt deb(s) to /var/cache/apt/archives/"
    cp -n "$CACHE_DIR/apt"/*.deb /var/cache/apt/archives/ 2>/dev/null || true
else
    warn "No apt debs found in $CACHE_DIR/apt/"
fi

# Verify other cache subdirs exist (informational)
for subdir in uv pip repos podman; do
    if [ -d "$CACHE_DIR/$subdir" ]; then
        log "Found $subdir cache ($(du -sh "$CACHE_DIR/$subdir" | cut -f1))"
    fi
done

echo ""
log "Restore complete. Run provisioning with:"
log "  sudo ./provision_strix_halo.sh --cache-dir=$CACHE_DIR --force"
