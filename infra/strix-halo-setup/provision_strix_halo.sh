#!/bin/bash

# provision_strix_halo.sh
# Modularized Hardware Provisioning for Strix Halo (GFX1151)
# Simply add a script to components/ to extend functionality.

set -eo pipefail

# --- Global Configuration ---
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$INFRA_DIR/../.." && pwd)"
KERNEL_VERSION="6.18.7"
ROCM_VERSION="7.2"
SHARED_MODEL_DIR="/models"
LOCAL_LLM_URL="http://localhost:11234/v1"
ACE_STEP_MODEL_URL="https://huggingface.co/Linaqruf/ace-step-1.5-turbo-aio/resolve/main/ace_step_1.5_turbo_aio.safetensors"
HSA_OVERRIDE="11.5.1"
CACHE_DIR="${INFRA_DIR}/.cache"  # Download cache dir; default alongside provision script
NO_CACHE=false           # Set to true to disable caching entirely
SSH_USERS="mk claw"     # Explicit SSH allowlist (space-separated)
SSH_UPNP_PORT=""         # External UPnP port for SSH; empty = skip UPnP
DDNS_FQDN=""             # Namecheap DDNS FQDN; empty = skip DDNS

# --- Internal Registry ---
declare -A COMPONENT_FUNCS
declare -A COMPONENT_NAMES
COMPONENT_LIST=()
INSTALL_MODES=()

# --- Backup / Undo State ---
STATE_DIR="/var/lib/strix-provision"
RUN_TS=""
BACKUP_DIR=""
MANIFEST_FILE=""
CURRENT_COMPONENT=""
DO_UNDO=false
UNDO_TARGET=""
DO_HISTORY=false

DRY_RUN=true
REDOWNLOAD=false

# Parse all CLI flags
for arg in "$@"; do
    case "$arg" in
        --force)             DRY_RUN=false ;;
        --redownload)        REDOWNLOAD=true ;;
        --cache-dir=*)       CACHE_DIR="${arg#*=}" ;;
        --no-cache)          NO_CACHE=true ;;
        --ssh-upnp-port=*)   SSH_UPNP_PORT="${arg#*=}" ;;
        --ddns-fqdn=*)       DDNS_FQDN="${arg#*=}" ;;
        --history)           DO_HISTORY=true ;;
        --undo)              DO_UNDO=true ;;
        --undo=*)            DO_UNDO=true; UNDO_TARGET="${arg#*=}" ;;
    esac
done

# Disable cache if --no-cache was passed
if [ "$NO_CACHE" = true ]; then
    CACHE_DIR=""
fi

export CACHE_DIR

# Source cache-aware download helpers.
# Also publish a world-readable copy so that sudo -u <svc-user> subshells can
# source it (the operator's home dir may not be traversable by service users).
CACHE_HELPERS_SRC="${INFRA_DIR}/lib/cache-helpers.sh"
CACHE_HELPERS="/tmp/strix-cache-helpers.sh"
if [ -f "$CACHE_HELPERS_SRC" ]; then
    source "$CACHE_HELPERS_SRC"
    cp "$CACHE_HELPERS_SRC" "$CACHE_HELPERS"
    chmod 644 "$CACHE_HELPERS"
fi
export CACHE_HELPERS

# --- Colors & Logging ---
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

run() {
    if [ "$DRY_RUN" = true ]; then
        log "${YELLOW}[DRY-RUN] Will execute:${NC} $*"
    else
        "$@"
    fi
}

# --- Backup / Undo Helpers ---

# Initialise state dirs and manifest for this run.
init_run_state() {
    RUN_TS=$(date +%Y%m%d-%H%M%S)
    BACKUP_DIR="${STATE_DIR}/backups/${RUN_TS}"
    MANIFEST_FILE="${STATE_DIR}/manifests/${RUN_TS}.manifest"

    if [ "$DRY_RUN" = true ]; then
        log "Run state: ts=${RUN_TS} (dry-run, no state files created)"
        return
    fi

    mkdir -p "${BACKUP_DIR}" "${STATE_DIR}/manifests"
    {
        echo "# STRIX_RUN_MANIFEST v1"
        echo "# timestamp: ${RUN_TS}"
        echo "# user: ${SUDO_USER:-root}"
        # components line filled in later by main()
    } > "$MANIFEST_FILE"
    log "Run state: ts=${RUN_TS}  manifest=${MANIFEST_FILE}"
}

