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
AI_USERS=("lmstudio" "comfyui" "claw" "hosting" "defense")
SHARED_MODEL_DIR="/models"
LM_STUDIO_URL="https://releases.lmstudio.ai/linux/x86_64/latest/LM-Studio.AppImage"
ACE_STEP_MODEL_URL="https://huggingface.co/Linaqruf/ace-step-1.5-turbo-aio/resolve/main/ace_step_1.5_turbo_aio.safetensors"
HSA_OVERRIDE="11.5.1"

# --- Internal Registry ---
declare -A COMPONENT_FUNCS
declare -A COMPONENT_NAMES
COMPONENT_LIST=()
INSTALL_MODES=()

DRY_RUN=true
[[ "$*" == *"--force"* ]] && DRY_RUN=false

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

show_menu() {
    echo -e "${BLUE}=== Strix Halo Setup Menu ===${NC}"
    echo "0) Full Installation (All components)"
    
    local i=1
    for id in "${COMPONENT_LIST[@]}"; do
        echo "$i) ${COMPONENT_NAMES[$id]}"
        i=$((i+1))
    done
    
    echo "c) Custom selection"
    echo "q) Quit"
    read -p "Select an option: " choice

    case $choice in
        0) INSTALL_MODES=("${COMPONENT_LIST[@]}") ;;
        [1-9]) 
            local idx=$((choice-1))
            INSTALL_MODES=("${COMPONENT_LIST[$idx]}") 
            ;;
        c)
            for id in "${COMPONENT_LIST[@]}"; do
                read -p "Install ${COMPONENT_NAMES[$id]} (y/n)? " selection
                [[ "$selection" == "y" ]] && INSTALL_MODES+=("$id")
            done
            ;;
        q) exit 0 ;;
        *) error "Invalid option." ;;
    esac
}

main() {
    [[ $EUID -ne 0 ]] && error "Run as root."
    check_ssh_safety
    confirm_execution

    # Load components
    for component in "${INFRA_DIR}"/components/*.sh; do
        source "$component"
    done

    if [[ "$*" == *"--all"* ]]; then
        INSTALL_MODES=("${COMPONENT_LIST[@]}")
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
