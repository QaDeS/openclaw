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
    run mainline install ${KERNEL_VERSION}

    log "ROCm ${ROCM_VERSION} Installation..."
    run mkdir -p /etc/apt/keyrings
    if [ "$DRY_RUN" = false ]; then
        # Detect Ubuntu codename (works on Mint/derivatives via UBUNTU_CODENAME)
        local ubuntu_codename
        ubuntu_codename=$(grep -oP 'UBUNTU_CODENAME=\K\w+' /etc/os-release 2>/dev/null || lsb_release -cs 2>/dev/null)
        # ROCm 7.2 ships noble and jammy; fall back to noble for 24.04+ derivatives
        case "$ubuntu_codename" in
            noble|jammy) ;;
            *) ubuntu_codename="noble" ;;
        esac
        wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${ubuntu_codename} main" | tee /etc/apt/sources.list.d/rocm.list
        # Pin ROCm repo higher than Ubuntu universe (which ships older rocminfo/hipcc)
        cat <<'PINEOF' > /etc/apt/preferences.d/rocm-pin-700
Package: *
Pin: origin repo.radeon.com
Pin-Priority: 700
PINEOF
    fi
    run apt update
    run apt install -y rocm-hip-sdk rocm-smi-lib mesa-va-drivers mesa-vdpau-drivers

    log "Optimizing GPU Memory (GTT Size)..."
    if [ "$DRY_RUN" = false ]; then
        local total_mem=$(free -g | awk '/^Mem:/{print $2}')
        local gtt_size=$((total_mem / 2))
        if ! grep -q "amdgpu.gttsize" /etc/default/grub; then
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"amdgpu.gttsize=${gtt_size}G /" /etc/default/grub
            update-grub
            log "GTT Size set to ${gtt_size}G. Requires reboot."
        fi
    fi
}

setup_users() {
    log "Setting up users and shared directories..."
    run groupadd -f ai-users
    run mkdir -p ${SHARED_MODEL_DIR}
    run chown :ai-users ${SHARED_MODEL_DIR}
    run chmod 2775 ${SHARED_MODEL_DIR}

    for user in "${AI_USERS[@]}"; do
        if ! id "$user" &>/dev/null; then
            run useradd -m -s /bin/bash -G ai-users,render,video "$user"
        fi
    done
}

deploy_base_config() {
    log "Deploying systemd units and configurations..."
    run cp ${INFRA_DIR}/systemd/*.service /etc/systemd/system/
    run systemctl daemon-reload

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
register_component "BASE" "install_base" "setup_users" "deploy_base_config"
