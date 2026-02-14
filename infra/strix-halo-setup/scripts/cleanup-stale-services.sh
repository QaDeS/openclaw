#!/bin/bash
# cleanup-stale-services.sh — Remove stale systemd units from earlier installations.
#
# The provisioning script has evolved: openclaw/hosting/ddns moved from
# system-level Docker Compose units to rootless-podman quadlets under each
# user's ~/.config/containers/systemd/. This script stops and removes the
# old units so they don't conflict or cause confusing `systemctl` output.
#
# Safe to re-run — skips anything already absent.

set -euo pipefail

DRY_RUN=false
VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=true ;;
        -v|--verbose) VERBOSE=true ;;
        -h|--help)
            echo "Usage: cleanup-stale-services.sh [--dry-run] [--verbose]"
            echo "  -n, --dry-run   Show what would be removed without touching anything"
            echo "  -v, --verbose   Print every check, not just actions"
            exit 0
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

removed=0
skipped=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "  $*"; }
vlog() { $VERBOSE && echo "  $*" || true; }

# Stop, disable, and delete a system-level unit file.
remove_system_unit() {
    local unit_file="/etc/systemd/system/$1"
    if [ ! -f "$unit_file" ]; then
        vlog "[skip] $1 — not present"
        skipped=$((skipped + 1))
        return
    fi
    if $DRY_RUN; then
        log "[dry-run] would remove $unit_file"
        removed=$((removed + 1))
        return
    fi
    log "[remove] $unit_file"
    systemctl stop "$1" 2>/dev/null || true
    systemctl disable "$1" 2>/dev/null || true
    rm -f "$unit_file"
    removed=$((removed + 1))
}

# Stop and remove a user-level unit/quadlet for a given user.
remove_user_unit() {
    local user=$1 file=$2
    local uid
    uid=$(id -u "$user" 2>/dev/null) || {
        vlog "[skip] user $user does not exist"
        skipped=$((skipped + 1))
        return
    }
    local unit_dir="/home/${user}/.config/containers/systemd"
    local unit_file="${unit_dir}/${file}"
    if [ ! -f "$unit_file" ]; then
        vlog "[skip] ${user}: $file — not present"
        skipped=$((skipped + 1))
        return
    fi
    local service_name="${file%.*}.service"
    if $DRY_RUN; then
        log "[dry-run] would remove ${unit_file} (user=$user)"
        removed=$((removed + 1))
        return
    fi
    log "[remove] ${unit_file} (user=$user)"
    sudo -u "$user" XDG_RUNTIME_DIR="/run/user/${uid}" \
        systemctl --user stop "$service_name" 2>/dev/null || true
    rm -f "$unit_file"
    sudo -u "$user" XDG_RUNTIME_DIR="/run/user/${uid}" \
        systemctl --user daemon-reload 2>/dev/null || true
    removed=$((removed + 1))
}

# ---------------------------------------------------------------------------
# System-level units (old Docker-era or renamed services)
# ---------------------------------------------------------------------------

echo "=== System-level units ==="

# Old Docker Compose-based units, replaced by rootless podman quadlets
remove_system_unit "openclaw.service"
remove_system_unit "hosting.service"

# Renamed / superseded services (add future renames here)
# remove_system_unit "old-name.service"

# Current system units are left alone:
#   llamacpp, comfyui, ace-step, cisco-defense,
#   sync-llama-models, upnp-ssh.{service,timer}

# ---------------------------------------------------------------------------
# User-level units (old quadlets / manually-created units)
# ---------------------------------------------------------------------------

echo "=== User-level units ==="

# claw: old manual service files that predate the quadlet
for f in openclaw.service; do
    local_path="/home/claw/.config/systemd/user/${f}"
    if [ -f "$local_path" ]; then
        if $DRY_RUN; then
            log "[dry-run] would remove $local_path"
        else
            log "[remove] $local_path (manual user unit)"
            uid=$(id -u claw 2>/dev/null) || true
            [ -n "$uid" ] && sudo -u claw XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user stop "$f" 2>/dev/null || true
            rm -f "$local_path"
            [ -n "$uid" ] && sudo -u claw XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user daemon-reload 2>/dev/null || true
        fi
        removed=$((removed + 1))
    else
        vlog "[skip] claw: $local_path — not present"
    fi
done

# hosting: old manual unit
for f in hosting.service hosting-stack.service; do
    local_path="/home/hosting/.config/systemd/user/${f}"
    if [ -f "$local_path" ]; then
        if $DRY_RUN; then
            log "[dry-run] would remove $local_path"
        else
            log "[remove] $local_path (manual user unit)"
            uid=$(id -u hosting 2>/dev/null) || true
            [ -n "$uid" ] && sudo -u hosting XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user stop "$f" 2>/dev/null || true
            rm -f "$local_path"
            [ -n "$uid" ] && sudo -u hosting XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user daemon-reload 2>/dev/null || true
        fi
        removed=$((removed + 1))
    else
        vlog "[skip] hosting: $local_path — not present"
    fi
done

# ---------------------------------------------------------------------------
# Final daemon-reload so systemd forgets the deleted units
# ---------------------------------------------------------------------------

if [ "$removed" -gt 0 ] && ! $DRY_RUN; then
    systemctl daemon-reload
fi

echo ""
echo "Done. Removed: $removed, Skipped (already clean): $skipped"
