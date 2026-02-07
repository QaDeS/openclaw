#!/bin/bash

# component_name: ComfyUI
# component_description: ComfyUI Backend (ROCm / GFX1151 Optimized)

install_comfyui() {
    log "Installing ComfyUI..."
    run sudo -u comfyui git clone https://github.com/comfyanonymous/ComfyUI.git /home/comfyui/ComfyUI || true
    if [ "$DRY_RUN" = false ]; then
        sudo -u comfyui bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
        # Install ROCm specific PyTorch for GFX1151
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install --pre torch torchvision torchaudio --index-url https://rocm.nightlies.amd.com/v2/gfx1151/
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install -r /home/comfyui/ComfyUI/requirements.txt
    fi
    run systemctl enable comfyui
}

register_component "COMFYUI" "install_comfyui"
