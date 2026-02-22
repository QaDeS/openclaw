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
            sudo -u comfyui git -C "$repo_dir" checkout -- .
            sudo -u comfyui git -C "$repo_dir" pull --rebase
        else
            sudo -u comfyui rm -rf "$repo_dir"
            sudo -u comfyui bash -c "source '${CACHE_HELPERS}' && cached_git_clone 'https://github.com/comfyanonymous/ComfyUI.git' '$repo_dir'"
        fi
    fi

    if [ "$DRY_RUN" = false ]; then
        # Install uv
        if [ ! -f "$UV" ]; then
            sudo -u comfyui bash -c "source '${CACHE_HELPERS}' && cached_curl_pipe 'https://astral.sh/uv/install.sh' sh"
        fi

        # Check if venv already has ROCm torch installed
        local need_venv=true
        if [ -f "${venv_dir}/bin/python" ]; then
            local hip
            hip=$("${venv_dir}/bin/python" -c "import torch; print(torch.version.hip or '')" 2>/dev/null || true)
            if [ -n "$hip" ]; then
                log "Venv already has ROCm torch (HIP ${hip}), skipping reinstall."
                need_venv=false
            fi
        fi

        if [ "$need_venv" = true ] || [ "$REDOWNLOAD" = true ]; then
            # Create/recreate venv
            sudo -u comfyui "$UV" --no-config venv --clear "$venv_dir"
            # Install ROCm specific PyTorch for GFX1151
            local pip_cache_args
            pip_cache_args=$(cached_pip_index_args torch-rocm-gfx1151)
            if [ -n "$pip_cache_args" ]; then
                sudo -u comfyui UV_CACHE_DIR="${UV_CACHE_DIR:-}" "$UV" --no-config pip install \
                    --python "${venv_dir}/bin/python" \
                    --pre torch torchvision torchaudio \
                    $pip_cache_args
            else
                sudo -u comfyui UV_CACHE_DIR="${UV_CACHE_DIR:-}" "$UV" --no-config pip install \
                    --python "${venv_dir}/bin/python" \
                    --pre torch torchvision torchaudio \
                    --index-url https://rocm.nightlies.amd.com/v2/gfx1151/
            fi
            sudo -u comfyui UV_CACHE_DIR="${UV_CACHE_DIR:-}" "$UV" --no-config pip install \
                --python "${venv_dir}/bin/python" \
                -r "${repo_dir}/requirements.txt"
        fi
    fi
    # Allow the provisioning user to rsync files as comfyui (model uploads)
    # Uses a wrapper script to restrict destinations to ComfyUI models dir only
    if [ -n "$SUDO_USER" ]; then
        run cp ${INFRA_DIR}/scripts/comfyui-rsync-wrapper.sh /usr/local/bin/comfyui-rsync-wrapper
        run chmod 755 /usr/local/bin/comfyui-rsync-wrapper
        run tee /etc/sudoers.d/comfyui-upload > /dev/null <<EOF
${SUDO_USER} ALL=(comfyui) NOPASSWD: /usr/local/bin/comfyui-rsync-wrapper
EOF
        run chmod 0440 /etc/sudoers.d/comfyui-upload
        track_file_create /etc/sudoers.d/comfyui-upload
        track_file_create /usr/local/bin/comfyui-rsync-wrapper
    fi

    # Ensure ComfyUI shared models directory exists and link it
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "${COMFYUI_MODELS_DIR}"
        chown :ai-users "${COMFYUI_MODELS_DIR}"
        chmod 2775 "${COMFYUI_MODELS_DIR}"
        sudo -u comfyui ln -sfn "${COMFYUI_MODELS_DIR}" "${repo_dir}/models"
        log "Linked ${repo_dir}/models → ${COMFYUI_MODELS_DIR}"
    fi
    track_symlink "${repo_dir}/models" "${COMFYUI_MODELS_DIR}"

    run cp ${INFRA_DIR}/systemd/comfyui.service /etc/systemd/system/comfyui.service
    track_file_create /etc/systemd/system/comfyui.service
    run systemctl daemon-reload
    run systemctl enable comfyui
    track_service comfyui
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
            sudo -u comfyui git -C "$manager_dir" checkout -- .
            sudo -u comfyui git -C "$manager_dir" pull --rebase
        else
            sudo -u comfyui rm -rf "$manager_dir"
            sudo -u comfyui bash -c "source '${CACHE_HELPERS}' && cached_git_clone 'https://github.com/ltdrdata/ComfyUI-Manager.git' '$manager_dir'"
        fi

        # Install Manager dependencies
        if [ -f "${manager_dir}/requirements.txt" ]; then
            sudo -u comfyui UV_CACHE_DIR="${UV_CACHE_DIR:-}" "$UV" --no-config pip install \
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
