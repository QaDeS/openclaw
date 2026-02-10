#!/bin/bash
# test_helper.bash — Common setup/teardown for strix provisioning tests.
#
# Sourced by every .bats file. Provides:
#   - STRIX_DIR, TESTS_DIR paths
#   - Mock command framework (prepend MOCK_BIN to PATH)
#   - MOCK_LOG for inspecting what commands were called
#   - capture() function for running component functions without clashing with bats' run
#   - Helper functions for assertions

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRIX_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Save real command paths before any mocks are installed.
# These must be resolved BEFORE MOCK_BIN is prepended to PATH.
_REAL_CHMOD="$(command -v chmod)"
_REAL_MKDIR="$(command -v mkdir)"
_REAL_CP="$(command -v cp)"
_REAL_LN="$(command -v ln)"

# Scratch space for each test (cleaned in teardown)
TEST_TMPDIR=""
MOCK_BIN=""
MOCK_LOG=""

# Set up mock environment before each test
setup_mocks() {
    TEST_TMPDIR="$(mktemp -d)"
    MOCK_BIN="$TEST_TMPDIR/mock-bin"
    MOCK_LOG="$TEST_TMPDIR/mock.log"
    $_REAL_MKDIR -p "$MOCK_BIN"
    touch "$MOCK_LOG"

    # Install all mock commands (uses _REAL_CHMOD internally)
    _install_mock apt
    _install_mock apt-get
    _install_mock add-apt-repository
    _install_mock mainline
    _install_mock wget
    _install_mock curl
    _install_mock systemctl
    _install_mock systemd-analyze
    _install_mock useradd
    _install_mock usermod
    _install_mock groupadd
    _install_mock chown
    _install_mock chmod
    _install_mock cp
    _install_mock ufw
    _install_mock update-grub
    _install_mock docker
    _install_mock openssl
    _install_mock sed
    _install_mock tee
    _install_mock pkill
    _install_mock xrdp
    _install_mock git
    _install_mock mkdir

    # Make getent return a fake home for testuser
    cat > "$MOCK_BIN/getent" <<'MOCK'
#!/bin/bash
echo "mock_getent $*" >> "$MOCK_LOG"
if [[ "$1" == "passwd" ]]; then
    echo "${2:-testuser}:x:1000:1000::/home/testuser:/bin/bash"
fi
MOCK
    $_REAL_CHMOD +x "$MOCK_BIN/getent"

    # Make id return fake values
    cat > "$MOCK_BIN/id" <<'MOCK'
#!/bin/bash
echo "mock_id $*" >> "$MOCK_LOG"
case "$1" in
    -u) echo "1000" ;;
    -g) echo "1000" ;;
    *)
        # "id <user>" — succeed so user-exists checks pass
        exit 0
        ;;
esac
MOCK
    $_REAL_CHMOD +x "$MOCK_BIN/id"

    # Make free return fake memory
    cat > "$MOCK_BIN/free" <<'MOCK'
#!/bin/bash
echo "mock_free $*" >> "$MOCK_LOG"
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:            128           8          96           1          24         119"
MOCK
    $_REAL_CHMOD +x "$MOCK_BIN/free"

    # Make sudo pass through to the command (dropping -u <user>)
    cat > "$MOCK_BIN/sudo" <<'MOCK'
#!/bin/bash
echo "mock_sudo $*" >> "$MOCK_LOG"
# Strip -u <user> and run the rest
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) shift 2 ;;
        *)  break ;;
    esac
done
"$@"
MOCK
    $_REAL_CHMOD +x "$MOCK_BIN/sudo"

    # Put mocks first in PATH
    export PATH="$MOCK_BIN:$PATH"

    # Set environment variables the scripts expect
    # Note: EUID is readonly in bash — we cannot override it.
    export SUDO_USER="testuser"
    export PROJECT_ROOT="$TEST_TMPDIR/project"
    $_REAL_MKDIR -p "$PROJECT_ROOT/infra/strix-halo-setup"

    # Symlink strix source tree into our fake project root
    $_REAL_LN -sf "$STRIX_DIR/components" "$PROJECT_ROOT/infra/strix-halo-setup/components"
    $_REAL_LN -sf "$STRIX_DIR/systemd"    "$PROJECT_ROOT/infra/strix-halo-setup/systemd"
    $_REAL_LN -sf "$STRIX_DIR/docker"     "$PROJECT_ROOT/infra/strix-halo-setup/docker"
    $_REAL_LN -sf "$STRIX_DIR/defense"    "$PROJECT_ROOT/infra/strix-halo-setup/defense"
}

