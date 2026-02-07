#!/bin/bash

# provision_strix_halo.sh
# Final version: Consolidates all requirements into one guarded script.
# Strix Halo (GFX1151) | Kernel 6.18+ | ROCm 7.2+ | AI Services | Cisco Defense
# Safety: Defaults to DRY RUN. Requires --force and HEAVY confirmation for live execution.

set -eo pipefail

# --- Configuration ---
PROJECT_ROOT="/Projects/clawd/openclaw" 
INFRA_DIR="${PROJECT_ROOT}/infra/strix-halo-setup"
KERNEL_VERSION="6.18.4"
ROCM_VERSION="7.2"
AI_USERS=("lmstudio" "comfyui" "claw" "hosting" "defense")
SHARED_MODEL_DIR="/opt/ai/models"
LM_STUDIO_URL="https://releases.lmstudio.ai/linux/x86_64/latest/LM-Studio.AppImage"
ACE_STEP_MODEL_URL="https://huggingface.co/Linaqruf/ace-step-1.5-turbo-aio/resolve/main/ace_step_1.5_turbo_aio.safetensors"
HSA_OVERRIDE="11.5.1"
INSTALL_MODES=()

DRY_RUN=true
[[ "$*" == *"--force"* ]] && DRY_RUN=false

# --- Colors ---
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
        read -p "Type 'I UNDERSTAND THE RISKS' to proceed: " confirm
        [[ "$confirm" != "I UNDERSTAND THE RISKS" ]] && error "Confirmation failed."
    fi
}

install_base() {
    log "System update and kernel upgrade..."
    run apt update && run apt upgrade -y
    if ! command -v mainline &> /dev/null; then
        run add-apt-repository ppa:cappelikan/ppa -y
        run apt update && run apt install mainline -y
    fi
    run mainline --install ${KERNEL_VERSION}

    log "ROCm ${ROCM_VERSION} Installation..."
    run mkdir -p /etc/apt/keyrings
    if [ "$DRY_RUN" = false ]; then
        wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} jammy main" | tee /etc/apt/sources.list.d/rocm.list
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

