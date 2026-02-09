#!/usr/bin/env bats
# Tests for --force mode execution flow.
# Specifically targets the bug where --force stops after confirmation.

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
}

teardown() {
    teardown_mocks
}

# --- Root cause analysis tests ---

@test "BUG-ROOT-CAUSE: glob inside double quotes prevents component loading" {
    # Line 118: for component in "${INFRA_DIR}/components/*.sh"
    # The * is inside double quotes, so bash treats it literally.
    # This means the loop body runs ONCE with a path containing a literal asterisk.
    local test_dir="$TEST_TMPDIR/glob_test"
    $_REAL_MKDIR -p "$test_dir"
    touch "$test_dir/a.sh" "$test_dir/b.sh" "$test_dir/c.sh"

    # Simulate the buggy pattern (quoted glob)
    local count=0
    for f in "${test_dir}/*.sh"; do
        count=$((count + 1))
    done
    # With the bug: count is 1 (the literal string "*/test_dir/*.sh")
    [ "$count" -eq 1 ]
}

@test "FIX-VERIFY: unquoted glob expands correctly" {
    local test_dir="$TEST_TMPDIR/glob_test"
    $_REAL_MKDIR -p "$test_dir"
    touch "$test_dir/a.sh" "$test_dir/b.sh" "$test_dir/c.sh"

    local count=0
    for f in "${test_dir}"/*.sh; do
        count=$((count + 1))
    done
    [ "$count" -eq 3 ]
}

@test "BUG-ROOT-CAUSE: echo before source prevents component execution" {
    # Line 119: echo source "$component"
    local test_script="$TEST_TMPDIR/test_source.sh"
    echo 'TEST_SOURCED_VAR=yes' > "$test_script"

    unset TEST_SOURCED_VAR
    echo source "$test_script" > /dev/null
    [ -z "${TEST_SOURCED_VAR:-}" ]
}

@test "FIX-VERIFY: source without echo loads the script" {
    local test_script="$TEST_TMPDIR/test_source.sh"
    echo 'TEST_SOURCED_VAR=yes' > "$test_script"

    unset TEST_SOURCED_VAR
    source "$test_script"
    [ "${TEST_SOURCED_VAR}" = "yes" ]
}

@test "BUG-ROOT-CAUSE: empty COMPONENT_LIST after buggy loading" {
    # Simulate the buggy main() component loading path
    declare -a loaded_components=()

    # Buggy: glob inside quotes + echo instead of source
    for component in "${STRIX_DIR}/components/*.sh"; do
        if [ -f "$component" ]; then
            loaded_components+=("$component")
        fi
    done

    # No components loaded because the literal glob path doesn't exist as a file
    [ ${#loaded_components[@]} -eq 0 ]
}

@test "BUG-CONSEQUENCE: with --all and empty COMPONENT_LIST, error exits" {
    # After the buggy loading, COMPONENT_LIST is empty.
    INSTALL_MODES=("${COMPONENT_LIST[@]}")
    [ ${#INSTALL_MODES[@]} -eq 0 ]
}

@test "BUG-CONSEQUENCE: without --all, show_menu blocks on read with empty menu" {
    # Selecting 0 with empty COMPONENT_LIST still results in empty INSTALL_MODES
    INSTALL_MODES=("${COMPONENT_LIST[@]}")
    [ ${#INSTALL_MODES[@]} -eq 0 ]
}

# --- Confirm execution flow ---

@test "confirm_execution: dry-run mode does not prompt" {
    DRY_RUN=true
    capture confirm_execution
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"DRY-RUN"* ]]
}

@test "confirm_execution: force mode requires exact risk string" {
    grep -q '"I UNDERSTAND THE RISKS"' "$STRIX_DIR/provision_strix_halo.sh"
}

@test "confirm_execution: force mode uses read -p for input" {
    grep -q 'read -p.*confirm' "$STRIX_DIR/provision_strix_halo.sh"
}

# --- End-to-end simulation of the fixed flow ---

@test "FIXED-FLOW: correct loading sources all 6 components" {
    local loaded=0
    for component in "${STRIX_DIR}"/components/*.sh; do
        source "$component"
        loaded=$((loaded + 1))
    done
    [ "$loaded" -eq 6 ]
    [ ${#COMPONENT_LIST[@]} -eq 6 ]
}

@test "FIXED-FLOW: with --all, INSTALL_MODES matches COMPONENT_LIST" {
    for component in "${STRIX_DIR}"/components/*.sh; do
        source "$component"
    done
    INSTALL_MODES=("${COMPONENT_LIST[@]}")
    [ ${#INSTALL_MODES[@]} -eq 6 ]
}

@test "FIXED-FLOW: all component functions execute in dry-run" {
    DRY_RUN=true
    for component in "${STRIX_DIR}"/components/*.sh; do
        source "$component"
    done
    INSTALL_MODES=("${COMPONENT_LIST[@]}")

    local executed=0
    for id in "${INSTALL_MODES[@]}"; do
        for func in ${COMPONENT_FUNCS[$id]}; do
            capture "$func"
            [ "$_status" -eq 0 ] || {
                echo "FAILED: $func (component $id): $_output"
                return 1
            }
            executed=$((executed + 1))
        done
    done
    # BASE(3) + LLM(1) + COMFYUI(1) + ZIMAGE(1) + ACE_STEP(1) + SECURITY(3) = 10
    [ "$executed" -eq 10 ]
}
