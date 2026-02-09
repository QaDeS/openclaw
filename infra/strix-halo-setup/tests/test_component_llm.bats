#!/usr/bin/env bats
# Tests for 20-llm-stack.sh (LLM Stack component).

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

@test "llm: registers as LLM component" {
    [[ " ${COMPONENT_LIST[*]} " == *" LLM "* ]]
}

@test "llm: registers install_llm_stack function" {
    [[ "${COMPONENT_FUNCS[LLM]}" == *"install_llm_stack"* ]]
}

# --- Dry-run execution ---

@test "llm: install_llm_stack runs in dry-run without errors" {
    DRY_RUN=true
    capture install_llm_stack
    [ "$_status" -eq 0 ]
}

@test "llm: install_llm_stack mentions LLM Stack" {
    DRY_RUN=true
    capture install_llm_stack
    [[ "$_output" == *"LLM Stack"* ]]
}

@test "llm: would enable llmster service in dry-run" {
    DRY_RUN=true
    capture install_llm_stack
    [[ "$_output" == *"systemctl"*"enable"*"llmster"* ]]
}

@test "llm: would enable openclaw service in dry-run" {
    DRY_RUN=true
    capture install_llm_stack
    [[ "$_output" == *"systemctl"*"enable"*"openclaw"* ]]
}

@test "llm: would add claw user to docker group" {
    DRY_RUN=true
    capture install_llm_stack
    [[ "$_output" == *"usermod"*"docker"*"claw"* ]]
}

# --- Script content checks ---

@test "llm: component_name header is LLM Stack" {
    grep -q "^# component_name: LLM Stack" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "llm: references LM_STUDIO_URL variable" {
    grep -q 'LM_STUDIO_URL' "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "llm: references SHARED_MODEL_DIR for symlink" {
    grep -q 'SHARED_MODEL_DIR' "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "llm: uses PROJECT_ROOT for bind-mount config" {
    grep -q 'PROJECT_ROOT' "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "llm: writes docker.env with LMSTUDIO_BASE_URL" {
    grep -q "LMSTUDIO_BASE_URL" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "llm: copies openclaw-compose.yml" {
    grep -q "openclaw-compose.yml" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "llm: checks for docker before installing" {
    grep -q 'command -v docker' "$STRIX_DIR/components/20-llm-stack.sh"
}
