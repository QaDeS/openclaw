#!/bin/bash

# component_name: Z-Image Turbo
# component_description: Optimized Image Generation for Strix Halo

install_zimage() {
    log "Installing Z-Image Turbo Base..."
    # Z-Image optimization for Strix Halo (FP8 preferred)
    if [ "$DRY_RUN" = false ]; then
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install "accelerate>=1.2.0"
        # Ensure VAE decoding doesn't hang (Triton/FlashAttention)
        sudo -u comfyui /home/comfyui/.local/bin/uv pip install "triton>=3.0.0"
    fi
}

register_component "ZIMAGE" "install_zimage"