# Append a tab-separated record to the manifest.
manifest_record() {
    [ "$DRY_RUN" = true ] && return
    local IFS=$'\t'
    echo "$*" >> "$MANIFEST_FILE"
}

# Back up a file into the run's backup dir. Idempotent within a run.
backup_file() {
    local src="$1"
    [ -f "$src" ] || return 0
    local flat
    flat=$(echo "$src" | sed 's|^/||; s|/|-|g')
    local dest="${BACKUP_DIR}/${flat}"
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would back up ${src} → ${dest}"
        return
    fi
    # Idempotent: skip if already backed up this run
    [ -f "$dest" ] && return 0
    cp -a "$src" "$dest"
    manifest_record "backup_file" "${CURRENT_COMPONENT}" "$src" "$dest"
    log "Backed up ${src}"
}

# Record that a file was created by this run.
track_file_create() {
    local path="$1"
    log "Tracking file create: ${path}"
    manifest_record "create_file" "${CURRENT_COMPONENT}" "$path"
}

# Back up then record modification of an existing file.
track_file_modify() {
    local path="$1"
    backup_file "$path"
    manifest_record "modify_file" "${CURRENT_COMPONENT}" "$path"
}

# Record a systemd service enablement.
track_service() {
    local unit="$1"
    manifest_record "enable_service" "${CURRENT_COMPONENT}" "$unit"
}

# Record a symlink creation.
track_symlink() {
    local link="$1" target="$2"
    manifest_record "create_symlink" "${CURRENT_COMPONENT}" "$link" "$target"
}

# Record a UFW rule.
track_ufw_rule() {
    local spec="$*"
    manifest_record "add_ufw_rule" "${CURRENT_COMPONENT}" "$spec"
}

# Record a Docker container.
track_docker() {
    local container="$1" image="$2"
    manifest_record "docker_container" "${CURRENT_COMPONENT}" "$container" "$image"
}

# Back up a file and record a marker-guarded append.
track_append() {
    local file="$1" marker="$2"
    backup_file "$file"
    manifest_record "append_block" "${CURRENT_COMPONENT}" "$file" "$marker"
}

# Record a non-reversible action (emits warning on undo).
undo_note() {
    local msg="$*"
    manifest_record "undo_note" "${CURRENT_COMPONENT}" "$msg"
}

# --- History & Undo ---

