#!/bin/bash

# component_name: Security & Hosting
# component_description: Cisco AI Defense, Web Hosting Stack, and SSH Hardening

install_cisco_defense() {
    log "Installing Cisco AI Defense..."
    ensure_user defense
    run cp ${INFRA_DIR}/defense/cisco-defense-daemon.py /home/defense/
    run chown defense:defense /home/defense/cisco-defense-daemon.py
    if [ "$DRY_RUN" = false ]; then
        sudo -u defense bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
        # Install available scanners as uv tools (a2a-scanner/skill-scanner not yet on PyPI)
        sudo -u defense /home/defense/.local/bin/uv --no-config tool install mcp-scan --python 3.11
    fi
    run cp ${INFRA_DIR}/systemd/cisco-defense.service /etc/systemd/system/cisco-defense.service
    run systemctl daemon-reload
    run systemctl enable cisco-defense
}

install_hosting_stack() {
    log "Installing Web Hosting Stack (Supabase + WordPress)..."
    ensure_user hosting
    if ! command -v docker &> /dev/null; then
        run curl -fsSL https://get.docker.com | sh
    fi
    run usermod -aG docker hosting

    run sudo -u hosting mkdir -p /home/hosting/hosting-stack
    run cp ${INFRA_DIR}/docker/hosting-compose.yml /home/hosting/hosting-stack/docker-compose.yml
    run chown hosting:hosting /home/hosting/hosting-stack/docker-compose.yml
    run cp ${INFRA_DIR}/systemd/hosting.service /etc/systemd/system/hosting.service
    run systemctl daemon-reload
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

    # SSH from anywhere (key-only auth enforced above)
    run ufw allow 22

    # Allow all traffic from private/local networks
    run ufw allow from 10.0.0.0/8
    run ufw allow from 172.16.0.0/12
    run ufw allow from 192.168.0.0/16

    # Tailscale subnet (if using Tailscale for remote LAN-like access)
    run ufw allow from 100.64.0.0/10

    run ufw --force enable
}

register_component "SECURITY" "install_cisco_defense" "install_hosting_stack" "harden_system"
