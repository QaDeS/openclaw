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

install_comfyui_manager() {
    log "Installing ComfyUI Manager (server-side model downloads)..."
    local repo_dir="/home/comfyui/ComfyUI"
    local manager_dir="${repo_dir}/custom_nodes/ComfyUI-Manager"
    local UV="/home/comfyui/.local/bin/uv"
    local VENV_PYTHON="${repo_dir}/.venv/bin/python"

    if [ "$DRY_RUN" = false ]; then
        if [ -d "$manager_dir" ] && [ "$REDOWNLOAD" = false ]; then
            log "ComfyUI Manager already installed, pulling latest..."
            sudo -u comfyui git -C "$manager_dir" pull --rebase
        else
            sudo -u comfyui rm -rf "$manager_dir"
            sudo -u comfyui git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$manager_dir"
        fi

        # Install Manager dependencies
        if [ -f "${manager_dir}/requirements.txt" ]; then
            sudo -u comfyui "$UV" --no-config pip install \
                --python "$VENV_PYTHON" \
                -r "${manager_dir}/requirements.txt"
        fi

        # Configure server-side model downloads (no browser download/re-upload)
        local config_dir="${repo_dir}/user/default"
        sudo -u comfyui mkdir -p "$config_dir"
        local settings_file="${config_dir}/comfy.settings.json"
        if [ -f "$settings_file" ]; then
            # Merge setting into existing config
            sudo -u comfyui "$VENV_PYTHON" -c "
import json, pathlib
p = pathlib.Path('${settings_file}')
cfg = json.loads(p.read_text())
cfg['ComfyUI-Manager.ModelDownloadMethod'] = 'server-only'
p.write_text(json.dumps(cfg, indent=2))
"
        else
            sudo -u comfyui tee "$settings_file" > /dev/null <<'JSONEOF'
{
  "ComfyUI-Manager.ModelDownloadMethod": "server-only"
}
JSONEOF
        fi
        log "ComfyUI Manager configured for server-side model downloads."
    fi
}

register_component "COMFYUI" "install_comfyui" "install_comfyui_manager"
