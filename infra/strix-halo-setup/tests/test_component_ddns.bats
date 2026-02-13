#!/usr/bin/env bats
# Tests for 62-ddns.sh (Dynamic DNS component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "62-ddns.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "ddns: registers as DDNS component" {
    [[ " ${COMPONENT_LIST[*]} " == *" DDNS "* ]]
}

@test "ddns: registers 1 function" {
    local funcs="${COMPONENT_FUNCS[DDNS]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 1 ]
}

# --- Dry-run execution ---

@test "ddns: install_ddns runs in dry-run without errors" {
    DRY_RUN=true
    capture install_ddns
    [ "$_status" -eq 0 ]
}

@test "ddns: install_ddns skips when DDNS_FQDN is empty" {
    DRY_RUN=true
    DDNS_FQDN=""
    capture install_ddns
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"skipping"* ]]
}

@test "ddns: install_ddns mentions quadlet when DDNS_FQDN is set" {
    DRY_RUN=true
    DDNS_FQDN="host.example.com"
    capture install_ddns
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"quadlet"* ]] || [[ "$_output" == *"Dynamic DNS"* ]]
}

# --- Content checks ---

@test "ddns: component references /home/ddns" {
    grep -q "/home/ddns" "$STRIX_DIR/components/62-ddns.sh"
}

@test "ddns: component uses namecheap-ddns image" {
    grep -q "namecheap-ddns" "$STRIX_DIR/components/62-ddns.sh"
}

@test "ddns: component creates secrets directory with mode 700" {
    grep -q "chmod 700" "$STRIX_DIR/components/62-ddns.sh"
}

@test "ddns: component uses Podman Quadlet" {
    grep -q "quadlet" "$STRIX_DIR/components/62-ddns.sh"
}

@test "ddns: component uses ensure_linger" {
    grep -q "ensure_linger" "$STRIX_DIR/components/62-ddns.sh"
}

@test "ddns: component uses track_podman" {
    grep -q "track_podman" "$STRIX_DIR/components/62-ddns.sh"
}
