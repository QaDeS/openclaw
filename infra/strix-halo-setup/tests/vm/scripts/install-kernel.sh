#!/bin/bash
# Install newer kernel for AMD GPU passthrough stability
# Kernel 6.17.9+ or 6.19+ recommended for Strix Halo gfx1151

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/kernel-install.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

show_help() {
    cat << 'HELP'
Usage: install-kernel.sh [VERSION]

Install a newer kernel for AMD GPU passthrough stability.

Arguments:
    VERSION     Kernel version to install (e.g., 6.17.9, 6.19.0)
                If not specified, shows available versions and recommendations

Examples:
    ./install-kernel.sh           # Show recommendations and available versions
    ./install-kernel.sh 6.17.9    # Install kernel 6.17.9
    ./install-kernel.sh 6.19.0    # Install kernel 6.19.0 (when available)

Recommended versions for Strix Halo:
    6.17.9      - Stable, well-tested with AMD GPU passthrough
    6.19+       - Latest, may have better gfx1151 support

Avoid:
    6.18.0-6.18.3  - Known amdgpu MES hang issues with ROCm
HELP
}

check_mainline() {
    if ! command -v mainline &> /dev/null; then
        log "Installing mainline tool..."
        sudo apt update
        sudo apt install -y mainline
    fi
}

list_available_kernels() {
    log "Checking available kernel versions..."
    
    echo ""
    echo "Available kernels from mainline:"
    mainline --list 2>/dev/null | grep -E "^6\.[0-9]+" | head -20 || {
        echo "Could not fetch kernel list. Checking online..."
        curl -s "https://kernel.ubuntu.com/~kernel-ppa/mainline/" 2>/dev/null | \
            grep -oE 'v6\.[0-9]+\.[0-9]+' | sort -V | tail -10 | sed 's/^v/  /' || \
            echo "  (Could not fetch online list)"
    }
    
    echo ""
    echo "Currently running kernel: $(uname -r)"
    
    echo ""
    echo "RECOMMENDATIONS for Strix Halo GPU passthrough:"
    echo "  ✓ 6.17.9 or later in 6.17 series - Stable with amdgpu"
    echo "  ✓ 6.19.0 or later - Latest features, best gfx1151 support"
    echo "  ✗ Avoid 6.18.0-6.18.3 - Known MES hang issues with ROCm"
    
    current_minor=$(uname -r | cut -d. -f2)
    current_patch=$(uname -r | cut -d. -f3 | cut -d- -f1)
    
    if [ "$current_minor" -eq 18 ] && [ "$current_patch" -lt 4 ] 2>/dev/null; then
        echo ""
        echo "⚠️  WARNING: You are running kernel 6.18.$current_patch"
        echo "   This version has known amdgpu hang issues."
        echo "   Strongly recommend upgrading to 6.17.9 or 6.19+"
    fi
}

install_kernel() {
    local version="$1"
    
    log "Installing kernel version: $version"
    
    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR: Invalid version format. Use format: X.Y.Z (e.g., 6.17.9)"
        exit 1
    fi
    
    # Check if already installed
    if dpkg -l | grep -q "linux-image-$version"; then
        log "Kernel $version appears to be already installed"
        read -p "Reinstall? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Skipping installation"
            return
        fi
    fi
    
    log "Downloading and installing kernel $version..."
    log "This may take several minutes..."
    
    # Install using mainline
    if ! sudo mainline --install "$version" 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR: Failed to install kernel $version"
        log "You may need to check available versions with: mainline --list"
        exit 1
    fi
    
    log "[OK] Kernel $version installed successfully"
    
    echo ""
    echo "========================================"
    echo "Kernel $version has been installed!"
    echo ""
    echo "To use the new kernel:"
    echo "  1. Reboot: sudo reboot"
    echo "  2. Select the new kernel in GRUB menu (if not default)"
    echo "  3. Verify: uname -r"
    echo ""
    echo "To set as default kernel:"
    echo "  sudo grub-set-default 'Advanced options for Ubuntu>Ubuntu, with Linux $version-generic'"
    echo "  sudo update-grub"
    echo "========================================"
}

install_dependencies() {
    log "Checking dependencies..."
    
    local deps="mainline curl"
    local missing=()
    
    for dep in $deps; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing missing dependencies: ${missing[*]}"
        sudo apt update
        sudo apt install -y "${missing[@]}"
    fi
}

main() {
    local version="${1:-}"
    
    if [ -z "$version" ] || [ "$version" = "--help" ] || [ "$version" = "-h" ]; then
        show_help
        echo ""
        list_available_kernels
        exit 0
    fi
    
    install_dependencies
    check_mainline
    install_kernel "$version"
}

main "$@"