teardown_mocks() {
    [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

# Install a no-op mock that logs calls
_install_mock() {
    local cmd="$1"
    cat > "$MOCK_BIN/$cmd" <<MOCK
#!/bin/bash
echo "mock_${cmd} \$*" >> "$MOCK_LOG"
exit 0
MOCK
    $_REAL_CHMOD +x "$MOCK_BIN/$cmd"
}

# Source the provisioning globals (without running main)
# Sets up all variables, colors, log functions, run(), register_component()
#
# IMPORTANT: The provisioning scripts define a function called `run()`. This
# clashes with bats' built-in `run` keyword. We keep the provisioning `run()`
# so that component scripts work, but tests must use `capture` (below) instead
# of bats' `run` when calling component functions.
load_provision_globals() {
    export DRY_RUN=true
    export INFRA_DIR="$PROJECT_ROOT/infra/strix-halo-setup"
    export KERNEL_VERSION="6.18.7"
    export ROCM_VERSION="7.2"
    export AI_USERS=("lmstudio" "comfyui" "claw" "hosting" "defense")
    export SHARED_MODEL_DIR="$TEST_TMPDIR/models"
    export LM_STUDIO_URL="https://releases.lmstudio.ai/linux/x86_64/latest/LM-Studio.AppImage"
    export ACE_STEP_MODEL_URL="https://huggingface.co/Linaqruf/ace-step-1.5-turbo-aio/resolve/main/ace_step_1.5_turbo_aio.safetensors"
    export HSA_OVERRIDE="11.5.1"

    $_REAL_MKDIR -p "$SHARED_MODEL_DIR"

    # Colors (stripped for test output clarity)
    BLUE='' YELLOW='' GREEN='' RED='' NC=''
    export BLUE YELLOW GREEN RED NC

    declare -gA COMPONENT_FUNCS
    declare -gA COMPONENT_NAMES
    declare -ga COMPONENT_LIST=()
    declare -ga INSTALL_MODES=()

    # Logging functions
    log()     { echo "[INFO] $1"; }
    warn()    { echo "[WARN] $1"; }
    success() { echo "[SUCCESS] $1"; }
    error()   { echo "[ERROR] $1"; return 1; }

    # The provisioning dry-run wrapper. Named `run` to match what components call.
    # Tests must NOT use bats' `run` keyword after loading globals — use capture() instead.
    run() {
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Will execute: $*"
        else
            "$@"
        fi
    }

    register_component() {
        local id=$1; shift
        local name=""
        name="Component $id"
        COMPONENT_LIST+=("$id")
        COMPONENT_NAMES["$id"]="$name"
        COMPONENT_FUNCS["$id"]="$*"
    }

    confirm_execution() {
        if [ "$DRY_RUN" = true ]; then
            warn "Running in DRY-RUN mode. No changes will be applied."
        else
            warn "CRITICAL: Modifying system files, kernel, and disabling SSH passwords."
            read -rp "Type 'I UNDERSTAND THE RISKS' to proceed: " confirm
            [[ "$confirm" != "I UNDERSTAND THE RISKS" ]] && error "Confirmation failed."
        fi
    }

    export -f log warn success error run register_component confirm_execution
}

# capture — Run a function and capture its output + exit status.
# Use this instead of bats' `run` for component functions (since `run` is overridden).
#
# Usage:
#   capture install_base
#   [ "$_status" -eq 0 ]
#   [[ "$_output" == *"ROCm"* ]]
capture() {
    _output="$("$@" 2>&1)" && _status=$? || _status=$?
}

# Load a component script after globals are set
load_component() {
    local component_file="$STRIX_DIR/components/$1"
    [[ -f "$component_file" ]] || { echo "Component not found: $1"; return 1; }
    source "$component_file"
}

# Assert that a mock command was called (substring match in MOCK_LOG)
assert_mock_called() {
    local pattern="$1"
    grep -q "$pattern" "$MOCK_LOG" || {
        echo "Expected mock call matching: $pattern"
        echo "Actual mock log:"
        cat "$MOCK_LOG"
        return 1
    }
}

# Assert that a mock command was NOT called
assert_mock_not_called() {
    local pattern="$1"
    if grep -q "$pattern" "$MOCK_LOG"; then
        echo "Did not expect mock call matching: $pattern"
        echo "But found in mock log:"
        grep "$pattern" "$MOCK_LOG"
        return 1
    fi
}

# Count how many times a pattern appears in mock log
mock_call_count() {
    local pattern="$1"
    grep -c "$pattern" "$MOCK_LOG" 2>/dev/null || echo 0
}
