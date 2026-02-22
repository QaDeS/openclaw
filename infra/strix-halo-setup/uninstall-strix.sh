#!/usr/bin/env bash
# ── uninstall-strix.sh ────────────────────────────────────────────────
# Complete uninstall for Strix Halo provisioning.
# Removes all service users, system services, and configuration changes
# while preserving caches and model data.
#
# Usage:
#   sudo ./uninstall-strix.sh        # Dry-run (shows what would be done)
#   sudo ./uninstall-strix.sh --force # Actually execute
#   sudo ./uninstall-strix.sh --force --skip-users  # Keep users, just cleanup system
#   sudo ./uninstall-strix.sh --force --only-users  # Only remove users, keep system config
# ────────────────────────────────────────────────────────────────────

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/strix-provision"

# Service users created by provisioning (in dependency order for removal)
SERVICE_USERS=("ddns" "hosting" "defense" "claw" "llamacpp" "comfyui")

# System services to disable/remove (in stop order)
SYSTEM_SERVICES=("sync-llama-models" "llamacpp" "comfyui" "ace-step" 
                 "cisco-defense" "upnp-ssh.timer" "upnp-ssh.service"
                 "xrdp" "lightdm" "fail2ban")

# Files to remove (not user-specific)
SYSTEM_FILES=(
    "/etc/ssh/sshd_config.d/00-strix.conf"
    "/etc/apt/sources.list.d/rocm.list"
    "/etc/apt/preferences.d/rocm-pin-700"
    "/etc/fail2ban/jail.d/ssh-strix.conf"
    "/etc/sudoers.d/comfyui-upload"
    "/etc/default/upnp-ssh"
    "/usr/local/sbin/upnp-ssh-refresh"
    "/usr/local/bin/sync-llama-models.sh"
    "/usr/local/bin/comfyui-rsync-wrapper"
    "/etc/systemd/system/upnp-ssh.service"
    "/etc/systemd/system/upnp-ssh.timer"
    "/etc/NetworkManager/dispatcher.d/99-upnp-ssh"
    "/etc/networkd-dispatcher/routable.d/99-upnp-ssh"
)

# Directories to remove (generated content, not user data)
GENERATED_DIRS=(
    "/llama_models"
)

# UFW rules to delete (in order they were added)
UFW_RULES=(
    "allow from 100.64.0.0/10"
    "allow from 192.168.0.0/16"
    "allow from 172.16.0.0/12"
    "allow from 10.0.0.0/8"
    "limit 22/tcp"
)

# ROCm symlinks to clean up from /usr/local/bin
ROCM_BINS=("rocminfo" "rocm-smi" "hipcc" "hipconfig")

# --- CLI Flags ---
FORCE=false
SKIP_USERS=false
ONLY_USERS=false
QUIET=false
NO_COLOR=false
LOG_FILE=""
KEEP_SSH_CONFIG=false

# --- Colors ---
setup_colors() {
    if $NO_COLOR || [[ ! -t 1 ]]; then
        RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
    else
        RED='\033[0;31m'
        YELLOW='\033[1;33m'
        GREEN='\033[0;32m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        RESET='\033[0m'
    fi
}

_log() {
    local msg="$1"
    [[ -n "$LOG_FILE" ]] && echo "$(date -Iseconds) $msg" >> "$LOG_FILE"
    $QUIET || echo -e "$msg"
}

log_info() { _log "${CYAN}[INFO]${RESET} $1"; }
log_warn() { _log "${YELLOW}[WARN]${RESET} $1" >&2; }
log_success() { _log "${GREEN}[SUCCESS]${RESET} $1"; }
log_error() { _log "${RED}[ERROR]${RESET} $1" >&2; }
log_action() {
    if $FORCE; then
        _log "  ${GREEN}[EXEC]${RESET} $1"
    else
        _log "  ${YELLOW}[DRY]${RESET}  $1"
    fi
}
log_skip() { _log "  (skipped: $1)"; }

# --- Usage ---
usage() {
    cat <<'EOF'
Usage: uninstall-strix.sh [OPTIONS]

Complete uninstall for Strix Halo provisioning.

Options:
  --force              Execute the uninstall (default: dry-run)
  --skip-users         Don't remove service users (just system cleanup)
  --only-users         Only remove users, keep system configuration
  --keep-ssh-config    Preserve /etc/ssh/sshd_config.d/00-strix.conf
  --yes, -y            Skip confirmation prompt
  --log FILE           Write log to FILE
  --quiet, -q          Minimal output
  --no-color           Disable colored output
  -h, --help           Show this help

Examples:
  # See what would be removed:
  sudo ./uninstall-strix.sh

  # Actually uninstall everything:
  sudo ./uninstall-strix.sh --force

  # Keep service users (useful for debugging):
  sudo ./uninstall-strix.sh --force --skip-users

Preserved (never touched):
  - /models (your model files)
  - /ComfyUI-models (ComfyUI-specific models)
  - /var/lib/strix-provision/manifests/ (for re-provisioning)
  - .cache/ directory

EOF
}

# --- Argument Parsing ---
CONFIRM=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)             FORCE=true; shift ;;
        --skip-users)        SKIP_USERS=true; shift ;;
        --only-users)        ONLY_USERS=true; shift ;;
        --keep-ssh-config)   KEEP_SSH_CONFIG=true; shift ;;
        --yes|-y)            CONFIRM=false; shift ;;
        --quiet|-q)          QUIET=true; shift ;;
        --no-color)          NO_COLOR=true; shift ;;
        --log)
            [[ -n "${2:-}" ]] || { log_error "--log requires an argument"; exit 1; }
            LOG_FILE="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

