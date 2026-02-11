#!/usr/bin/env bats
# Tests for 05-ssh.sh (SSH Outside Encrypted Home component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "05-ssh.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "ssh-outside-home: registers as SSH_OUTSIDE_HOME component" {
    [[ " ${COMPONENT_LIST[*]} " == *" SSH_OUTSIDE_HOME "* ]]
}

@test "ssh-outside-home: registers 3 functions" {
    local funcs="${COMPONENT_FUNCS[SSH_OUTSIDE_HOME]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 3 ]
}

# --- Dry-run execution ---

@test "ssh-outside-home: setup_ssh_outside_home runs in dry-run without errors" {
    DRY_RUN=true
    capture setup_ssh_outside_home
    [ "$_status" -eq 0 ]
}

@test "ssh-outside-home: install_ssh_user_hook runs in dry-run without errors" {
    DRY_RUN=true
    capture install_ssh_user_hook
    [ "$_status" -eq 0 ]
}

@test "ssh-outside-home: deploy_ecryptfs_helpers runs in dry-run without errors" {
    DRY_RUN=true
    capture deploy_ecryptfs_helpers
    [ "$_status" -eq 0 ]
}

# --- Content checks ---

@test "ssh-outside-home: component deploys setup-ssh-for-user script" {
    grep -q "setup-ssh-for-user" "$STRIX_DIR/components/05-ssh.sh"
}

@test "ssh-outside-home: component references /etc/ssh/users" {
    grep -q "/etc/ssh/users" "$STRIX_DIR/components/05-ssh.sh"
}

@test "ssh-outside-home: scripts/setup-ssh-for-user.sh exists" {
    [ -f "$STRIX_DIR/scripts/setup-ssh-for-user.sh" ]
}

@test "ssh-outside-home: setup_ssh_outside_home mentions AuthorizedKeysFile" {
    grep -q "AuthorizedKeysFile" "$STRIX_DIR/components/05-ssh.sh"
}

@test "ssh-outside-home: setup_ssh_outside_home validates with sshd -t" {
    grep -q "sshd -t" "$STRIX_DIR/components/05-ssh.sh"
}
