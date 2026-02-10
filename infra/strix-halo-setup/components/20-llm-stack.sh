#!/bin/bash

# component_name: OpenClaw Stack
# component_description: Git clone under /home/claw + Docker gateway (no encrypted-home dependency)

OPENCLAW_REPO="https://github.com/QaDeS/openclaw.git"
OPENCLAW_BRANCH="strix"
OPENCLAW_DIR="/home/claw/openclaw"

install_openclaw_stack() {
    log "Installing OpenClaw stack..."
    ensure_user claw

    # Docker
    if ! command -v docker &> /dev/null; then
        run curl -fsSL https://get.docker.com | sh
    fi
    run usermod -aG docker claw

    # Node.js 22+ (needed on host for pnpm install / building the clone)
    if ! command -v node &>/dev/null || [[ "$(node -v 2>/dev/null | tr -d v | cut -d. -f1)" -lt 22 ]]; then
        log "Installing Node.js 22..."
        if [ "$DRY_RUN" = false ]; then
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
            apt install -y nodejs
        else
            run echo "curl … nodesource setup_22.x | bash && apt install nodejs"
        fi
    else
        log "Node.js $(node -v) already installed."
    fi

    # pnpm
    if ! command -v pnpm &>/dev/null; then
        log "Installing pnpm..."
        run npm install -g pnpm
    fi

    # Clone or update the repo as claw user
    if [ -d "${OPENCLAW_DIR}/.git" ]; then
        log "Updating existing clone..."
        run sudo -u claw git -C "${OPENCLAW_DIR}" fetch origin
        run sudo -u claw git -C "${OPENCLAW_DIR}" checkout "${OPENCLAW_BRANCH}"
        run sudo -u claw git -C "${OPENCLAW_DIR}" pull --rebase origin "${OPENCLAW_BRANCH}"
    else
        log "Cloning openclaw repo → ${OPENCLAW_DIR}..."
        run sudo -u claw git clone --branch "${OPENCLAW_BRANCH}" "${OPENCLAW_REPO}" "${OPENCLAW_DIR}"
    fi

    # Install deps & build on host (volume-mounted into container at runtime)
    log "Installing dependencies and building..."
    if [ "$DRY_RUN" = false ]; then
        sudo -u claw bash -c "cd ${OPENCLAW_DIR} && pnpm install && pnpm build"
    else
        run echo "cd ${OPENCLAW_DIR} && pnpm install && pnpm build"
    fi

    # Config & compose setup
    run sudo -u claw mkdir -p /home/claw/.openclaw
    run cp ${INFRA_DIR}/docker/openclaw-compose.yml /home/claw/openclaw-compose.yml
    run cp ${INFRA_DIR}/docker/Dockerfile.openclaw  /home/claw/Dockerfile.openclaw
    run chown claw:claw /home/claw/openclaw-compose.yml /home/claw/Dockerfile.openclaw

    # Env file (consumed by compose --env-file)
    if [ "$DRY_RUN" = false ]; then
        {
            echo "LOCAL_LLM_URL=${LOCAL_LLM_URL}"
        } | tee /home/claw/.openclaw/env > /dev/null
        chown claw:claw /home/claw/.openclaw/env
    fi

    # Add claw's clone as a git remote in the operator's repo for cherry-picking
    if [ "$DRY_RUN" = false ] && [ -n "$SUDO_USER" ]; then
        local user_repo
        user_repo=$(sudo -u "$SUDO_USER" git -C "${PROJECT_ROOT}" rev-parse --git-dir 2>/dev/null) && {
            if ! sudo -u "$SUDO_USER" git -C "${PROJECT_ROOT}" remote get-url claw &>/dev/null; then
                sudo -u "$SUDO_USER" git -C "${PROJECT_ROOT}" remote add claw "${OPENCLAW_DIR}"
                log "Added git remote 'claw' → ${OPENCLAW_DIR} (use: git fetch claw)"
            else
                log "Git remote 'claw' already exists."
            fi
        }
    fi

    # Systemd service
    run cp ${INFRA_DIR}/systemd/openclaw.service /etc/systemd/system/openclaw.service
    run systemctl daemon-reload
    run systemctl enable openclaw
}

register_component "OPENCLAW" "install_openclaw_stack"