setup_colors

[[ $(id -u) -eq 0 ]] || { log_error "Must run as root"; exit 1; }

# --- Safety Checks ---
# Never run if important env vars suggest this is a production system with
# non-strix users. This is a safety check for the service users.
validate_users_removable() {
    local user
    for user in "${SERVICE_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            # Check if user has login sessions or important processes
            if pgrep -u "$user" sshd &>/dev/null; then
                log_warn "User '$user' has active SSH sessions - aborting for safety"
                return 1
            fi
        fi
    done
    return 0
}

# --- Confirmation ---
if $FORCE && $CONFIRM; then
    echo -en "${RED}${BOLD}Type 'UNINSTALL STRIX' to completely remove all Strix Halo components: ${RESET}"
    read -r answer
    if [[ "$answer" != "UNINSTALL STRIX" ]]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# --- User Removal ---
remove_service_users() {
    log_info "Removing service users..."
    
    local remove_script="${SCRIPT_DIR}/remove-user.sh"
    if [[ ! -x "$remove_script" ]]; then
        log_error "remove-user.sh not found or not executable: $remove_script"
        return 1
    fi
    
    for user in "${SERVICE_USERS[@]}"; do
        if ! id "$user" &>/dev/null; then
            log_skip "user '$user' does not exist"
            continue
        fi
        
        log_action "Removing user: $user"
        if $FORCE; then
            # Use --no-backup to avoid cluttering backups dir (we're uninstalling)
            # Use --nuke-orphans to clean up any remaining files
            # Use --yes to skip confirmation
            if "$remove_script" --force --no-backup --nuke-orphans --yes "$user" 2>&1 | 
               while read -r line; do echo "    $line"; done; then
                log_success "Removed user: $user"
            else
                log_warn "Issues removing user: $user (check output above)"
            fi
        fi
    done
}

# --- System Services ---
stop_system_services() {
    log_info "Stopping and disabling system services..."
    
    for svc in "${SYSTEM_SERVICES[@]}"; do
        # Check if service file exists or is enabled
        if systemctl cat "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
            log_action "Stop & disable: $svc"
            if $FORCE; then
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                systemctl reset-failed "$svc" 2>/dev/null || true
            fi
        else
            log_skip "service '$svc' not found"
        fi
    done
    
    if $FORCE; then
        systemctl daemon-reload
    fi
}

# --- File Cleanup ---
remove_system_files() {
    log_info "Removing system configuration files..."
    
    for file in "${SYSTEM_FILES[@]}"; do
        # Special case: keep SSH config if requested
        if $KEEP_SSH_CONFIG && [[ "$file" == *"sshd_config.d"* ]]; then
            log_skip "SSH config preservation requested: $file"
            continue
        fi
        
        if [[ -f "$file" ]]; then
            log_action "Remove: $file"
            if $FORCE; then
                rm -f "$file"
            fi
        else
            log_skip "file not found: $file"
        fi
    done
}

# --- ROCm Cleanup ---
cleanup_rocm_symlinks() {
    log_info "Cleaning up ROCm symlinks..."
    
    # Remove ROCm symlinks from /usr/local/bin
    for bin in "${ROCM_BINS[@]}"; do
        local link="/usr/local/bin/$bin"
        if [[ -L "$link" ]]; then
            log_action "Remove symlink: $link"
            if $FORCE; then
                rm -f "$link"
            fi
        fi
    done
    
    # Remove /opt/rocm symlink (but not the actual install)
    if [[ -L /opt/rocm ]]; then
        log_action "Remove symlink: /opt/rocm"
        if $FORCE; then
            rm -f /opt/rocm
        fi
    fi
}

