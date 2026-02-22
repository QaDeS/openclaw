#!/bin/bash

# component_name: SSH Hardening & Firewall
# component_description: SSH hardening, fail2ban, UFW firewall, optional UPnP

harden_ssh() {
    log "Hardening SSH configuration..."

    # Back up sshd_config (timestamped, idempotent within run)
    backup_file /etc/ssh/sshd_config

    set_sshd_directive PermitRootLogin "prohibit-password"
    set_sshd_directive PubkeyAuthentication "yes"
    set_sshd_directive MaxAuthTries "5"

    # Audit key quality (warn on DSA, don't delete)
    if [ "$DRY_RUN" = false ]; then
        for user in $SSH_USERS ${SUDO_USER:-}; do
            local keys_file="/etc/ssh/users/${user}/authorized_keys"
            [ -f "$keys_file" ] || continue
            if grep -q "ssh-dss" "$keys_file" 2>/dev/null; then
                warn "DSA key found for ${user} — consider upgrading to ed25519"
            fi
        done
    fi

    # Keep password auth enabled — required for ecryptfs home directory unwrapping.
    # AuthenticationMethods publickey,password ensures both factors are needed.
    set_sshd_directive PasswordAuthentication "yes"
    set_sshd_directive AuthenticationMethods "publickey,password"

    # Validate config before reload; revert on failure
    if [ "$DRY_RUN" = false ]; then
        if sshd -t 2>/dev/null; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        else
            warn "sshd -t failed; reverting sshd_config from backup"
            local flat_backup="${BACKUP_DIR}/etc-ssh-sshd_config"
            [ -f "$flat_backup" ] && cp "$flat_backup" /etc/ssh/sshd_config
        fi
    fi
}

setup_fail2ban() {
    log "Installing and configuring fail2ban..."
    run cached_apt_install fail2ban

    if [ "$DRY_RUN" = false ]; then
        mkdir -p /etc/fail2ban/jail.d
        cat <<'F2B' | tee /etc/fail2ban/jail.d/ssh-strix.conf >/dev/null
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
F2B
    else
        log "${YELLOW}[DRY-RUN] Will deploy /etc/fail2ban/jail.d/ssh-strix.conf${NC}"
    fi

    track_file_create /etc/fail2ban/jail.d/ssh-strix.conf
    run systemctl enable fail2ban
    run systemctl restart fail2ban
    track_service fail2ban
}

setup_firewall() {
    log "Configuring UFW firewall..."

    # Rate-limited SSH (brute-force protection)
    run ufw limit 22/tcp
    track_ufw_rule limit 22/tcp

    # Allow all traffic from private/local networks
    run ufw allow from 10.0.0.0/8
    track_ufw_rule allow from 10.0.0.0/8
    run ufw allow from 172.16.0.0/12
    track_ufw_rule allow from 172.16.0.0/12
    run ufw allow from 192.168.0.0/16
    track_ufw_rule allow from 192.168.0.0/16

    # Tailscale subnet
    run ufw allow from 100.64.0.0/10
    track_ufw_rule allow from 100.64.0.0/10

    run ufw --force enable
}

setup_upnp_ssh() {
    # Early return if SSH_UPNP_PORT is empty
    if [ -z "$SSH_UPNP_PORT" ]; then
        log "SSH UPnP port not configured; skipping UPnP setup."
        return 0
    fi

    log "Setting up UPnP SSH port forwarding (external port ${SSH_UPNP_PORT})..."
    run cached_apt_install miniupnpc

    # Deploy refresh script
    run cp "${INFRA_DIR}/scripts/upnp-ssh-refresh.sh" /usr/local/sbin/upnp-ssh-refresh
    run chmod 755 /usr/local/sbin/upnp-ssh-refresh
    track_file_create /usr/local/sbin/upnp-ssh-refresh

    # Deploy systemd units
    run cp "${INFRA_DIR}/systemd/upnp-ssh.service" /etc/systemd/system/upnp-ssh.service
    run cp "${INFRA_DIR}/systemd/upnp-ssh.timer" /etc/systemd/system/upnp-ssh.timer
    track_file_create /etc/systemd/system/upnp-ssh.service
    track_file_create /etc/systemd/system/upnp-ssh.timer

    if [ "$DRY_RUN" = false ]; then
        # Write the port config for the script
        echo "SSH_UPNP_PORT=${SSH_UPNP_PORT}" | tee /etc/default/upnp-ssh >/dev/null
        track_file_create /etc/default/upnp-ssh
    fi

    run systemctl daemon-reload
    run systemctl enable upnp-ssh.timer
    run systemctl start upnp-ssh.timer
    track_service upnp-ssh.timer

    # Deploy NetworkManager dispatcher hook
    if [ "$DRY_RUN" = false ]; then
        mkdir -p /etc/NetworkManager/dispatcher.d
        cat <<'NM' | tee /etc/NetworkManager/dispatcher.d/99-upnp-ssh >/dev/null
#!/bin/bash
# Refresh UPnP SSH mapping on network changes
[ "$2" = "up" ] && /usr/local/sbin/upnp-ssh-refresh &
NM
        chmod 755 /etc/NetworkManager/dispatcher.d/99-upnp-ssh
        track_file_create /etc/NetworkManager/dispatcher.d/99-upnp-ssh

        # Deploy networkd dispatcher hook
        mkdir -p /etc/networkd-dispatcher/routable.d
        cat <<'ND' | tee /etc/networkd-dispatcher/routable.d/99-upnp-ssh >/dev/null
#!/bin/bash
# Refresh UPnP SSH mapping on network changes
/usr/local/sbin/upnp-ssh-refresh &
ND
        chmod 755 /etc/networkd-dispatcher/routable.d/99-upnp-ssh
        track_file_create /etc/networkd-dispatcher/routable.d/99-upnp-ssh
    else
        log "${YELLOW}[DRY-RUN] Will deploy network dispatcher hooks for UPnP SSH${NC}"
    fi

    # Initial mapping attempt (warn on failure)
    if [ "$DRY_RUN" = false ]; then
        /usr/local/sbin/upnp-ssh-refresh || warn "Initial UPnP mapping failed (timer will retry)"
    fi
}

register_component "SSH_HARDENING" "harden_ssh" "setup_fail2ban" "setup_firewall" "setup_upnp_ssh"
