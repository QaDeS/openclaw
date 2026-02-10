#!/usr/bin/env bats
# Tests for 50-ace-step.sh (ACE Step 1.5 Standalone component).

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

@test "ace_step: would clone the standalone repo in dry-run" {
    DRY_RUN=true
    capture install_ace_step
    [[ "$_output" == *"git clone"* ]]
}

@test "ace_step: would enable ace-step service in dry-run" {
    DRY_RUN=true
    capture install_ace_step
    [[ "$_output" == *"systemctl"*"enable"*"ace-step"* ]]
}

# --- Script content: standalone installation ---

@test "ace_step: component_name header is ACE Step 1.5 Standalone" {
    grep -q "^# component_name: ACE Step 1.5 Standalone" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: clones from ACE-Step GitHub" {
    grep -q "github.com/ACE-Step/ACE-Step-1.5" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: creates an isolated venv (not uv sync)" {
    grep -q "python3.11 -m venv" "$STRIX_DIR/components/50-ace-step.sh"
    # Must NOT use uv sync which pulls CUDA torch
    ! grep -q "uv sync" "$STRIX_DIR/components/50-ace-step.sh"
}

# --- Script content: ROCm pinning ---

@test "ace_step: installs ROCm PyTorch from GFX1151 nightly index" {
    grep -q "rocm.nightlies.amd.com/v2/gfx1151" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: installs ROCm torch BEFORE other deps" {
    # Torch install line must appear before requirements install
    local torch_line
    torch_line=$(grep -n "torch torchvision torchaudio" "$STRIX_DIR/components/50-ace-step.sh" | head -1 | cut -d: -f1)
    local req_line
    req_line=$(grep -n "requirements-rocm-linux.txt" "$STRIX_DIR/components/50-ace-step.sh" | head -1 | cut -d: -f1)
    [ "$torch_line" -lt "$req_line" ]
}

@test "ace_step: uses --no-deps when installing the project" {
    grep -q "\-\-no-deps" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: uses requirements-rocm-linux.txt when available" {
    grep -q "requirements-rocm-linux.txt" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: has fallback manual dep install if ROCm requirements missing" {
    grep -q "No requirements-rocm-linux.txt found" "$STRIX_DIR/components/50-ace-step.sh"
}

# --- Script content: ROCm verification ---

@test "ace_step: verifies ROCm torch after installation" {
    grep -q "torch.version.hip" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: auto-reinstalls ROCm torch if CUDA was pulled in" {
    grep -q "Forcing ROCm reinstall" "$STRIX_DIR/components/50-ace-step.sh"
}

@test "ace_step: defines _verify_rocm_torch function" {
    grep -q "_verify_rocm_torch" "$STRIX_DIR/components/50-ace-step.sh"
}

# --- Script content: nano-vllm ---

@test "ace_step: installs nano-vllm bundled package" {
    grep -q "nano-vllm" "$STRIX_DIR/components/50-ace-step.sh"
}

# --- Script content: shared models ---

@test "ace_step: symlinks SHARED_MODEL_DIR to checkpoints" {
    grep -q "ln.*SHARED_MODEL_DIR.*checkpoints" "$STRIX_DIR/components/50-ace-step.sh"
}

# --- Script content: no CUDA/NVIDIA references ---

@test "ace_step: does not reference CUDA index" {
    ! grep -qi "cu12[0-9]" "$STRIX_DIR/components/50-ace-step.sh"
    ! grep -qi "pytorch.org/whl/cu" "$STRIX_DIR/components/50-ace-step.sh"
}
