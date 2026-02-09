#!/usr/bin/env bats
# Tests for 50-ace-step.sh (ACE Step 1.5 component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "50-ace-step.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "ace_step: registers as ACE_STEP component" {
    [[ " ${COMPONENT_LIST[*]} " == *" ACE_STEP "* ]]
}

@test "ace_step: registers install_ace_step function" {
    [[ "${COMPONENT_FUNCS[ACE_STEP]}" == *"install_ace_step"* ]]
}

# --- Dry-run execution ---

@test "ace_step: install_ace_step runs in dry-run without errors" {
    DRY_RUN=true
    capture install_ace_step
    [ "$_status" -eq 0 ]
}

@test "ace_step: install_ace_step mentions ACE Step" {
    DRY_RUN=true
    capture install_ace_step
    [[ "$_output" == *"ACE Step"* ]]
}

@test "ace_step: would create checkpoints directory in dry-run" {
    DRY_RUN=true
    capture install_ace_step
    [[ "$_output" == *"mkdir"*"checkpoints"* ]]
}

# --- Script content checks ---

@test "ace_step: component_name header is ACE Step 1.5" {
    grep -q "^# component_name: ACE Step 1.5" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: references ACE_STEP_MODEL_URL variable" {
    grep -q 'ACE_STEP_MODEL_URL' "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: downloads to SHARED_MODEL_DIR/checkpoints" {
    grep -q 'SHARED_MODEL_DIR.*checkpoints' "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: installs transformers >= 4.48.0" {
    grep -q 'transformers>=4.48.0' "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: installs diffusers >= 0.32.0" {
    grep -q 'diffusers>=0.32.0' "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: checks for existing model file before downloading" {
    grep -q '! -f.*model_path' "$STRIX_DIR/components/50-ace-step.sh"
}
