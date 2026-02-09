#!/usr/bin/env bats
# Tests for 30-comfyui.sh (ComfyUI component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "30-comfyui.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "comfyui: registers as COMFYUI component" {
    [[ " ${COMPONENT_LIST[*]} " == *" COMFYUI "* ]]
}

@test "comfyui: registers install_comfyui function" {
    [[ "${COMPONENT_FUNCS[COMFYUI]}" == *"install_comfyui"* ]]
}

# --- Dry-run execution ---

@test "comfyui: install_comfyui runs in dry-run without errors" {
    DRY_RUN=true
    capture install_comfyui
    [ "$_status" -eq 0 ]
}

@test "comfyui: install_comfyui mentions ComfyUI" {
    DRY_RUN=true
    capture install_comfyui
    [[ "$_output" == *"ComfyUI"* ]]
}

@test "comfyui: would enable comfyui service in dry-run" {
    DRY_RUN=true
    capture install_comfyui
    [[ "$_output" == *"systemctl"*"enable"*"comfyui"* ]]
}

# --- Script content checks ---

@test "comfyui: component_name header is ComfyUI" {
    grep -q "^# component_name: ComfyUI" "$STRIX_DIR/components/30-comfyui.sh"
}

@test "comfyui: clones ComfyUI from GitHub" {
    grep -q "github.com/comfyanonymous/ComfyUI" "$STRIX_DIR/components/30-comfyui.sh"
}

@test "comfyui: installs uv package manager" {
    grep -q "astral.sh/uv" "$STRIX_DIR/components/30-comfyui.sh"
}

@test "comfyui: uses ROCm-specific PyTorch index for GFX1151" {
    grep -q "gfx1151" "$STRIX_DIR/components/30-comfyui.sh"
}

@test "comfyui: installs from ComfyUI requirements.txt" {
    grep -q "requirements.txt" "$STRIX_DIR/components/30-comfyui.sh"
}

@test "comfyui: git clone uses || true for idempotency" {
    grep -q 'git clone.*|| true' "$STRIX_DIR/components/30-comfyui.sh"
}
