#!/usr/bin/env bats
# Tests for 20-llm-stack.sh (OpenClaw Stack component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "20-llm-stack.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "openclaw: registers as OPENCLAW component" {
    [[ " ${COMPONENT_LIST[*]} " == *" OPENCLAW "* ]]
}

@test "openclaw: registers install_openclaw_stack function" {
    [[ "${COMPONENT_FUNCS[OPENCLAW]}" == *"install_openclaw_stack"* ]]
}

# --- Dry-run execution ---

@test "openclaw: install_openclaw_stack runs in dry-run without errors" {
    DRY_RUN=true
    capture install_openclaw_stack
    [ "$_status" -eq 0 ]
}

@test "openclaw: install_openclaw_stack mentions OpenClaw" {
    DRY_RUN=true
    capture install_openclaw_stack
    [[ "$_output" == *"OpenClaw"* ]]
}

# --- Script content checks ---

@test "openclaw: component_name header is OpenClaw Stack" {
    grep -q "^# component_name: OpenClaw Stack" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: uses PROJECT_ROOT for bind-mount config" {
    grep -q 'PROJECT_ROOT' "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: writes env with LOCAL_LLM_URL" {
    grep -q "LOCAL_LLM_URL" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: uses podman build for container image" {
    grep -q "podman build" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: deploys quadlet file" {
    grep -q "quadlet" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: uses ensure_linger" {
    grep -q "ensure_linger" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: uses cached_curl_pipe for nodesource" {
    grep -q "cached_curl_pipe" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "openclaw: uses cached_git_clone for repo" {
    grep -q "cached_git_clone" "$STRIX_DIR/components/20-llm-stack.sh"
}
