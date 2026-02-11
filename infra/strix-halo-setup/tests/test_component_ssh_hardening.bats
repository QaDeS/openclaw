#!/usr/bin/env bats
# Tests for 07-ssh-hardening.sh (SSH Hardening & Firewall component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "07-ssh-hardening.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "ssh-hardening: registers as SSH_HARDENING component" {
    [[ " ${COMPONENT_LIST[*]} " == *" SSH_HARDENING "* ]]
}

@test "ssh-hardening: registers 4 functions" {
    local funcs="${COMPONENT_FUNCS[SSH_HARDENING]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 4 ]
}

# --- Dry-run execution ---

@test "ssh-hardening: harden_ssh runs in dry-run without errors" {
    DRY_RUN=true
    capture harden_ssh
    [ "$_status" -eq 0 ]
}

@test "ssh-hardening: setup_fail2ban runs in dry-run without errors" {
    DRY_RUN=true
    capture setup_fail2ban
    [ "$_status" -eq 0 ]
}

@test "ssh-hardening: setup_firewall runs in dry-run without errors" {
    DRY_RUN=true
    capture setup_firewall
    [ "$_status" -eq 0 ]
}

@test "ssh-hardening: setup_upnp_ssh runs in dry-run without errors" {
    DRY_RUN=true
    capture setup_upnp_ssh
    [ "$_status" -eq 0 ]
}

# --- Firewall checks ---

@test "ssh-hardening: setup_firewall uses ufw limit for SSH" {
    grep -q "ufw limit" "$STRIX_DIR/components/07-ssh-hardening.sh"
}

@test "ssh-hardening: setup_firewall does not use ufw allow for SSH port" {
    ! grep -q "ufw allow 22" "$STRIX_DIR/components/07-ssh-hardening.sh"
}

# --- UPnP skip behavior ---

@test "ssh-hardening: setup_upnp_ssh skips when SSH_UPNP_PORT is empty" {
    DRY_RUN=true
    SSH_UPNP_PORT=""
    capture setup_upnp_ssh
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"skipping"* ]]
}

# --- Content checks ---

@test "ssh-hardening: component references fail2ban" {
    grep -q "fail2ban" "$STRIX_DIR/components/07-ssh-hardening.sh"
}

@test "ssh-hardening: component deploys upnp-ssh service files" {
    grep -q "upnp-ssh.service" "$STRIX_DIR/components/07-ssh-hardening.sh"
    grep -q "upnp-ssh.timer" "$STRIX_DIR/components/07-ssh-hardening.sh"
}

@test "ssh-hardening: scripts/upnp-ssh-refresh.sh exists" {
    [ -f "$STRIX_DIR/scripts/upnp-ssh-refresh.sh" ]
}

@test "ssh-hardening: harden_ssh sets PermitRootLogin" {
    grep -q "PermitRootLogin" "$STRIX_DIR/components/07-ssh-hardening.sh"
}

@test "ssh-hardening: harden_ssh validates with sshd -t" {
    grep -q "sshd -t" "$STRIX_DIR/components/07-ssh-hardening.sh"
}
