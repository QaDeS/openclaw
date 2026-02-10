#!/bin/bash

# component_name: LM Studio
# component_description: LM Studio headless daemon (port 1234)

install_lmstudio() {
    log "Installing LM Studio..."
    ensure_user lmstudio

    if [ "$DRY_RUN" = false ]; then
        if [ "$REDOWNLOAD" = true ] || [ ! -f /home/lmstudio/.lmstudio/bin/lms ]; then
            local attempt
            for attempt in 1 2 3; do
                log "LM Studio install attempt ${attempt}/3..."
                if sudo -u lmstudio bash -c 'curl -fsSL https://lmstudio.ai/install.sh | bash'; then
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
        sudo -u lmstudio mkdir -p /home/lmstudio/.cache/lm-studio
        sudo -u lmstudio ln -sf ${SHARED_MODEL_DIR} /home/lmstudio/.cache/lm-studio/models
    fi
    run cp ${INFRA_DIR}/systemd/llmster.service /etc/systemd/system/llmster.service
    run systemctl daemon-reload
    run systemctl enable llmster
    set_local_llm_url "http://localhost:1234/v1"
}

register_component "LMSTUDIO" "install_lmstudio"
