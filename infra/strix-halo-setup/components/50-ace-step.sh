#!/bin/bash

# component_name: ACE Step 1.5 Standalone
# component_description: Standalone Music Generation Server (ROCm 7.2+ / GFX1151, pinned to avoid NVIDIA fallback)

ACE_STEP_REPO="https://github.com/ACE-Step/ACE-Step-1.5.git"
ACE_STEP_HOME="/home/comfyui/ACE-Step-1.5"
ACE_STEP_VENV="${ACE_STEP_HOME}/venv_rocm"
# ROCm nightly index for GFX1151 — standard rocm6.x wheels lack gfx1151 kernels
ACE_STEP_TORCH_INDEX="https://rocm.nightlies.amd.com/v2/gfx1151/"

install_ace_step() {
    log "Installing ACE Step 1.5 Standalone (Music Generation)..."

    # 1. Clone the standalone project
    run sudo -u comfyui git clone "${ACE_STEP_REPO}" "${ACE_STEP_HOME}" || true

    if [ "$DRY_RUN" = false ]; then
        # 2. Create an isolated venv (NOT uv sync — that pulls CUDA torch)
        sudo -u comfyui python3.11 -m venv "${ACE_STEP_VENV}"
        local PIP="${ACE_STEP_VENV}/bin/pip"
        local PYTHON="${ACE_STEP_VENV}/bin/python"

        # 3. Install ROCm PyTorch FIRST — this must happen before any other
        #    package can drag in CUDA torch as a transitive dependency
        sudo -u comfyui "$PIP" install --pre \
            torch torchvision torchaudio \
            --index-url "${ACE_STEP_TORCH_INDEX}"

        # 4. Install project deps WITHOUT re-resolving torch.
        #    Use requirements-rocm-linux.txt if present (ships with ACE-Step 1.5),
        #    otherwise fall back to the standard requirements minus torch.
        if [ -f "${ACE_STEP_HOME}/requirements-rocm-linux.txt" ]; then
            sudo -u comfyui "$PIP" install -r "${ACE_STEP_HOME}/requirements-rocm-linux.txt"
        else
            log "No requirements-rocm-linux.txt found, installing core deps manually..."
            sudo -u comfyui "$PIP" install \
                "transformers>=4.51.0,<4.58.0" \
                "diffusers" \
                "accelerate>=1.12.0" \
                "gradio==6.2.0" \
                "fastapi>=0.110.0" \
                "uvicorn[standard]>=0.27.0" \
                "vector-quantize-pytorch>=1.27.15" \
                "numba>=0.63.1" \
                "einops>=0.8.1" \
                "scipy>=1.10.1"
        fi

        # 5. Install nano-vllm (bundled local package)
        if [ -d "${ACE_STEP_HOME}/acestep/third_parts/nano-vllm" ]; then
            sudo -u comfyui "$PIP" install -e "${ACE_STEP_HOME}/acestep/third_parts/nano-vllm"
        fi

        # 6. Install ACE-Step itself with --no-deps to prevent pip from
        #    re-resolving torch (the CUDA→ROCm overwrite problem)
        sudo -u comfyui "$PIP" install -e "${ACE_STEP_HOME}" --no-deps

        # 7. Verify ROCm torch is still in place
        _verify_rocm_torch "$PYTHON"

        # 8. Symlink shared model directory so downloaded checkpoints are shared
        sudo -u comfyui ln -sfn "${SHARED_MODEL_DIR}" "${ACE_STEP_HOME}/checkpoints"
    fi

    run systemctl enable ace-step
}

_verify_rocm_torch() {
    local python_bin="$1"
    log "Verifying ROCm PyTorch installation..."
    local hip_version
    hip_version=$("$python_bin" -c "import torch; print(torch.version.hip or 'NONE')" 2>/dev/null)

    if [ "$hip_version" = "NONE" ] || [ -z "$hip_version" ]; then
        warn "ROCm PyTorch verification FAILED — torch.version.hip is empty."
        warn "Something reinstalled CUDA torch. Forcing ROCm reinstall..."
        local PIP="${ACE_STEP_VENV}/bin/pip"
        sudo -u comfyui "$PIP" uninstall torch torchvision torchaudio -y
        sudo -u comfyui "$PIP" install --pre \
            torch torchvision torchaudio \
            --index-url "${ACE_STEP_TORCH_INDEX}"
        # Re-verify
        hip_version=$("$python_bin" -c "import torch; print(torch.version.hip or 'NONE')" 2>/dev/null)
        if [ "$hip_version" = "NONE" ]; then
            error "ROCm PyTorch reinstall failed. Check ROCm 7.2 installation."
        fi
    fi
    success "ROCm PyTorch verified: HIP ${hip_version}"
}

register_component "ACE_STEP" "install_ace_step"
