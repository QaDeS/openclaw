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
LOCAL_LLM_URL="http://localhost:1234/v1"
ACE_STEP_MODEL_URL="https://huggingface.co/Linaqruf/ace-step-1.5-turbo-aio/resolve/main/ace_step_1.5_turbo_aio.safetensors"
HSA_OVERRIDE="11.5.1"
SSH_USERS="mk claw"     # Explicit SSH allowlist (space-separated)
SSH_UPNP_PORT=""         # External UPnP port for SSH; empty = skip UPnP
DDNS_FQDN=""             # Namecheap DDNS FQDN; empty = skip DDNS

# --- Internal Registry ---
declare -A COMPONENT_FUNCS
declare -A COMPONENT_NAMES
COMPONENT_LIST=()
INSTALL_MODES=()

DRY_RUN=true
REDOWNLOAD=false
[[ "$*" == *"--force"* ]] && DRY_RUN=false
[[ "$*" == *"--redownload"* ]] && REDOWNLOAD=true

# Parse --ssh-upnp-port=PORT and --ddns-fqdn=FQDN
for arg in "$@"; do
    case "$arg" in
        --ssh-upnp-port=*) SSH_UPNP_PORT="${arg#*=}" ;;
        --ddns-fqdn=*)     DDNS_FQDN="${arg#*=}" ;;
    esac
done

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
    local config="/etc/ssh/sshd_config"
    if grep -qE "^#?\s*${key}\b" "$config" 2>/dev/null; then
        run sed -i "s|^#\?\s*${key}\b.*|${key} ${value}|" "$config"
    else
        run tee -a "$config" <<< "${key} ${value}"
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
        LMSTUDIO)  [ -f /home/lmstudio/.lmstudio/bin/lms ] && systemctl is-enabled llmster >/dev/null 2>&1 ;;
        LLAMACPP)  [ -x /home/llamacpp/llama.cpp/build/bin/llama-server ] && systemctl is-enabled llamacpp >/dev/null 2>&1 ;;
        SYNC_LLAMA) [ -x /usr/local/bin/sync-llama-models.sh ] && systemctl is-enabled sync-llama-models >/dev/null 2>&1 ;;
        COMFYUI)   [ -d /home/comfyui/ComfyUI ] && systemctl is-enabled comfyui >/dev/null 2>&1 ;;
        ZIMAGE)    [ -d /home/comfyui/ComfyUI ] && /home/comfyui/.local/bin/uv --no-config pip show accelerate >/dev/null 2>&1 ;;
        ACE_STEP)  [ -d /home/comfyui/ACE-Step-1.5 ] && systemctl is-enabled ace-step >/dev/null 2>&1 ;;
        SSH_OUTSIDE_HOME) [ -d /etc/ssh/users ] && grep -q "/etc/ssh/users" /etc/ssh/sshd_config 2>/dev/null ;;
        SSH_HARDENING)    grep -q "PermitRootLogin prohibit-password" /etc/ssh/sshd_config 2>/dev/null && systemctl is-enabled fail2ban >/dev/null 2>&1 ;;
        SECURITY)  [ -f /home/defense/cisco-defense-daemon.py ] && systemctl is-enabled cisco-defense >/dev/null 2>&1 && systemctl is-enabled hosting >/dev/null 2>&1 ;;
        DDNS)      [ -n "$DDNS_FQDN" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "ddns-${DDNS_FQDN}" ;;
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
  --all                Skip menu and install all components
  --only ID,...        Install specific components (comma-separated IDs)
  --ssh-upnp-port=PORT External UPnP port for SSH (enables UPnP forwarding)
  --ddns-fqdn=FQDN    Namecheap DDNS FQDN (enables dynamic DNS)
  --help, -h           Show this help message

Component IDs:
HELPEOF
    for id in "${COMPONENT_LIST[@]}"; do
        printf "  %-12s %s\n" "$id" "${COMPONENT_NAMES[$id]}"
    done

    cat <<URLEOF

Access URLs (once provisioned, use ${host} from your laptop):
  RDP Desktop        ssh -L 3389:localhost:3389 ${host}  ->  rdp://localhost:3389
  LM Studio API      http://${host}:1234/v1
  llama.cpp API      http://${host}:11234/v1
  llama.cpp UI       http://${host}:11234
  ComfyUI            http://${host}:8188
  ACE Step (Music)   http://${host}:7860
  WordPress          http://${host}:8080

Upload models to ComfyUI:
  rsync -avP -e ssh --rsync-path="sudo -u comfyui rsync" <file> $(logname)@${host}:/home/comfyui/ComfyUI/models/<subdir>/
URLEOF
    exit 0
}

main() {
    [[ $EUID -ne 0 ]] && error "Run as root."
    check_ssh_safety
    confirm_execution

    # Load components
    for component in "${INFRA_DIR}"/components/*.sh; do
        source "$component"
    done

    [[ "$*" == *"--help"* || "$*" == *"-h"* ]] && show_help

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

    # Execute selected components
    for id in "${INSTALL_MODES[@]}"; do
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
                echo -e "  ${GREEN}LM Studio API${NC}      http://${host}:1234/v1"
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

main "$@"
