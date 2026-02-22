#!/bin/bash
# backup-caches.sh — Populate CACHE_DIR from the live system's caches.
#
# Usage: sudo ./scripts/backup-caches.sh [CACHE_DIR]
#        Default CACHE_DIR: .cache/ (alongside provision script)
#
# After running, CACHE_DIR contains everything needed for a fast re-provision
# on a new machine: apt debs, uv/pip caches, git bare repos, and podman images.

set -eo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${1:-${INFRA_DIR}/.cache}"

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0 [CACHE_DIR]"; exit 1; }

log() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

mkdir -p "$CACHE_DIR"

# --- 1. apt debs ---
log "Backing up apt debs..."
mkdir -p "$CACHE_DIR/apt"
count=0
for deb in /var/cache/apt/archives/*.deb; do
    [ -f "$deb" ] || continue
    base=$(basename "$deb")
    if [ ! -f "$CACHE_DIR/apt/$base" ]; then
        cp "$deb" "$CACHE_DIR/apt/$base"
        count=$((count + 1))
    fi
done
log "  Copied $count new deb(s) to $CACHE_DIR/apt/"

# --- 2. uv cache ---
log "Backing up uv cache..."
mkdir -p "$CACHE_DIR/uv"
# Check if provisioning already redirected the cache
if [ -d "$CACHE_DIR/uv" ] && [ -n "$(ls -A "$CACHE_DIR/uv" 2>/dev/null)" ]; then
    log "  uv cache already in CACHE_DIR ($(du -sh "$CACHE_DIR/uv" | cut -f1))"
else
    # Fall back to the comfyui user's default cache location
    local_uv="/home/comfyui/.cache/uv"
    if [ -d "$local_uv" ]; then
        rsync -a "$local_uv/" "$CACHE_DIR/uv/"
        log "  Synced from $local_uv ($(du -sh "$CACHE_DIR/uv" | cut -f1))"
    else
        log "  No uv cache found to back up"
    fi
fi

# --- 3. pip cache ---
log "Backing up pip cache..."
mkdir -p "$CACHE_DIR/pip"
if [ -d "$CACHE_DIR/pip" ] && [ -n "$(ls -A "$CACHE_DIR/pip" 2>/dev/null)" ]; then
    log "  pip cache already in CACHE_DIR ($(du -sh "$CACHE_DIR/pip" | cut -f1))"
else
    local_pip="/home/comfyui/.cache/pip"
    if [ -d "$local_pip" ]; then
        rsync -a "$local_pip/" "$CACHE_DIR/pip/"
        log "  Synced from $local_pip ($(du -sh "$CACHE_DIR/pip" | cut -f1))"
    else
        log "  No pip cache found to back up"
    fi
fi

# --- 4. podman images ---
log "Backing up podman images..."
mkdir -p "$CACHE_DIR/podman"

save_user_images() {
    local user="$1"
    if ! id "$user" &>/dev/null; then
        return
    fi
    local uid
    uid=$(id -u "$user")
    local rtdir="/run/user/${uid}"

    # List all images for this user
    local images
    images=$(sudo -u "$user" XDG_RUNTIME_DIR="$rtdir" podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' || true)

    if [ -z "$images" ]; then
        log "  No images for user $user"
        return
    fi

    for image in $images; do
        local safe_name="${image//\//_}"
        safe_name="${safe_name//:/_}"
        local archive="$CACHE_DIR/podman/${safe_name}.tar"
        if [ -f "$archive" ]; then
            log "  Already cached: $image"
            continue
        fi
        log "  Saving $image → $archive"
        sudo -u "$user" XDG_RUNTIME_DIR="$rtdir" podman save -o "$archive" "$image" || {
            warn "  Failed to save $image"
            rm -f "$archive"
        }
    done
}

for user in hosting ddns claw; do
    save_user_images "$user"
done

# --- 5. git repos ---
# Already populated in CACHE_DIR/repos/ by cached_git_clone during provisioning.
if [ -d "$CACHE_DIR/repos" ]; then
    log "Git bare repos already in CACHE_DIR/repos/ ($(du -sh "$CACHE_DIR/repos" | cut -f1))"
else
    log "No git repo cache found (will be populated on next provision with CACHE_DIR)"
fi

# --- 6. Write manifest ---
log "Writing manifest..."
{
    echo "# backup-caches manifest"
    echo "# timestamp: $(date -Is)"
    echo "# hostname: $(hostname)"
    echo "#"
    for subdir in apt uv pip podman repos scripts files; do
        if [ -d "$CACHE_DIR/$subdir" ]; then
            echo "# ${subdir}: $(du -sh "$CACHE_DIR/$subdir" | cut -f1)"
        fi
    done
    echo "# total: $(du -sh "$CACHE_DIR" | cut -f1)"
} > "$CACHE_DIR/manifest.txt"

echo ""
log "Backup complete. Cache contents:"
du -sh "$CACHE_DIR"/*/ 2>/dev/null | sort -rh
echo ""
log "To transfer: rsync -a $CACHE_DIR/ <dest>/"