# List all past runs with their status and components.
show_history() {
    local manifest_dir="${STATE_DIR}/manifests"
    if [ ! -d "$manifest_dir" ] || [ -z "$(ls -A "$manifest_dir" 2>/dev/null)" ]; then
        log "No provisioning runs recorded yet."
        return 0
    fi

    echo ""
    echo -e "${BLUE}=== Provisioning History ===${NC}"
    printf "  %-20s %-10s %-10s %s\n" "TIMESTAMP" "STATUS" "USER" "COMPONENTS"
    printf "  %-20s %-10s %-10s %s\n" "---------" "------" "----" "----------"

    for mf in "$manifest_dir"/*.manifest; do
        [ -f "$mf" ] || continue
        local ts
        ts=$(basename "$mf" .manifest)
        local status="applied"
        [ -f "${mf}.undone" ] && status="undone"
        local user=""
        user=$(grep "^# user:" "$mf" | head -1 | cut -d: -f2- | xargs)
        local components=""
        components=$(grep "^# components:" "$mf" | head -1 | cut -d: -f2- | xargs)
        printf "  %-20s %-10s %-10s %s\n" "$ts" "$status" "$user" "$components"
    done
    echo ""
}

# Find the most recent manifest that hasn't been undone.
find_latest_manifest() {
    local manifest_dir="${STATE_DIR}/manifests"
    local latest=""
    for mf in "$manifest_dir"/*.manifest; do
        [ -f "$mf" ] || continue
        [ -f "${mf}.undone" ] && continue
        latest="$mf"
    done
    echo "$latest"
}

# Resolve a manifest by timestamp or "latest".
resolve_manifest() {
    local target="$1"
    if [ -z "$target" ] || [ "$target" = "latest" ]; then
        find_latest_manifest
    else
        local mf="${STATE_DIR}/manifests/${target}.manifest"
        [ -f "$mf" ] && echo "$mf"
    fi
}

# Undo a provisioning run by reading its manifest in reverse.
do_undo() {
    local mf
    mf=$(resolve_manifest "$UNDO_TARGET")
    if [ -z "$mf" ] || [ ! -f "$mf" ]; then
        error "No manifest found for '${UNDO_TARGET:-latest}'. Run --history to see available runs."
    fi
    if [ -f "${mf}.undone" ]; then
        error "Run $(basename "$mf" .manifest) has already been undone."
    fi

    local ts
    ts=$(basename "$mf" .manifest)
    log "Undoing run ${ts} ..."

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would undo the following actions:"
    fi

    # Read manifest lines (skip comments), reverse order
    local lines=()
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done < "$mf"

    # Process in reverse
    local i
    for (( i=${#lines[@]}-1; i>=0; i-- )); do
        local line="${lines[$i]}"
        local action component arg1 arg2
        IFS=$'\t' read -r action component arg1 arg2 <<< "$line"

        case "$action" in
            backup_file)
                # arg1=original path, arg2=backup path — restore
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Restore ${arg2} → ${arg1}"
                else
                    if [ -f "$arg2" ]; then
                        cp -a "$arg2" "$arg1"
                        log "Restored ${arg1} from backup"
                    else
                        warn "Backup missing: ${arg2} — cannot restore ${arg1}"
                    fi
                fi
                ;;
            create_file)
                # arg1=path — remove if it exists
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Remove created file ${arg1}"
                else
                    if [ -f "$arg1" ]; then
                        rm -f "$arg1"
                        log "Removed ${arg1}"
                    fi
                fi
                ;;
            create_symlink)
                # arg1=link path — remove symlink
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Remove symlink ${arg1}"
                else
                    if [ -L "$arg1" ]; then
                        rm -f "$arg1"
                        log "Removed symlink ${arg1}"
                    fi
                fi
                ;;
            enable_service)
                # arg1=unit — disable and stop
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Disable and stop service ${arg1}"
                else
                    systemctl disable "$arg1" 2>/dev/null || true
                    systemctl stop "$arg1" 2>/dev/null || true
                    log "Disabled service ${arg1}"
                fi
                ;;
            add_ufw_rule)
                # arg1=rule spec — delete the rule
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Delete UFW rule: ${arg1}"
                else
                    ufw delete "$arg1" 2>/dev/null || warn "Could not delete UFW rule: ${arg1}"
                    log "Deleted UFW rule: ${arg1}"
                fi
                ;;
            docker_container|podman_container)
                # arg1=container name — stop and remove
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Stop and remove container ${arg1}"
                else
                    # Try podman first, fall back to docker
                    if command -v podman &>/dev/null; then
                        podman stop "$arg1" 2>/dev/null || true
                        podman rm "$arg1" 2>/dev/null || true
                    elif command -v docker &>/dev/null; then
                        docker stop "$arg1" 2>/dev/null || true
                        docker rm "$arg1" 2>/dev/null || true
                    fi
                    log "Removed container ${arg1}"
                fi
                ;;
            append_block)
                # arg1=file, arg2=marker — backup was already taken, remove marker block
                # Restoring from backup_file entry handles this
                ;;
            modify_file)
                # Restoring handled by backup_file entry
                ;;
            undo_note)
                warn "Non-reversible: ${arg1}"
                ;;
        esac
    done

    # Validate SSH config after undo (if any SSH-related backups were restored)
    if grep -q "sshd_config" "$mf" 2>/dev/null; then
        if [ "$DRY_RUN" = false ]; then
            if sshd -t 2>/dev/null; then
                log "SSH config validated OK after undo"
                systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
            else
                warn "sshd -t failed after undo — SSH config may need manual repair"
            fi
        fi
    fi

    # Write .undone sidecar
    if [ "$DRY_RUN" = false ]; then
        echo "Undone at $(date -Is) by ${SUDO_USER:-root}" > "${mf}.undone"
        success "Run ${ts} has been undone."
    else
        log "[DRY-RUN] Would mark run ${ts} as undone"
    fi
}

# --- Helpers ---
ensure_user() {
    local user=$1
    if ! id "$user" &>/dev/null; then
        run useradd -m -s /bin/bash -G ai-users,render,video "$user"
    fi
}

set_local_llm_url() {
    local url=$1
    LOCAL_LLM_URL="$url"
    local env_file="/home/claw/.openclaw/env"
    if [ -f "$env_file" ]; then
        sed -i "s|^LOCAL_LLM_URL=.*|LOCAL_LLM_URL=${url}|" "$env_file"
        log "Updated LOCAL_LLM_URL → ${url}"
    fi
}

# Idempotently set an sshd_config directive — replace if exists (commented or not), append if absent.
set_sshd_directive() {
    local key=$1 value=$2
    # Use a drop-in config in sshd_config.d/ to ensure our setting wins.
    # Ubuntu 24.04's sshd_config has "Include /etc/ssh/sshd_config.d/*.conf"
    # at the top — first match wins, so a high-priority filename ensures
    # our directive takes effect before any distro defaults.
    local drop_in="/etc/ssh/sshd_config.d/00-strix.conf"
    if [ "$DRY_RUN" = false ]; then
        mkdir -p /etc/ssh/sshd_config.d
        # Update or append the directive in our drop-in file
        if [ -f "$drop_in" ] && grep -q "^${key} " "$drop_in" 2>/dev/null; then
            sed -i "s|^${key} .*|${key} ${value}|" "$drop_in"
        else
            echo "${key} ${value}" >> "$drop_in"
        fi
        track_file_create "$drop_in"
    else
        log "${YELLOW}[DRY-RUN] Will set ${key} in ${drop_in}${NC}"
    fi
}

# Returns 0 if user is in $SSH_USERS (plus $SUDO_USER always implicitly included).
user_has_ssh() {
    local user=$1
    [[ " ${SSH_USERS} ${SUDO_USER:-} " == *" ${user} "* ]]
}

# Enable SSH for a user by setting up /etc/ssh/users/<user>/.ssh/
enable_ssh_for_user() {
    local user=$1
    user_has_ssh "$user" || return 0

    local ssh_dir="/etc/ssh/users/${user}/.ssh"
    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)

    run mkdir -p "$ssh_dir"
    run chown "${user}:${user}" "/etc/ssh/users/${user}" "$ssh_dir"
    run chmod 700 "/etc/ssh/users/${user}" "$ssh_dir"

    # Migrate existing authorized_keys (merge via sort -u, no data loss)
    local target="${ssh_dir}/authorized_keys"
    if [ "$DRY_RUN" = false ]; then
        if [ -f "${user_home}/.ssh/authorized_keys" ] && [ ! -L "${user_home}/.ssh" ]; then
            if [ -f "$target" ]; then
                # Merge existing keys
                sort -u "${user_home}/.ssh/authorized_keys" "$target" > "${target}.tmp"
                mv "${target}.tmp" "$target"
            else
                cp -n "${user_home}/.ssh/authorized_keys" "$target"
            fi
        fi
        chown "${user}:${user}" "$target" 2>/dev/null || true
        chmod 600 "$target" 2>/dev/null || true
    else
        log "${YELLOW}[DRY-RUN] Will migrate authorized_keys for ${user}${NC}"
    fi

    # Symlink ~/.ssh → /etc/ssh/users/<user>/.ssh
    if [ "$DRY_RUN" = false ]; then
        if [ -L "${user_home}/.ssh" ]; then
            log "Symlink already exists: ${user_home}/.ssh"
        elif [ -d "${user_home}/.ssh" ]; then
            mv "${user_home}/.ssh" "${user_home}/.ssh.bak.$(date +%s)"
            ln -sf "$ssh_dir" "${user_home}/.ssh"
        else
            ln -sf "$ssh_dir" "${user_home}/.ssh"
        fi
    else
        log "${YELLOW}[DRY-RUN] Will symlink ${user_home}/.ssh → ${ssh_dir}${NC}"
    fi
}

# --- Podman / Quadlet Helpers ---

# Enable linger for a user so rootless podman services survive logout.
ensure_linger() {
    local user=$1
    local uid
    uid=$(id -u "$user")

    if ! loginctl show-user "$user" -p Linger 2>/dev/null | grep -q "yes"; then
        run loginctl enable-linger "$user"
    fi

    # For freshly-created users, linger alone isn't enough — the user
    # manager (user@<uid>.service) may not be running yet. Start it
    # explicitly so that quadlet generation and systemctl --user work.
    if ! systemctl is-active --quiet "user@${uid}.service"; then
        systemctl start "user@${uid}.service"
    fi

    # Wait for the D-Bus session socket — the user manager startup is
    # async and the bus may not exist yet when we return.
    local rtdir="/run/user/${uid}"
    local tries=0
    while [ ! -S "${rtdir}/bus" ] && [ "$tries" -lt 30 ]; do
        sleep 0.2
        tries=$((tries + 1))
    done
    if [ ! -S "${rtdir}/bus" ]; then
        warn "D-Bus session socket not found after 6s for ${user} (uid ${uid})"
    fi
}

# Run systemctl --user as another user with the correct XDG_RUNTIME_DIR.
# Without this, "sudo -u <user> systemctl --user" fails with
# "Failed to connect to bus: No medium found / No such file or directory"
# because the D-Bus session socket path is unknown or the runtime dir
# hasn't been created yet for freshly-created service users.
user_systemctl() {
    local user=$1; shift
    local uid
    uid=$(id -u "$user")
    local rtdir="/run/user/${uid}"

    # Ensure the runtime dir exists (systemd-logind creates it on login,
    # but lingering users that never logged in may not have it yet).
    if [ ! -d "$rtdir" ]; then
        mkdir -p "$rtdir"
        chown "${user}:${user}" "$rtdir"
        chmod 700 "$rtdir"
    fi

    sudo -u "$user" \
        XDG_RUNTIME_DIR="$rtdir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${rtdir}/bus" \
        systemctl --user "$@"
}

# Deploy a quadlet file to a user's systemd directory and reload.
deploy_quadlet() {
    local user=$1 src=$2
    local dest="/home/${user}/.config/containers/systemd/$(basename "$src")"
    run mkdir -p "$(dirname "$dest")"
    run cp "$src" "$dest"
    run chown "${user}:${user}" "$(dirname "$(dirname "$(dirname "$dest")")")" -R
    track_file_create "$dest"
}

# Record a podman container for undo tracking (replaces track_docker).
track_podman() {
    local container="$1" image="$2"
    manifest_record "podman_container" "${CURRENT_COMPONENT}" "$container" "$image"
}

# --- Plugin Framework ---
register_component() {
    local id=$1
    shift
    local name=$(grep -m 1 "component_name:" "${BASH_SOURCE[1]}" | cut -d: -f2- | xargs)
    local desc=$(grep -m 1 "component_description:" "${BASH_SOURCE[1]}" | cut -d: -f2- | xargs)
    
    COMPONENT_LIST+=("$id")
    COMPONENT_NAMES["$id"]="$name"
    COMPONENT_FUNCS["$id"]="$*"
}

check_ssh_safety() {
    log "Verifying SSH persistence..."
    local user_home
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)

    # Check both the outside-home location and the traditional path (follow symlinks)
    local outside_keys="/etc/ssh/users/${SUDO_USER}/.ssh/authorized_keys"
    local home_keys="${user_home}/.ssh/authorized_keys"

    local found=false
    for auth_keys in "$outside_keys" "$home_keys"; do
        if [[ -f "$auth_keys" ]] && [[ -s "$auth_keys" ]]; then
            found=true
            # Warn on DSA keys (weak) but don't block
            if grep -q "ssh-dss" "$auth_keys" 2>/dev/null; then
                warn "DSA key found in $auth_keys — consider upgrading to ed25519"
            fi
            break
        fi
    done

    if ! $found; then
        error "Lockout Protection: No SSH keys found for ${SUDO_USER}. Setup aborted."
    fi
}

confirm_execution() {
    if [ "$DRY_RUN" = true ]; then
        warn "Running in DRY-RUN mode. No changes will be applied."
        warn "To apply changes, run with: sudo ./provision_strix_halo.sh --force"
    else
        warn "CRITICAL: Modifying system files, kernel, and disabling SSH passwords."
        # read -p "Type 'I UNDERSTAND THE RISKS' to proceed: " confirm
        # [[ "$confirm" != "I UNDERSTAND THE RISKS" ]] && error "Confirmation failed."
    fi
}

# --- System State Detection ---
# Returns 0 (true) if a component appears to be already installed.
# For components with systemd services, also verifies the service is enabled.
is_installed() {
    local id=$1
    case "$id" in
        BASE)      ls -d /opt/rocm-${ROCM_VERSION}* >/dev/null 2>&1 ;;
        OPENCLAW)  [ -d /home/claw/openclaw/.git ] && systemctl is-enabled openclaw >/dev/null 2>&1 ;;
        LMSTUDIO)  local _lms_home; _lms_home=$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6); [ -f "${_lms_home}/.lmstudio/bin/lms" ] ;;
        LLAMACPP)  [ -x /home/llamacpp/llama.cpp/build/bin/llama-server ] && systemctl is-enabled llamacpp >/dev/null 2>&1 ;;
        SYNC_LLAMA) [ -x /usr/local/bin/sync-llama-models.sh ] && systemctl is-enabled sync-llama-models >/dev/null 2>&1 ;;
        COMFYUI)   [ -d /home/comfyui/ComfyUI ] && systemctl is-enabled comfyui >/dev/null 2>&1 ;;
        ZIMAGE)    [ -d /home/comfyui/ComfyUI ] && /home/comfyui/.local/bin/uv --no-config pip show accelerate >/dev/null 2>&1 ;;
        ACE_STEP)  [ -d /home/comfyui/ACE-Step-1.5 ] && systemctl is-enabled ace-step >/dev/null 2>&1 ;;
        SSH_OUTSIDE_HOME) [ -d /etc/ssh/users ] && grep -rq "/etc/ssh/users" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null ;;
        SSH_HARDENING)    grep -q "PermitRootLogin prohibit-password" /etc/ssh/sshd_config 2>/dev/null && systemctl is-enabled fail2ban >/dev/null 2>&1 ;;
        SECURITY)  [ -f /home/defense/cisco-defense-daemon.py ] && systemctl is-enabled cisco-defense >/dev/null 2>&1 && systemctl is-enabled hosting >/dev/null 2>&1 ;;
        PODMAN)    command -v podman &>/dev/null ;;
        DDNS)      [ -n "$DDNS_FQDN" ] && podman ps --format '{{.Names}}' 2>/dev/null | grep -q "ddns-${DDNS_FQDN}" ;;
        *)         return 1 ;;
    esac
}

show_menu() {
    # Build selection array: default to selecting components that are NOT installed
    local total=${#COMPONENT_LIST[@]}
    declare -A selected
    for id in "${COMPONENT_LIST[@]}"; do
        if is_installed "$id"; then
            selected["$id"]=false
        else
            selected["$id"]=true
        fi
    done

    while true; do
        echo ""
        echo -e "${BLUE}=== Strix Halo Setup ===${NC}"
        echo ""

        local i=1
        for id in "${COMPONENT_LIST[@]}"; do
            local marker=" "
            ${selected[$id]} && marker="*"
            local status=""
            if is_installed "$id"; then
                status="${GREEN}(installed)${NC}"
            fi
            printf "  %s${BLUE}%d${NC}) %-30s %b\n" "[$marker] " "$i" "${COMPONENT_NAMES[$id]}" "$status"
            i=$((i+1))
        done

        echo ""
        echo -e "  ${YELLOW}Toggle${NC}: enter numbers (e.g. ${BLUE}1 3 5${NC} or ${BLUE}1,3,5${NC})"
        echo -e "  ${YELLOW}a${NC} = select all   ${YELLOW}n${NC} = select none   ${YELLOW}Enter${NC} = confirm   ${YELLOW}q${NC} = quit"
        echo ""
        read -p "  > " input

        # Trim whitespace
        input=$(echo "$input" | xargs)

        case "$input" in
            "")
                # Confirm current selection
                for id in "${COMPONENT_LIST[@]}"; do
                    if ${selected[$id]}; then
                        INSTALL_MODES+=("$id")
                    fi
                done
                return
                ;;
            q|Q)
                exit 0
                ;;
            a|A)
                for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=true; done
                ;;
            n|N)
                for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=false; done
                ;;
            *)
                # Parse comma or space separated numbers and toggle them
                local nums
                nums=$(echo "$input" | tr ',' ' ')
                for num in $nums; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
                        local idx=$((num-1))
                        local id="${COMPONENT_LIST[$idx]}"
                        if ${selected[$id]}; then
                            selected["$id"]=false
                        else
                            selected["$id"]=true
                        fi
                    else
                        warn "Invalid number: $num (valid: 1-$total)"
                    fi
                done
                ;;
        esac
    done
}

show_help() {
    local host
    host=$(hostname 2>/dev/null || echo "<hostname>")

    cat <<HELPEOF
Usage: sudo ./provision_strix_halo.sh [OPTIONS]

Options:
  --force              Apply changes (default is dry-run)
  --redownload         Re-download assets even if they already exist
  --cache-dir=PATH     Override download cache directory (default: .cache/)
  --no-cache           Disable download cache entirely
  --all                Skip menu and install all components
  --only ID,...        Install specific components (comma-separated IDs)
  --ssh-upnp-port=PORT External UPnP port for SSH (enables UPnP forwarding)
  --ddns-fqdn=FQDN    Namecheap DDNS FQDN (enables dynamic DNS)
  --history            Show provisioning run history
  --undo[=TIMESTAMP]   Undo a provisioning run (default: latest)
  --help, -h           Show this help message

Component IDs:
HELPEOF
    for id in "${COMPONENT_LIST[@]}"; do
        printf "  %-12s %s\n" "$id" "${COMPONENT_NAMES[$id]}"
    done

    cat <<URLEOF

Access URLs (once provisioned, use ${host} from your laptop):
  RDP Desktop        ssh -L 3389:localhost:3389 ${host}  ->  rdp://localhost:3389
  LM Studio          ssh -X ${SUDO_USER}@${host} lmstudio  (or use RDP)
  llama.cpp API      http://${host}:11234/v1
  llama.cpp UI       http://${host}:11234
  ComfyUI            http://${host}:8188
  ACE Step (Music)   http://${host}:7860
  WordPress          http://${host}:8080

Upload models to ComfyUI:
  rsync -avP -e ssh --rsync-path="sudo -u comfyui rsync" <file> $(logname)@${host}:/home/comfyui/ComfyUI/models/<subdir>/

Service management:
  System services (llamacpp, comfyui, ace-step, cisco-defense, sync-llama-models):
    sudo systemctl stop|start|restart|status <service>
    sudo journalctl -u <service> -f           # follow logs

  User services — Hosting stack (rootless podman quadlets, user=hosting):
    sudo -u hosting XDG_RUNTIME_DIR=/run/user/\$(id -u hosting) systemctl --user stop|start|restart hosting.target
    sudo -u hosting XDG_RUNTIME_DIR=/run/user/\$(id -u hosting) systemctl --user status supabase wordpress

  User services — OpenClaw (rootless podman quadlet, user=claw):
    sudo -u claw XDG_RUNTIME_DIR=/run/user/\$(id -u claw) systemctl --user stop|start|restart openclaw.service
    sudo -u claw XDG_RUNTIME_DIR=/run/user/\$(id -u claw) systemctl --user status openclaw
URLEOF
    exit 0
}

main() {
    [[ $EUID -ne 0 ]] && error "Run as root."

    # Reset CWD to a universally accessible directory. sudo -u <user> inherits
    # the caller's CWD; if that's an operator-only path (e.g. /home/mk/…), any
    # process that tries to chdir into it (podman, cmake, git, systemctl --user)
    # will fail with "Permission denied". INFRA_DIR is already absolute.
    cd /tmp

    # Load components (needed for --help, --history, and normal runs)
    for component in "${INFRA_DIR}"/components/*.sh; do
        source "$component"
    done

    [[ "$*" == *"--help"* || "$*" == *"-h"* ]] && show_help

    # --- History mode ---
    if [ "$DO_HISTORY" = true ]; then
        show_history
        return 0
    fi

    # --- Undo mode ---
    if [ "$DO_UNDO" = true ]; then
        do_undo
        return 0
    fi

    # --- Normal provisioning ---
    check_ssh_safety
    confirm_execution

    if [[ "$*" == *"--all"* ]]; then
        INSTALL_MODES=("${COMPONENT_LIST[@]}")
    elif [[ "$*" == *"--only"* ]]; then
        # Extract the value after --only
        local only_val
        only_val=$(echo "$*" | grep -oP '(?<=--only\s)\S+')
        IFS=',' read -ra only_ids <<< "$only_val"
        for id in "${only_ids[@]}"; do
            id=$(echo "$id" | tr '[:lower:]' '[:upper:]')
            if [[ -n "${COMPONENT_NAMES[$id]+x}" ]]; then
                INSTALL_MODES+=("$id")
            else
                warn "Unknown component: $id (skipping)"
            fi
        done
    else
        show_menu
    fi

    if [ ${#INSTALL_MODES[@]} -eq 0 ]; then
        error "No components selected."
    fi

    # Initialise run state (backups + manifest)
    init_run_state

    # Write components list to manifest header
    if [ "$DRY_RUN" = false ] && [ -n "$MANIFEST_FILE" ]; then
        local comp_list
        comp_list=$(IFS=,; echo "${INSTALL_MODES[*]}")
        sed -i "2a # components: ${comp_list}" "$MANIFEST_FILE"
    fi

    # Execute selected components
    for id in "${INSTALL_MODES[@]}"; do
        CURRENT_COMPONENT="$id"
        log "${BLUE}>>> Executing: ${COMPONENT_NAMES[$id]}${NC}"
        for func in ${COMPONENT_FUNCS[$id]}; do
            $func
        done
    done

    success "Provisioning complete for selected components! REBOOT is required."

    # Print accessible URLs for installed components
    print_urls
}

print_urls() {
    local host
    host=$(hostname)

    echo ""
    echo -e "${BLUE}=== Access URLs (use ${GREEN}${host}${BLUE} from your laptop) ===${NC}"
    echo ""

    # Show URLs for ALL installed components (pre-existing + just provisioned)
    local any=false
    for id in "${COMPONENT_LIST[@]}"; do
        # Show if just installed OR was already installed
        local dominated=false
        for m in "${INSTALL_MODES[@]}"; do [[ "$m" == "$id" ]] && dominated=true; done
        if ! $dominated && ! is_installed "$id"; then
            continue
        fi

        case "$id" in
            BASE)
                echo -e "  ${GREEN}RDP Desktop${NC}        ssh -L 3389:localhost:3389 ${host}  →  rdp://localhost:3389"
                any=true
                ;;
            SSH_HARDENING)
                if [ -n "$SSH_UPNP_PORT" ]; then
                    echo -e "  ${GREEN}SSH (UPnP)${NC}         ssh -p ${SSH_UPNP_PORT} <external-ip>"
                fi
                ;;
            LMSTUDIO)
                echo -e "  ${GREEN}LM Studio${NC}          ssh -X user@${host} lmstudio  (or use RDP desktop)"
                any=true
                ;;
            LLAMACPP)
                echo -e "  ${GREEN}llama.cpp API${NC}      http://${host}:11234/v1"
                echo -e "  ${GREEN}llama.cpp UI${NC}       http://${host}:11234"
                any=true
                ;;
            COMFYUI)
                echo -e "  ${GREEN}ComfyUI${NC}            http://${host}:8188"
                echo -e "  ${GREEN}Upload models${NC}      rsync -avP -e ssh --rsync-path=\"sudo -u comfyui rsync\" <file> ${host}:/home/comfyui/ComfyUI/models/<subdir>/"
                any=true
                ;;
            ACE_STEP)
                echo -e "  ${GREEN}ACE Step (Music)${NC}   http://${host}:7860"
                any=true
                ;;
            SECURITY)
                echo -e "  ${GREEN}WordPress${NC}          http://${host}:8080"
                any=true
                ;;
            DDNS)
                if [ -n "$DDNS_FQDN" ]; then
                    echo -e "  ${GREEN}DDNS${NC}               ${DDNS_FQDN}"
                    any=true
                fi
                ;;
        esac
    done

    if [ "$any" = false ]; then
        echo -e "  ${YELLOW}(no web-accessible components installed)${NC}"
    fi
    echo ""
}

# Only run main when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
