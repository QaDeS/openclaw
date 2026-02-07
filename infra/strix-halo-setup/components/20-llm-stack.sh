#!/bin/bash

# component_name: LLM Stack
# component_description: LM Studio + OpenClaw (Local Checkout & Bind-mount)

install_llm_stack() {
    log "Installing LLM Stack..."
    
    # 1. LM Studio
    run sudo -u lmstudio mkdir -p /home/lmstudio/bin
    run sudo -u lmstudio mkdir -p /home/lmstudio/.cache/lm-studio
    if [ "$DRY_RUN" = false ]; then
        sudo -u lmstudio wget -O /home/lmstudio/bin/lm-studio.AppImage ${LM_STUDIO_URL}
        sudo -u lmstudio chmod +x /home/lmstudio/bin/lm-studio.AppImage
        sudo -u lmstudio ln -sf ${SHARED_MODEL_DIR} /home/lmstudio/.cache/lm-studio/models
    fi
    run systemctl enable llmster

    # 2. OpenClaw (Bind-mounted for Self-Development)
    if ! command -v docker &> /dev/null; then
        run curl -fsSL https://get.docker.com | sh
    fi
    run usermod -aG docker claw
    
    run sudo -u claw mkdir -p /home/claw/.openclaw
    run cp ${INFRA_DIR}/docker/openclaw-compose.yml /home/claw/openclaw-compose.yml
    run chown claw:claw /home/claw/openclaw-compose.yml

    local host_uid=$(id -u $SUDO_USER)
    local host_gid=$(id -g $SUDO_USER)
    
    if [ "$DRY_RUN" = false ]; then
        {
            echo "HOST_UID=${host_uid}"
            echo "HOST_GID=${host_gid}"
            echo "LOCAL_REPO_PATH=${PROJECT_ROOT}"
            echo "LMSTUDIO_BASE_URL=http://localhost:1234/v1"
        } | tee /home/claw/.openclaw/docker.env > /dev/null
        chown claw:claw /home/claw/.openclaw/docker.env
    fi
    run systemctl enable openclaw
}

register_component "LLM" "install_llm_stack"
