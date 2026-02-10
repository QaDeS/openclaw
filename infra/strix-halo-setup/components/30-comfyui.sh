#!/bin/bash

# component_name: ComfyUI
# component_description: ComfyUI Backend (ROCm / GFX1151 Optimized)

install_comfyui() {
    log "Installing ComfyUI..."
    ensure_user comfyui

    local repo_dir="/home/comfyui/ComfyUI"
    local venv_dir="${repo_dir}/.venv"
    local UV="/home/comfyui/.local/bin/uv"

    # Clone or update
    if [ "$DRY_RUN" = false ]; then
        if [ -d "$repo_dir" ] && [ "$REDOWNLOAD" = false ]; then
            log "ComfyUI already cloned, pulling latest..."
            sudo -u comfyui git -C "$repo_dir" pull --rebase
        else
            sudo -u comfyui rm -rf "$repo_dir"
            sudo -u comfyui git clone https://github.com/comfyanonymous/ComfyUI.git "$repo_dir"
        fi
    fi

    if [ "$DRY_RUN" = false ]; then
        # Install uv
        sudo -u comfyui bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
        # Create venv
        sudo -u comfyui "$UV" --no-config venv "$venv_dir"
        # Install ROCm specific PyTorch for GFX1151
        sudo -u comfyui "$UV" --no-config pip install \
            --python "${venv_dir}/bin/python" \
            --pre torch torchvision torchaudio \
            --index-url https://rocm.nightlies.amd.com/v2/gfx1151/
        sudo -u comfyui "$UV" --no-config pip install \
            --python "${venv_dir}/bin/python" \
            -r "${repo_dir}/requirements.txt"
    fi
    run cp ${INFRA_DIR}/systemd/comfyui.service /etc/systemd/system/comfyui.service
    run systemctl daemon-reload
    run systemctl enable comfyui
}

register_component "COMFYUI" "install_comfyui"
