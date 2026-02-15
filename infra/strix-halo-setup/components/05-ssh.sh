#!/bin/bash

# component_name: SSH Outside Encrypted Home
# component_description: Move SSH keys outside ecryptfs to survive reboots

setup_ssh_outside_home() {
    log "Setting up SSH outside encrypted home..."
    run mkdir -p /etc/ssh/users

    # Back up sshd_config (timestamped, idempotent within run)
    backup_file /etc/ssh/sshd_config

    # Configure sshd to look in /etc/ssh/users/%u/ (outside encrypted home)
    set_sshd_directive AuthorizedKeysFile "/etc/ssh/users/%u/authorized_keys"

    # Require both pubkey AND password — ecryptfs unwraps the home dir via
    # pam_ecryptfs when the password is supplied, so no profile.d workaround needed.
    set_sshd_directive AuthenticationMethods "publickey,password"
    set_sshd_directive PasswordAuthentication "yes"

    # Enable SSH for the provisioning user + each user in SSH_USERS
    enable_ssh_for_user "${SUDO_USER:-}"
    for user in $SSH_USERS; do
        [[ "$user" == "${SUDO_USER:-}" ]] && continue
        enable_ssh_for_user "$user"
    done

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

install_ssh_user_hook() {
    log "Installing SSH user creation hook..."

    # Deploy the hook script
    run cp "${INFRA_DIR}/scripts/setup-ssh-for-user.sh" /usr/local/sbin/setup-ssh-for-user
    run chmod 755 /usr/local/sbin/setup-ssh-for-user
    track_file_create /usr/local/sbin/setup-ssh-for-user

    # Wire into adduser.local (append only if not present)
    if [ "$DRY_RUN" = false ]; then
        local hook_file="/usr/local/sbin/adduser.local"
        if [ ! -f "$hook_file" ]; then
            echo '#!/bin/bash' | tee "$hook_file" >/dev/null
            chmod 755 "$hook_file"
            track_file_create "$hook_file"
        fi
        if ! grep -q "setup-ssh-for-user" "$hook_file" 2>/dev/null; then
            track_append "$hook_file" "setup-ssh-for-user"
            # $1 is intentionally literal (expanded by adduser at runtime)
            # shellcheck disable=SC2016
            echo '/usr/local/sbin/setup-ssh-for-user "$1"' | tee -a "$hook_file" >/dev/null
        fi
    else
        log "${YELLOW}[DRY-RUN] Will wire setup-ssh-for-user into adduser.local${NC}"
    fi
}

register_component "SSH_OUTSIDE_HOME" "setup_ssh_outside_home" "install_ssh_user_hook"
