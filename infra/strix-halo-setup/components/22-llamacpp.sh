#!/bin/bash

# component_name: llama.cpp (Vulkan)
# component_description: llama.cpp server with Vulkan backend (port 11234)

install_llamacpp() {
    log "Installing llama.cpp with Vulkan support..."
    ensure_user llamacpp

    # Build dependencies
    run cached_apt_install cmake build-essential libvulkan-dev vulkan-tools

    # Clone or update
    local repo_dir="/home/llamacpp/llama.cpp"
    if [ "$DRY_RUN" = false ]; then
        if [ -d "$repo_dir" ] && [ "$REDOWNLOAD" = false ]; then
            log "llama.cpp already cloned, pulling latest..."
            sudo -u llamacpp git -C "$repo_dir" checkout -- .
            sudo -u llamacpp git -C "$repo_dir" pull --rebase
        else
            sudo -u llamacpp rm -rf "$repo_dir"
            sudo -u llamacpp bash -c "source '${CACHE_HELPERS}' && cached_git_clone 'https://github.com/ggml-org/llama.cpp.git' '$repo_dir'"
        fi
    fi

    # Build with Vulkan
    if [ "$DRY_RUN" = false ]; then
        sudo -u llamacpp cmake -B "$repo_dir/build" -S "$repo_dir" \
            -DGGML_VULKAN=ON \
            -DCMAKE_BUILD_TYPE=Release
        sudo -u llamacpp cmake --build "$repo_dir/build" --config Release -j "$(nproc)"
    fi

    # Symlink shared models (for direct access)
    run sudo -u llamacpp ln -sfn ${SHARED_MODEL_DIR} /home/llamacpp/models
    track_symlink /home/llamacpp/models "${SHARED_MODEL_DIR}"

    # Install systemd service (uses /llama_models from sync-llama-models component)
    run cp ${INFRA_DIR}/systemd/llamacpp.service /etc/systemd/system/llamacpp.service
    track_file_create /etc/systemd/system/llamacpp.service
    run systemctl daemon-reload
    run systemctl enable llamacpp
    track_service llamacpp
    set_local_llm_url "http://localhost:11234/v1"
}

register_component "LLAMACPP" "install_llamacpp"
