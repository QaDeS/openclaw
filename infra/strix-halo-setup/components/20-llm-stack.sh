#!/bin/bash

# component_name: OpenClaw Stack
# component_description: OpenClaw Docker daemon (bind-mount local checkout)

install_openclaw_stack() {
    log "Installing OpenClaw stack..."
    ensure_user claw

    # Docker
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
            echo "LOCAL_LLM_URL=${LOCAL_LLM_URL}"
        } | tee /home/claw/.openclaw/docker.env > /dev/null
        chown claw:claw /home/claw/.openclaw/docker.env
    fi
    run cp ${INFRA_DIR}/systemd/openclaw.service /etc/systemd/system/openclaw.service
    run systemctl daemon-reload
    run systemctl enable openclaw
}

register_component "OPENCLAW" "install_openclaw_stack"
