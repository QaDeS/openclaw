#!/usr/bin/env bats
# Tests for 40-zimage.sh (Z-Image Turbo component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "40-zimage.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "zimage: registers as ZIMAGE component" {
    [[ " ${COMPONENT_LIST[*]} " == *" ZIMAGE "* ]]
}

@test "zimage: registers install_zimage function" {
    [[ "${COMPONENT_FUNCS[ZIMAGE]}" == *"install_zimage"* ]]
}

# --- Dry-run execution ---

@test "zimage: install_zimage runs in dry-run without errors" {
    DRY_RUN=true
    capture install_zimage
    [ "$_status" -eq 0 ]
}

@test "zimage: install_zimage mentions Z-Image" {
    DRY_RUN=true
    capture install_zimage
    [[ "$_output" == *"Z-Image"* ]]
}

# --- Script content checks ---

@test "zimage: component_name header is Z-Image Turbo" {
    grep -q "^# component_name: Z-Image Turbo" "$STRIX_DIR/components/40-zimage.sh"
}

@test "zimage: installs accelerate >= 1.2.0" {
    grep -q 'accelerate>=1.2.0' "$STRIX_DIR/components/40-zimage.sh"
}

@test "zimage: installs triton >= 3.0.0" {
    grep -q 'triton>=3.0.0' "$STRIX_DIR/components/40-zimage.sh"
}

@test "zimage: dry-run skips pip installs (no sudo calls)" {
    DRY_RUN=true
    capture install_zimage
    # In dry-run, the if-block skips entirely — output should be minimal
    # (just the log message, no pip commands)
    [[ "$_output" != *"uv pip install"* ]]
}

@test "zimage: uses comfyui user's uv for installation" {
    grep -q '/home/comfyui/.local/bin/uv' "$STRIX_DIR/components/40-zimage.sh"
}
