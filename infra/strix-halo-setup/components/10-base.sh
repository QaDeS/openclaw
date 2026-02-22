#!/bin/bash

# component_name: Base System
# component_description: Kernel 6.18, ROCm 7.2, and GPU Memory Optimization

install_base() {
    log "System update and kernel upgrade..."
    run apt update
    # Skip full upgrade when ROCm is already installed to avoid apt removing/churning SDK packages
    if [ "$REDOWNLOAD" = false ] && ls -d /opt/rocm-${ROCM_VERSION}* >/dev/null 2>&1; then
        log "ROCm ${ROCM_VERSION} present — skipping apt upgrade to avoid SDK package churn."
    else
        run apt upgrade -y
    fi
    if ! command -v mainline &> /dev/null; then
        run add-apt-repository ppa:cappelikan/ppa -y
        run apt update && run cached_apt_install mainline
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
        cached_fetch "https://repo.radeon.com/rocm/rocm.gpg.key" /tmp/rocm.gpg.key
        cat /tmp/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null
        rm -f /tmp/rocm.gpg.key
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${ubuntu_codename} main" | tee /etc/apt/sources.list.d/rocm.list
        track_file_create /etc/apt/sources.list.d/rocm.list
        cat <<'PINEOF' > /etc/apt/preferences.d/rocm-pin-700
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 700
PINEOF
        track_file_create /etc/apt/preferences.d/rocm-pin-700
    fi
    run apt update

    # Ensure rocminfo comes from the ROCm repo (not the Ubuntu universe package)
    if dpkg -l rocminfo 2>/dev/null | grep -q '^ii' && ! dpkg -s rocminfo 2>/dev/null | grep -q "repo.radeon.com"; then
        run apt remove -y rocminfo
    fi
    run cached_apt_install rocminfo

    # Link ROCm binaries into /usr/local/bin so they're always on PATH
    if [ "$DRY_RUN" = false ]; then
        local rocm_dir
        rocm_dir=$(find /opt -maxdepth 1 -name 'rocm-*' -type d 2>/dev/null | sort -V | tail -1)
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
        run cached_apt_install rocm-hip-sdk rocm-smi-lib mesa-va-drivers mesa-vdpau-drivers
        # Re-link after SDK install (adds hipcc, rocm-smi, etc.)
        if [ "$DRY_RUN" = false ]; then
            rocm_dir=$(find /opt -maxdepth 1 -name 'rocm-*' -type d 2>/dev/null | sort -V | tail -1)
            if [ -n "$rocm_dir" ] && [ -d "$rocm_dir/bin" ]; then
                ln -sfn "$rocm_dir" /opt/rocm
                for bin in "$rocm_dir"/bin/*; do
                    [ -x "$bin" ] && ln -sf "$bin" /usr/local/bin/
                done
            fi
        fi
    fi

    undo_note "Packages (rocm-hip-sdk, xfce4, kernel) not auto-removed on undo"

    log "Optimizing GPU Memory (GTT Size)..."
    if [ "$DRY_RUN" = false ]; then
        local total_mem=$(free -g | awk '/^Mem:/{print $2}')
        local gtt_size_mb=$((total_mem * 1024 / 2))
        if ! grep -q "amdgpu.gttsize" /etc/default/grub; then
            track_file_modify /etc/default/grub
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

    # Graphical desktop (HDMI auto-detected) + xrdp for headless remote access
    if [ "$DRY_RUN" = false ]; then
        cached_apt_install xorg xserver-xorg-video-amdgpu xfce4 lightdm \
                       xrdp xvfb
        # Remove any forced driver config — let Xorg auto-detect hardware.
        # HDMI connected → amdgpu picked up automatically → lightdm serves desktop.
        # No HDMI → Xorg finds no screens → lightdm stops → xrdp still works (Xvnc).
        rm -f /etc/X11/xorg.conf.d/70-dummy.conf \
              /etc/X11/xorg.conf.d/70-amdgpu.conf
    fi

    # Bind xrdp to localhost only — access via SSH tunnel (key-gated)
    if [ "$DRY_RUN" = false ]; then
        track_file_modify /etc/xrdp/xrdp.ini
        sed -i 's/^port=.*/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini
    fi
    run systemctl enable lightdm
    run systemctl enable xrdp
    run systemctl restart xrdp
    track_service lightdm
    track_service xrdp
}

# Registration
register_component "BASE" "install_base" "setup_shared_dirs" "deploy_base_config"