deploy_config() {
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

install_lmstudio() {
    log "Installing LM Studio..."
    run sudo -u lmstudio mkdir -p /home/lmstudio/bin
    run sudo -u lmstudio mkdir -p /home/lmstudio/.cache/lm-studio
    if [ "$DRY_RUN" = false ]; then
        sudo -u lmstudio wget -O /home/lmstudio/bin/lm-studio.AppImage ${LM_STUDIO_URL}
        sudo -u lmstudio chmod +x /home/lmstudio/bin/lm-studio.AppImage
        sudo -u lmstudio ln -sf ${SHARED_MODEL_DIR} /home/lmstudio/.cache/lm-studio/models
    fi
    run systemctl enable llmster
}

install_comfyui() {
    log "Installing ComfyUI..."
    run sudo -u comfyui git clone https://github.com/comfyanonymous/ComfyUI.git /home/comfyui/ComfyUI || true
    if [ "$DRY_RUN" = false ]; then
        sudo -u comfyui bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install --pre torch torchvision torchaudio --index-url https://rocm.nightlies.amd.com/v2/gfx1151/
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install -r /home/comfyui/ComfyUI/requirements.txt
    fi
    run systemctl enable comfyui
}

install_ace_step() {
    log "Installing ACE Step 1.5 (Music Generation)..."
    local model_path="${SHARED_MODEL_DIR}/checkpoints/ace_step_1.5_turbo_aio.safetensors"
    run mkdir -p "${SHARED_MODEL_DIR}/checkpoints"
    if [ "$DRY_RUN" = false ]; then
        if [ ! -f "$model_path" ]; then
            wget -O "$model_path" "${ACE_STEP_MODEL_URL}"
        fi
        # ACE Step often needs specific transformers/diffusers versions to avoid hangs on Strix
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install "transformers>=4.48.0" "diffusers>=0.32.0"
    fi
}

install_zimage() {
    log "Installing Z-Image Turbo Base..."
    # Z-Image optimization for Strix Halo (FP8 preferred)
    if [ "$DRY_RUN" = false ]; then
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install "accelerate>=1.2.0"
        # Ensure VAE decoding doesn't hang (Triton/FlashAttention)
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install "triton>=3.0.0"
    fi
}

install_cisco_defense() {
    log "Installing Cisco AI Defense..."
    run cp ${INFRA_DIR}/defense/cisco-defense-daemon.py /home/defense/
    run chown defense:defense /home/defense/cisco-defense-daemon.py
    if [ "$DRY_RUN" = false ]; then
        sudo -u defense bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
        sudo -u defense /home/defense/.local/bin/uv tool install a2a-scanner --python 3.11
        sudo -u defense /home/defense/.local/bin/uv tool install mcp-scanner --python 3.11
        sudo -u defense /home/defense/.local/bin/uv tool install skill-scanner --python 3.11
    fi
    run systemctl enable cisco-defense
}

install_docker_services() {
    log "Installing Dockerized Services (OpenClaw, Hosting)..."
    if ! command -v docker &> /dev/null; then
        run curl -fsSL https://get.docker.com | sh
    fi
    run usermod -aG docker claw
    run usermod -aG docker hosting
    
    # OpenClaw Local Deployment (from current checkout)
    run sudo -u claw mkdir -p /home/claw/openclaw
    if [ "$DRY_RUN" = false ]; then
        # Copy current checkout to claw user's home
        cp -r ${PROJECT_ROOT}/. /home/claw/openclaw/
        chown -R claw:claw /home/claw/openclaw
    fi
    run cp ${INFRA_DIR}/docker/openclaw-compose.yml /home/claw/openclaw/docker-compose.yml
    run chown claw:claw /home/claw/openclaw/docker-compose.yml
    run systemctl enable openclaw

    run sudo -u hosting mkdir -p /home/hosting/hosting-stack
    run cp ${INFRA_DIR}/docker/hosting-compose.yml /home/hosting/hosting-stack/docker-compose.yml
    run chown hosting:hosting /home/hosting/hosting-stack/docker-compose.yml
    run systemctl enable hosting

    log "Generating service secrets..."
    if [ "$DRY_RUN" = false ]; then
        local pg_pass=$(openssl rand -hex 16)
        echo "SUPABASE_DB_PASSWORD=${pg_pass}" | tee /home/hosting/hosting-stack/.env > /dev/null
        chown hosting:hosting /home/hosting/hosting-stack/.env
        echo "LMSTUDIO_BASE_URL=http://localhost:1234/v1" | tee /home/claw/openclaw/.env > /dev/null
        chown claw:claw /home/claw/openclaw/.env
    fi
}

show_menu() {
    echo -e "${BLUE}=== Strix Halo Setup Menu ===${NC}"
    echo "1) Full Installation (Everything)"
    echo "2) Base System & ROCm Only"
    echo "3) LLM Stack (LM Studio + OpenClaw)"
    echo "4) Image/Music Stack (ComfyUI + Z-Image + ACE Step)"
    echo "5) Security (Cisco AI Defense)"
    echo "6) Custom (Select steps)"
    echo "q) Quit"
    read -p "Select an option: " choice

    case $choice in
        1) INSTALL_MODES=("BASE" "LLM" "IMAGE" "MUSIC" "SECURITY") ;;
        2) INSTALL_MODES=("BASE") ;;
        3) INSTALL_MODES=("BASE" "LLM") ;;
        4) INSTALL_MODES=("BASE" "IMAGE" "MUSIC") ;;
        5) INSTALL_MODES=("BASE" "SECURITY") ;;
        6)
            read -p "Install Base (y/n)? " ib && [[ $ib == "y" ]] && INSTALL_MODES+=("BASE")
            read -p "Install LLMs (y/n)? " il && [[ $il == "y" ]] && INSTALL_MODES+=("LLM")
            read -p "Install ComfyUI/Z-Image (y/n)? " ii && [[ $ii == "y" ]] && INSTALL_MODES+=("IMAGE")
            read -p "Install ACE Step 1.5 (y/n)? " im && [[ $im == "y" ]] && INSTALL_MODES+=("MUSIC")
            read -p "Install Cisco Defense (y/n)? " is && [[ $is == "y" ]] && INSTALL_MODES+=("SECURITY")
            ;;
        q) exit 0 ;;
        *) error "Invalid option." ;;
    esac
}

harden() {
    log "Hardening System..."
    if [ "$DRY_RUN" = false ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        systemctl restart ssh
    fi
    run ufw allow 22
    run ufw allow 3389
    run ufw --force enable
}

main() {
    [[ $EUID -ne 0 ]] && error "Run as root."
    check_ssh_safety
    confirm_execution

    if [[ "$*" == *"--all"* ]]; then
        INSTALL_MODES=("BASE" "LLM" "IMAGE" "MUSIC" "SECURITY")
    else
        show_menu
    fi

    # 1. Base components
    if [[ " ${INSTALL_MODES[@]} " =~ " BASE " ]]; then
        install_base
        setup_users
        deploy_config
    fi

    # 2. LLM Stack
    if [[ " ${INSTALL_MODES[@]} " =~ " LLM " ]]; then
        install_lmstudio
        install_docker_services
    fi

    # 3. Image Stack
    if [[ " ${INSTALL_MODES[@]} " =~ " IMAGE " ]]; then
        install_comfyui
        install_zimage
    fi

    # 4. Music Stack
    if [[ " ${INSTALL_MODES[@]} " =~ " MUSIC " ]]; then
        # Music requires ComfyUI backend
        if [[ ! " ${INSTALL_MODES[@]} " =~ " IMAGE " ]]; then
            install_comfyui
        fi
        install_ace_step
    fi

    # 5. Security
    if [[ " ${INSTALL_MODES[@]} " =~ " SECURITY " ]]; then
        install_cisco_defense
    fi

    harden
    success "Provisioning complete for selected components! REBOOT is required."
}

main "$@"
