#!/bin/bash

# component_name: LM Studio
# component_description: LM Studio desktop app for the operator (use via ssh -X or RDP to browse & test models)

install_lmstudio() {
    log "Installing LM Studio for operator (${SUDO_USER})..."
    local user_home
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)

    if [ "$DRY_RUN" = false ]; then
        if [ "$REDOWNLOAD" = true ] || [ ! -f "${user_home}/.lmstudio/bin/lms" ]; then
            local attempt
            for attempt in 1 2 3; do
                log "LM Studio install attempt ${attempt}/3..."
                if sudo -u "$SUDO_USER" bash -c "source '${CACHE_HELPERS}' && cached_curl_pipe 'https://lmstudio.ai/install.sh' bash"; then
                    break
                fi
                if [ "$attempt" -lt 3 ]; then
                    warn "LM Studio install failed, retrying in 5s..."
                    sleep 5
                else
                    error "LM Studio install failed after 3 attempts"
                fi
            done
        else
            log "LM Studio already installed, skipping (use --redownload to force)"
        fi

        # Point LM Studio's model cache at the shared /models directory
        sudo -u "$SUDO_USER" mkdir -p "${user_home}/.cache/lm-studio"
        if [ -L "${user_home}/.cache/lm-studio/models" ]; then
            log "Model symlink already exists"
        else
            sudo -u "$SUDO_USER" ln -sfn "${SHARED_MODEL_DIR}" "${user_home}/.cache/lm-studio/models"
        fi
    else
        run echo "Install LM Studio for ${SUDO_USER} via lmstudio.ai/install.sh"
        run echo "Symlink ${user_home}/.cache/lm-studio/models → ${SHARED_MODEL_DIR}"
    fi

    log "LM Studio installed. Launch via:"
    log "  ssh -X ${SUDO_USER}@$(hostname) lmstudio"
    log "  (or use RDP desktop session)"
    log "Models are stored in ${SHARED_MODEL_DIR}"
}

register_component "LMSTUDIO" "install_lmstudio"
