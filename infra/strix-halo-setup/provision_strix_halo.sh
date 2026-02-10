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

# --- Internal Registry ---
declare -A COMPONENT_FUNCS
declare -A COMPONENT_NAMES
COMPONENT_LIST=()
INSTALL_MODES=()

DRY_RUN=true
REDOWNLOAD=false
[[ "$*" == *"--force"* ]] && DRY_RUN=false
[[ "$*" == *"--redownload"* ]] && REDOWNLOAD=true

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
    local env_file="/home/claw/.openclaw/docker.env"
    if [ -f "$env_file" ]; then
        sed -i "s|^LOCAL_LLM_URL=.*|LOCAL_LLM_URL=${url}|" "$env_file"
        log "Updated LOCAL_LLM_URL → ${url}"
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
    local user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    local auth_keys="$user_home/.ssh/authorized_keys"
    if [[ ! -f "$auth_keys" ]] || [[ ! -s "$auth_keys" ]]; then
        error "Lockout Protection: No SSH keys found in $auth_keys. Setup aborted."
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
        OPENCLAW)  [ -f /home/claw/openclaw-compose.yml ] && systemctl is-enabled openclaw >/dev/null 2>&1 ;;
        LMSTUDIO)  [ -f /home/lmstudio/.lmstudio/bin/lms ] && systemctl is-enabled llmster >/dev/null 2>&1 ;;
        LLAMACPP)  [ -x /home/llamacpp/llama.cpp/build/bin/llama-server ] && systemctl is-enabled llamacpp >/dev/null 2>&1 ;;
        COMFYUI)   [ -d /home/comfyui/ComfyUI ] && systemctl is-enabled comfyui >/dev/null 2>&1 ;;
        ZIMAGE)    [ -d /home/comfyui/ComfyUI ] && /home/comfyui/.local/bin/uv --no-config pip show accelerate >/dev/null 2>&1 ;;
        ACE_STEP)  [ -d /home/comfyui/ACE-Step-1.5 ] && systemctl is-enabled ace-step >/dev/null 2>&1 ;;
        SECURITY)  [ -f /home/defense/cisco-defense-daemon.py ] && systemctl is-enabled cisco-defense >/dev/null 2>&1 && systemctl is-enabled hosting >/dev/null 2>&1 ;;
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
                    ${selected[$id]} && INSTALL_MODES+=("$id")
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
    cat <<HELPEOF
Usage: sudo ./provision_strix_halo.sh [OPTIONS]

Options:
  --force        Apply changes (default is dry-run)
  --redownload   Re-download assets even if they already exist
  --all          Skip menu and install all components
  --only ID,...  Install specific components (comma-separated IDs)
  --help, -h     Show this help message

Component IDs:
HELPEOF
    for id in "${COMPONENT_LIST[@]}"; do
        printf "  %-12s %s\n" "$id" "${COMPONENT_NAMES[$id]}"
    done
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
}

main "$@"
