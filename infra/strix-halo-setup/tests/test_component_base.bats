#!/usr/bin/env bats
# Tests for 10-base.sh (Base System component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "10-base.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "base: registers as BASE component" {
    [[ " ${COMPONENT_LIST[*]} " == *" BASE "* ]]
}

@test "base: registers 3 functions" {
    local funcs="${COMPONENT_FUNCS[BASE]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 3 ]
}

@test "base: registered functions are install_base, setup_users, deploy_base_config" {
    local funcs="${COMPONENT_FUNCS[BASE]}"
    [[ "$funcs" == *"install_base"* ]]
    [[ "$funcs" == *"setup_users"* ]]
    [[ "$funcs" == *"deploy_base_config"* ]]
}

# --- install_base (dry-run) ---

@test "base: install_base runs in dry-run without errors" {
    DRY_RUN=true
    capture install_base
    [ "$_status" -eq 0 ]
}

@test "base: install_base mentions kernel upgrade" {
    DRY_RUN=true
    capture install_base
    [[ "$_output" == *"kernel"* ]] || [[ "$_output" == *"System update"* ]]
}

@test "base: install_base mentions ROCm" {
    DRY_RUN=true
    capture install_base
    [[ "$_output" == *"ROCm"* ]]
}

@test "base: install_base mentions GPU memory" {
    DRY_RUN=true
    capture install_base
    [[ "$_output" == *"GPU Memory"* ]] || [[ "$_output" == *"GTT"* ]]
}

@test "base: install_base would call apt in dry-run" {
    DRY_RUN=true
    capture install_base
    [[ "$_output" == *"apt update"* ]]
    [[ "$_output" == *"apt upgrade"* ]]
}

@test "base: install_base would install mainline" {
    DRY_RUN=true
    capture install_base
    [[ "$_output" == *"mainline install"* ]]
}

# --- setup_users (dry-run) ---

@test "base: setup_users runs in dry-run without errors" {
    DRY_RUN=true
    capture setup_users
    [ "$_status" -eq 0 ]
}

@test "base: setup_users would create ai-users group" {
    DRY_RUN=true
    capture setup_users
    [[ "$_output" == *"groupadd"*"ai-users"* ]]
}

@test "base: setup_users would create shared model directory" {
    DRY_RUN=true
    capture setup_users
    [[ "$_output" == *"mkdir"*"models"* ]]
}

@test "base: setup_users would set setgid on model dir" {
    DRY_RUN=true
    capture setup_users
    [[ "$_output" == *"chmod"*"2775"* ]]
}

# --- deploy_base_config (dry-run) ---

@test "base: deploy_base_config runs in dry-run without errors" {
    DRY_RUN=true
    capture deploy_base_config
    [ "$_status" -eq 0 ]
}

@test "base: deploy_base_config would copy systemd units" {
    DRY_RUN=true
    capture deploy_base_config
    [[ "$_output" == *"cp"*".service"* ]]
}

@test "base: deploy_base_config would reload and enable xrdp" {
    DRY_RUN=true
    capture deploy_base_config
    [[ "$_output" == *"systemctl"*"daemon-reload"* ]]
    [[ "$_output" == *"systemctl"*"enable"*"xrdp"* ]]
}

# --- Script content checks ---

@test "base: component_name header is present" {
    grep -q "^# component_name:" "$STRIX_DIR/components/10-base.sh"
}

@test "base: component_description header is present" {
    grep -q "^# component_description:" "$STRIX_DIR/components/10-base.sh"
}

@test "base: uses KERNEL_VERSION variable (not hardcoded)" {
    grep -q 'KERNEL_VERSION' "$STRIX_DIR/components/10-base.sh"
}

@test "base: uses ROCM_VERSION variable (not hardcoded)" {
    grep -q 'ROCM_VERSION' "$STRIX_DIR/components/10-base.sh"
}

@test "base: xorg config creates 4K resolution" {
    grep -q "3840x2160" "$STRIX_DIR/components/10-base.sh"
}

@test "base: xorg config targets GFX1151" {
    grep -q "GFX1151" "$STRIX_DIR/components/10-base.sh"
}

@test "base: GTT size uses half of system RAM" {
    grep -q 'total_mem.*/ 2' "$STRIX_DIR/components/10-base.sh" || \
    grep -q 'gtt_size=$((total_mem / 2))' "$STRIX_DIR/components/10-base.sh"
}

# --- Script content: ROCm codename detection ---

@test "base: detects Ubuntu codename from os-release (not hardcoded jammy)" {
    ! grep -v '^\s*#' "$STRIX_DIR/components/10-base.sh" | grep -q '"jammy main"'
    grep -q 'UBUNTU_CODENAME' "$STRIX_DIR/components/10-base.sh"
}

@test "base: falls back to noble for unknown derivatives" {
    grep -q 'ubuntu_codename="noble"' "$STRIX_DIR/components/10-base.sh"
}

@test "base: pins ROCm repo above Ubuntu universe" {
    grep -q 'rocm-pin' "$STRIX_DIR/components/10-base.sh"
    grep -q 'Pin-Priority: 700' "$STRIX_DIR/components/10-base.sh"
}

@test "base: uses mainline install (not --install)" {
    grep -q 'mainline install' "$STRIX_DIR/components/10-base.sh"
    ! grep -q 'mainline --install' "$STRIX_DIR/components/10-base.sh"
}
