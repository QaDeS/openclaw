#!/bin/bash

# component_name: ACE Step 1.5
# component_description: Music Generation (ROCm / GFX1151 Memory Tweaks)

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

register_component "ACE_STEP" "install_ace_step"
