#!/bin/bash

# component_name: Security & Hosting
# component_description: Cisco AI Defense, Web Hosting Stack, and SSH Hardening

install_cisco_defense() {
    log "Installing Cisco AI Defense..."
    run cp ${INFRA_DIR}/defense/cisco-defense-daemon.py /home/defense/
    run chown defense:defense /home/defense/cisco-defense-daemon.py
    if [ "$DRY_RUN" = false ]; then
        sudo -u defense bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
        # Use uv to install scanners as tools
        sudo -u defense /home/defense/.local/bin/uv tool install a2a-scanner --python 3.11
        sudo -u defense /home/defense/.local/bin/uv tool install mcp-scanner --python 3.11
        sudo -u defense /home/defense/.local/bin/uv tool install skill-scanner --python 3.11
    fi
    run systemctl enable cisco-defense
}

install_hosting_stack() {
    log "Installing Web Hosting Stack (Supabase + WordPress)..."
    if ! command -v docker &> /dev/null; then
        run curl -fsSL https://get.docker.com | sh
    fi
    run usermod -aG docker hosting

    run sudo -u hosting mkdir -p /home/hosting/hosting-stack
    run cp ${INFRA_DIR}/docker/hosting-compose.yml /home/hosting/hosting-stack/docker-compose.yml
    run chown hosting:hosting /home/hosting/hosting-stack/docker-compose.yml
    run systemctl enable hosting

    if [ "$DRY_RUN" = false ]; then
        log "Generating hosting secrets..."
        local pg_pass=$(openssl rand -hex 16)
        echo "SUPABASE_DB_PASSWORD=${pg_pass}" | tee /home/hosting/hosting-stack/.env > /dev/null
        chown hosting:hosting /home/hosting/hosting-stack/.env
    fi
}

harden_system() {
    log "Hardening System SSH and Firewall..."
    if [ "$DRY_RUN" = false ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        systemctl restart ssh
    fi
    run ufw allow 22
    run ufw allow 3389
    run ufw --force enable
}

register_component "SECURITY" "install_cisco_defense" "install_hosting_stack" "harden_system"
