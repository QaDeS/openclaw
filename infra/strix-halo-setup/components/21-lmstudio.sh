#!/bin/bash

# component_name: LM Studio
# component_description: LM Studio headless daemon (port 1234)

install_lmstudio() {
    log "Installing LM Studio..."
    ensure_user lmstudio

    if [ "$DRY_RUN" = false ]; then
        if [ "$REDOWNLOAD" = true ] || [ ! -f /home/lmstudio/.lmstudio/bin/lms ]; then
            sudo -u lmstudio bash -c 'curl -fsSL https://lmstudio.ai/install.sh | bash'
        else
            log "LM Studio already installed, skipping (use --redownload to force)"
        fi
        sudo -u lmstudio mkdir -p /home/lmstudio/.cache/lm-studio
        sudo -u lmstudio ln -sf ${SHARED_MODEL_DIR} /home/lmstudio/.cache/lm-studio/models
    fi
    run systemctl enable llmster
    set_local_llm_url "http://localhost:1234/v1"
}

register_component "LMSTUDIO" "install_lmstudio"
