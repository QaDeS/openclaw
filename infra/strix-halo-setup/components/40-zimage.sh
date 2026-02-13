#!/bin/bash

# component_name: Z-Image Turbo
# component_description: Optimized Image Generation for Strix Halo

install_zimage() {
    log "Installing Z-Image Turbo Base..."
    local UV="/home/comfyui/.local/bin/uv"
    local VENV_PYTHON="/home/comfyui/ComfyUI/.venv/bin/python"
    undo_note "pip packages (accelerate, triton) not auto-removed on undo"
    # Z-Image optimization for Strix Halo (FP8 preferred)
    # Installs into ComfyUI's venv (requires ComfyUI component installed first)
    if [ "$DRY_RUN" = false ]; then
        sudo -u comfyui "$UV" --no-config pip install --python "$VENV_PYTHON" "accelerate>=1.2.0"
        # Ensure VAE decoding doesn't hang (Triton/FlashAttention)
        sudo -u comfyui "$UV" --no-config pip install --python "$VENV_PYTHON" "triton>=3.0.0"
    fi
}

register_component "ZIMAGE" "install_zimage"
