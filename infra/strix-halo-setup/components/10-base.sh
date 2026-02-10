#!/bin/bash

# component_name: Base System
# component_description: Kernel 6.18, ROCm 7.2, and GPU Memory Optimization

install_base() {
    log "System update and kernel upgrade..."
    run apt update && run apt upgrade -y
    if ! command -v mainline &> /dev/null; then
        run add-apt-repository ppa:cappelikan/ppa -y
        run apt update && run apt install mainline -y
    fi
    run mainline install ${KERNEL_VERSION} || log "Kernel ${KERNEL_VERSION} already installed, continuing."

    # ROCm repo setup (cheap, idempotent)
    log "Configuring ROCm ${ROCM_VERSION} repository..."
    run mkdir -p /etc/apt/keyrings
    if [ "$DRY_RUN" = false ]; then
        local ubuntu_codename
        ubuntu_codename=$(grep -oP 'UBUNTU_CODENAME=\K\w+' /etc/os-release 2>/dev/null || lsb_release -cs 2>/dev/null)
        case "$ubuntu_codename" in
            noble|jammy) ;;
            *) ubuntu_codename="noble" ;;
        esac
        wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${ubuntu_codename} main" | tee /etc/apt/sources.list.d/rocm.list
        cat <<'PINEOF' > /etc/apt/preferences.d/rocm-pin-700
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 700
PINEOF
    fi
    run apt update

    # Ensure rocminfo comes from the ROCm repo (not the Ubuntu universe package)
    if dpkg -l rocminfo 2>/dev/null | grep -q '^ii' && ! dpkg -s rocminfo 2>/dev/null | grep -q "repo.radeon.com"; then
        run apt remove -y rocminfo
    fi
    run apt install -y rocminfo

    # Link ROCm binaries into /usr/local/bin so they're always on PATH
    if [ "$DRY_RUN" = false ]; then
        local rocm_dir
        rocm_dir=$(ls -d /opt/rocm-* 2>/dev/null | sort -V | tail -1)
        if [ -n "$rocm_dir" ] && [ -d "$rocm_dir/bin" ]; then
            ln -sfn "$rocm_dir" /opt/rocm
            for bin in "$rocm_dir"/bin/*; do
                [ -x "$bin" ] && ln -sf "$bin" /usr/local/bin/
            done
            log "Linked ROCm binaries from $rocm_dir/bin → /usr/local/bin"
        fi
    fi

    # Check if ROCm SDK is already installed at the target version
    if [ "$DRY_RUN" = false ] && [ "$REDOWNLOAD" = false ] \
        && ls -d /opt/rocm-${ROCM_VERSION}* >/dev/null 2>&1 \
        && rocminfo 2>/dev/null | grep -q "ROCk module version"; then
        log "ROCm ${ROCM_VERSION} already installed and driver loaded, skipping SDK install."
    else
        log "Installing ROCm ${ROCM_VERSION} SDK..."
        run apt install -y rocm-hip-sdk rocm-smi-lib mesa-va-drivers mesa-vdpau-drivers
        # Re-link after SDK install (adds hipcc, rocm-smi, etc.)
        if [ "$DRY_RUN" = false ]; then
            rocm_dir=$(ls -d /opt/rocm-* 2>/dev/null | sort -V | tail -1)
            if [ -n "$rocm_dir" ] && [ -d "$rocm_dir/bin" ]; then
                ln -sfn "$rocm_dir" /opt/rocm
                for bin in "$rocm_dir"/bin/*; do
                    [ -x "$bin" ] && ln -sf "$bin" /usr/local/bin/
                done
            fi
        fi
    fi

    log "Optimizing GPU Memory (GTT Size)..."
    if [ "$DRY_RUN" = false ]; then
        local total_mem=$(free -g | awk '/^Mem:/{print $2}')
        local gtt_size_mb=$((total_mem / 2 * 1024))
        if ! grep -q "amdgpu.gttsize" /etc/default/grub; then
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"amdgpu.gttsize=${gtt_size_mb} /" /etc/default/grub
            update-grub
            log "GTT Size set to ${gtt_size_mb}MB. Requires reboot."
        fi
    fi
}

setup_shared_dirs() {
    log "Setting up shared group and directories..."
    run groupadd -f ai-users
    run mkdir -p ${SHARED_MODEL_DIR}
    run chown :ai-users ${SHARED_MODEL_DIR}
    run chmod 2775 ${SHARED_MODEL_DIR}
}

deploy_base_config() {
    log "Deploying base configurations..."

    # Dummy Xorg for GFX1151
    if [ "$DRY_RUN" = false ]; then
        apt install -y xrdp xserver-xorg-video-dummy
        cat <<EOF > /etc/X11/xorg.conf.d/70-dummy.conf
Section "Device"
    Identifier  "GFX1151"
    Driver      "dummy"
    VideoRam    1024000
EndSection
Section "Screen"
    Identifier  "Default Screen"
    Device      "GFX1151"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "3840x2160"
    EndSubSection
EndSection
EOF
    fi
    run systemctl enable xrdp
    run systemctl restart xrdp
}

# Registration
register_component "BASE" "install_base" "setup_shared_dirs" "deploy_base_config"
