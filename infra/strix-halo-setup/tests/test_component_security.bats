#!/usr/bin/env bats
# Tests for 60-security.sh (Security & Hosting component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "60-security.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "security: registers as SECURITY component" {
    [[ " ${COMPONENT_LIST[*]} " == *" SECURITY "* ]]
}

@test "security: registers 3 functions" {
    local funcs="${COMPONENT_FUNCS[SECURITY]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 3 ]
}

@test "security: registered functions are install_cisco_defense, install_hosting_stack, harden_system" {
    local funcs="${COMPONENT_FUNCS[SECURITY]}"
    [[ "$funcs" == *"install_cisco_defense"* ]]
    [[ "$funcs" == *"install_hosting_stack"* ]]
    [[ "$funcs" == *"harden_system"* ]]
}

# --- install_cisco_defense (dry-run) ---

@test "security: install_cisco_defense runs in dry-run without errors" {
    DRY_RUN=true
    capture install_cisco_defense
    [ "$_status" -eq 0 ]
}

@test "security: install_cisco_defense mentions Cisco AI Defense" {
    DRY_RUN=true
    capture install_cisco_defense
    [[ "$_output" == *"Cisco AI Defense"* ]]
}

@test "security: install_cisco_defense would enable cisco-defense service" {
    DRY_RUN=true
    capture install_cisco_defense
    [[ "$_output" == *"systemctl"*"enable"*"cisco-defense"* ]]
}

@test "security: install_cisco_defense would copy defense daemon" {
    DRY_RUN=true
    capture install_cisco_defense
    [[ "$_output" == *"cp"*"cisco-defense-daemon"* ]]
}

# --- install_hosting_stack (dry-run) ---

@test "security: install_hosting_stack runs in dry-run without errors" {
    DRY_RUN=true
    capture install_hosting_stack
    [ "$_status" -eq 0 ]
}

@test "security: install_hosting_stack mentions hosting" {
    DRY_RUN=true
    capture install_hosting_stack
    [[ "$_output" == *"Hosting Stack"* ]] || [[ "$_output" == *"hosting"* ]]
}

@test "security: install_hosting_stack would enable hosting service" {
    DRY_RUN=true
    capture install_hosting_stack
    [[ "$_output" == *"systemctl"*"enable"*"hosting"* ]]
}

@test "security: install_hosting_stack would add hosting user to docker group" {
    DRY_RUN=true
    capture install_hosting_stack
    [[ "$_output" == *"usermod"*"docker"*"hosting"* ]]
}

@test "security: install_hosting_stack checks for docker" {
    grep -q 'command -v docker' "$STRIX_DIR/components/60-security.sh"
}

# --- harden_system (dry-run) ---

@test "security: harden_system runs in dry-run without errors" {
    DRY_RUN=true
    capture harden_system
    [ "$_status" -eq 0 ]
}

@test "security: harden_system would enable UFW in dry-run" {
    DRY_RUN=true
    capture harden_system
    [[ "$_output" == *"ufw"*"enable"* ]]
}

@test "security: harden_system would allow SSH port 22" {
    DRY_RUN=true
    capture harden_system
    [[ "$_output" == *"ufw"*"22"* ]]
}

@test "security: harden_system would allow RDP port 3389" {
    DRY_RUN=true
    capture harden_system
    [[ "$_output" == *"ufw"*"3389"* ]]
}

# --- Script content checks ---

@test "security: component_name header is Security & Hosting" {
    grep -q "^# component_name: Security & Hosting" "$STRIX_DIR/components/60-security.sh"
}

@test "security: SSH hardening disables password auth" {
    grep -q "PasswordAuthentication no" "$STRIX_DIR/components/60-security.sh"
}

@test "security: SSH hardening enables pubkey auth" {
    grep -q "PubkeyAuthentication yes" "$STRIX_DIR/components/60-security.sh"
}

@test "security: SSH hardening backs up sshd_config" {
    grep -q "sshd_config.bak" "$STRIX_DIR/components/60-security.sh"
}

@test "security: hosting uses openssl for password generation" {
    grep -q "openssl rand" "$STRIX_DIR/components/60-security.sh"
}

@test "security: installs security scanners via uv tool" {
    grep -q "uv tool install" "$STRIX_DIR/components/60-security.sh"
}

@test "security: installs a2a-scanner, mcp-scanner, skill-scanner" {
    grep -q "a2a-scanner" "$STRIX_DIR/components/60-security.sh"
    grep -q "mcp-scanner" "$STRIX_DIR/components/60-security.sh"
    grep -q "skill-scanner" "$STRIX_DIR/components/60-security.sh"
}