# --- UFW Rules ---
remove_ufw_rules() {
    log_info "Removing UFW rules..."
    
    # Check if UFW is active
    if ! ufw status &>/dev/null; then
        log_skip "UFW not active"
        return
    fi
    
    for rule in "${UFW_RULES[@]}"; do
        # Check if rule exists
        if ufw status | grep -q "$rule"; then
            log_action "Delete UFW rule: $rule"
            if $FORCE; then
                ufw delete $rule 2>/dev/null || log_warn "Could not delete rule: $rule"
            fi
        else
            log_skip "rule not found: $rule"
        fi
    done
}

# --- Generated Directories ---
remove_generated_dirs() {
    log_info "Removing generated directories..."
    
    for dir in "${GENERATED_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            log_action "Remove directory: $dir"
            if $FORCE; then
                rm -rf "$dir"
            fi
        else
            log_skip "directory not found: $dir"
        fi
    done
}

# --- SSH Config Validation ---
validate_ssh_config() {
    log_info "Validating SSH configuration..."
    
    if $KEEP_SSH_CONFIG; then
        log_skip "SSH config preservation requested, skipping validation"
        return
    fi
    
    if $FORCE; then
        if sshd -t 2>/dev/null; then
            log_success "SSH config is valid"
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        else
            log_warn "SSH config validation failed - manual check recommended"
            log_warn "Run: sshd -t"
        fi
    fi
}

# --- State Cleanup ---
cleanup_state() {
    log_info "Cleaning up state directory..."
    
    # Remove backups but keep manifests for potential re-provisioning
    if [[ -d "${STATE_DIR}/backups" ]]; then
        log_action "Remove: ${STATE_DIR}/backups"
        if $FORCE; then
            rm -rf "${STATE_DIR}/backups"
        fi
    fi
    
    # Note: manifests are preserved for re-provisioning reference
    if [[ -d "${STATE_DIR}/manifests" ]]; then
        log_info "Preserving manifests at ${STATE_DIR}/manifests/ for re-provisioning"
    fi
}

# --- Summary ---
print_summary() {
    echo ""
    if $FORCE; then
        log_success "Uninstall complete!"
        echo ""
        log_info "The following have been removed:"
        echo "  - All service users (comfyui, llamacpp, claw, hosting, ddns, defense)"
        echo "  - System services (llamacpp, comfyui, ace-step, cisco-defense, etc.)"
        echo "  - Configuration files (/etc/ssh/sshd_config.d/00-strix.conf, etc.)"
        echo "  - ROCm APT sources and preferences"
        echo "  - UFW rules added by provisioning"
        echo "  - /llama_models generated directory"
        echo ""
        log_info "The following have been PRESERVED:"
        echo "  - /models (your model files)"
        echo "  - /ComfyUI-models (ComfyUI model files, if created)"
        echo "  - /var/lib/strix-provision/manifests/ (for re-provisioning history)"
        echo "  - .cache/ directory (for faster re-provisioning)"
        echo "  - ROCm SDK installation at /opt/rocm-* (packages not removed)"
        echo ""
        log_warn "Manual cleanup may be required for:"
        echo "  - GRUB cmdline parameters (amdgpu.gttsize) - edit /etc/default/grub"
        echo "  - Installed packages (rocm-hip-sdk, xfce4, etc.) - use apt remove"
        echo "  - Kernel 6.18 - use mainline to remove"
        echo ""
        log_info "To re-provision later, run:"
        echo "  sudo ./provision_strix_halo.sh --force"
    else
        log_info "Dry-run complete. No changes were made."
        echo ""
        echo "Re-run with --force to execute the uninstall."
    fi
    
    if [[ -n "$LOG_FILE" ]]; then
        echo ""
        log_info "Log written to: $LOG_FILE"
    fi
}

# --- Main ---
main() {
    log_info "Strix Halo Uninstall"
    log_info "Mode: $($FORCE && echo "EXECUTE" || echo "DRY-RUN")"
    
    if ! $ONLY_USERS; then
        validate_users_removable || exit 1
    fi
    
    if ! $ONLY_USERS; then
        stop_system_services
        remove_ufw_rules
        remove_system_files
        cleanup_rocm_symlinks
        remove_generated_dirs
    fi
    
    if ! $SKIP_USERS; then
        remove_service_users
    fi
    
    if ! $ONLY_USERS; then
        validate_ssh_config
        cleanup_state
    fi
    
    print_summary
}

main "$@"
