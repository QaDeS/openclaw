#!/usr/bin/env bats
# Tests for the main provision_strix_halo.sh orchestrator script.

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
}

teardown() {
    teardown_mocks
}

# --- Global configuration ---

@test "global config: KERNEL_VERSION is set" {
    [ "$KERNEL_VERSION" = "6.18.4" ]
}

@test "global config: ROCM_VERSION is set" {
    [ "$ROCM_VERSION" = "7.2" ]
}

@test "global config: HSA_OVERRIDE is set" {
    [ "$HSA_OVERRIDE" = "11.5.1" ]
}

@test "global config: AI_USERS has 5 entries" {
    [ ${#AI_USERS[@]} -eq 5 ]
}

@test "global config: AI_USERS contains expected users" {
    local found_lmstudio=false found_comfyui=false found_claw=false found_hosting=false found_defense=false
    for u in "${AI_USERS[@]}"; do
        case "$u" in
            lmstudio) found_lmstudio=true ;;
            comfyui)  found_comfyui=true ;;
            claw)     found_claw=true ;;
            hosting)  found_hosting=true ;;
            defense)  found_defense=true ;;
        esac
    done
    $found_lmstudio && $found_comfyui && $found_claw && $found_hosting && $found_defense
}

# --- DRY_RUN mode ---

@test "dry-run mode: run() does not execute commands" {
    DRY_RUN=true
    capture run echo "should_not_execute"
    [[ "$_output" == *"DRY-RUN"* ]]
}

@test "force mode: run() executes commands" {
    DRY_RUN=false
    capture run echo "force_test_sentinel"
    [[ "$_output" == *"force_test_sentinel"* ]]
}

# --- Logging functions ---

@test "log() outputs INFO prefix" {
    capture log "test message"
    [[ "$_output" == *"[INFO]"* ]]
    [[ "$_output" == *"test message"* ]]
}

@test "warn() outputs WARN prefix" {
    capture warn "test warning"
    [[ "$_output" == *"[WARN]"* ]]
    [[ "$_output" == *"test warning"* ]]
}

@test "success() outputs SUCCESS prefix" {
    capture success "it worked"
    [[ "$_output" == *"[SUCCESS]"* ]]
    [[ "$_output" == *"it worked"* ]]
}

@test "error() outputs ERROR prefix and fails" {
    capture error "bad thing"
    [ "$_status" -ne 0 ]
    [[ "$_output" == *"[ERROR]"* ]]
    [[ "$_output" == *"bad thing"* ]]
}

# --- Component registration ---

@test "register_component stores component ID in list" {
    register_component "TEST_COMP" "my_func"
    [[ " ${COMPONENT_LIST[*]} " == *" TEST_COMP "* ]]
}

@test "register_component stores function mapping" {
    register_component "TEST_COMP" "my_func_a" "my_func_b"
    [[ "${COMPONENT_FUNCS[TEST_COMP]}" == *"my_func_a"* ]]
    [[ "${COMPONENT_FUNCS[TEST_COMP]}" == *"my_func_b"* ]]
}

@test "register_component stores name" {
    register_component "TEST_COMP" "my_func"
    [[ -n "${COMPONENT_NAMES[TEST_COMP]}" ]]
}

@test "multiple register_component calls accumulate" {
    register_component "COMP_A" "func_a"
    register_component "COMP_B" "func_b"
    register_component "COMP_C" "func_c"
    [ ${#COMPONENT_LIST[@]} -ge 3 ]
}

# --- Component sourcing bug detection ---

@test "BUG: provision_strix_halo.sh line 119 has echo before source" {
    grep -n 'echo source' "$STRIX_DIR/provision_strix_halo.sh" | grep -q '119'
}

@test "BUG: provision_strix_halo.sh line 122 has debug echo leftover" {
    grep -n 'echo.*COMPONENT_LIST' "$STRIX_DIR/provision_strix_halo.sh" | grep -q '122'
}

@test "component glob pattern in main uses quotes but no array expansion" {
    # Line 118: for component in "${INFRA_DIR}/components/*.sh"
    # The quotes prevent glob expansion — this is the root cause of --force hang
    grep -n '"${INFRA_DIR}/components/\*\.sh"' "$STRIX_DIR/provision_strix_halo.sh" | grep -q '118'
}

# --- SSH safety ---

@test "check_ssh_safety: script contains lockout protection" {
    grep -q "Lockout Protection" "$STRIX_DIR/provision_strix_halo.sh"
}

@test "check_ssh_safety: checks authorized_keys existence" {
    grep -q "authorized_keys" "$STRIX_DIR/provision_strix_halo.sh"
}

# --- Root check ---

@test "main function requires root" {
    grep -q 'EUID.*-ne 0' "$STRIX_DIR/provision_strix_halo.sh"
}

# --- Confirm execution ---

@test "confirm_execution requires risk acknowledgement string" {
    grep -q "I UNDERSTAND THE RISKS" "$STRIX_DIR/provision_strix_halo.sh"
}

@test "confirm_execution: dry-run mode does not prompt" {
    DRY_RUN=true
    capture confirm_execution
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"DRY-RUN"* ]]
}

# --- Component loading order ---

@test "components are numbered for ordered loading" {
    local files=("$STRIX_DIR"/components/*.sh)
    local prev=0
    for f in "${files[@]}"; do
        local basename
        basename=$(basename "$f")
        local num=${basename%%-*}
        [ "$num" -ge "$prev" ] || {
            echo "Components not in order: $basename comes after $prev"
            return 1
        }
        prev=$num
    done
}

@test "exactly 6 component scripts exist" {
    local count
    count=$(ls "$STRIX_DIR"/components/*.sh 2>/dev/null | wc -l)
    [ "$count" -eq 6 ]
}
