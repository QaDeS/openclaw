#!/bin/bash
# run-tests.sh — Build and run the strix provisioning test suite in Docker or VM.
#
# Usage:
#   From anywhere (automatically finds strix-halo-setup):
#     ./infra/strix-halo-setup/tests/run-tests.sh            # build + run in Docker
#     ./infra/strix-halo-setup/tests/run-tests.sh --local    # run bats directly (inside container or CI)
#     ./infra/strix-halo-setup/tests/run-tests.sh --no-tmpfs # disable tmpfs overlay (low RAM)
#     ./infra/strix-halo-setup/tests/run-tests.sh --vm       # run provisioning in VM with GPU passthrough
#
#   Filter tests:
#     ./infra/strix-halo-setup/tests/run-tests.sh test_force_mode.bats
#     ./infra/strix-halo-setup/tests/run-tests.sh --local test_shellcheck.bats
#
#   VM mode (--vm):
#     ./run-tests.sh --vm                    # Full test cycle (setup + provision + health checks)
#     ./run-tests.sh --vm setup              # Only VM setup (download image, generate keys)
#     ./run-tests.sh --vm provision          # Run provisioning in existing VM
#     ./run-tests.sh --vm health             # Run health checks in existing VM
#     ./run-tests.sh --vm cleanup            # Stop VM and reattach GPU

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_HELPER="${SCRIPT_DIR}/vm/prepare-vm.sh"

# =============================================================================
# Mode: Local (bats directly)
# =============================================================================

if [[ "${1:-}" == "--local" ]]; then
    shift
    cd "$SCRIPT_DIR"
    if [[ $# -gt 0 ]]; then
        exec bats --tap "$@"
    else
        exec bats --tap ./*.bats
    fi
fi

# =============================================================================
# Mode: VM (KVM with GPU passthrough)
# =============================================================================

if [[ "${1:-}" == "--vm" ]]; then
    shift
    
    if [[ ! -x "$VM_HELPER" ]]; then
        echo "ERROR: VM helper not found: $VM_HELPER"
        exit 1
    fi
    
    # Show warning banner
    echo ""
    echo "================================================================================"
    echo "WARNING: GPU PASSTHROUGH TEST"
    echo ""
    echo "This test will detach your GPU (c5:00.0) from the host and pass it to a VM."
    echo "Your display will go BLACK during the test."
    echo ""
    echo "After the test completes:"
    echo "  - The VM will shut down"
    echo "  - Your GPU will be re-attached to the host"
    echo "  - The display manager will restart automatically"
    echo ""
    echo "To abort NOW: Press Ctrl+C within 10 seconds, or SSH in from another machine and run:"
    echo "  virsh destroy strix-test-vm"
    echo ""
    echo "================================================================================"
    echo ""
    
    # Countdown
    for i in $(seq 10 -1 1); do
        echo -ne "\rStarting in $i seconds... "
        sleep 1
    done
    echo ""
    echo ""
    
    # Run VM helper with all remaining args
    exec "$VM_HELPER" "$@"
fi

# =============================================================================
# Mode: Docker (default)
# =============================================================================

USE_TMPFS=true
if [[ "${1:-}" == "--no-tmpfs" ]]; then
    USE_TMPFS=false
    shift
fi

# Check for docker or podman
CONTAINER_ENGINE=""
if command -v docker &>/dev/null; then
    CONTAINER_ENGINE="docker"
elif command -v podman &>/dev/null; then
    CONTAINER_ENGINE="podman"
else
    echo "ERROR: Neither docker nor podman found."
    echo "Install one of them, or run tests inside an existing container with: ./run-tests.sh --local"
    exit 1
fi

echo "Using container engine: $CONTAINER_ENGINE"
echo "Build context: $STRIX_DIR"

# --- tmpfs memory check ---
# Container overlay in RAM avoids SSD wear and speeds up test runs.
# Requires ~256MB free. Auto-disables if insufficient.
TMPFS_ARGS=()
if $USE_TMPFS; then
    avail_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$avail_mb" -ge 512 ]; then
        TMPFS_ARGS=("--tmpfs" "/tmp:rw,exec,size=256m")
        echo "tmpfs overlay: enabled (${avail_mb}MB available, using 256MB)"
    else
        echo "tmpfs overlay: disabled (only ${avail_mb}MB available, need 512MB)"
    fi
else
    echo "tmpfs overlay: disabled (--no-tmpfs)"
fi

echo ""
echo "NOTE: This builds a disposable container image (~150MB). No packages are"
echo "installed on your host system. The container is removed after tests finish."
echo ""

IMAGE_NAME="strix-provision-tests"

echo "=== Building test container ==="
"$CONTAINER_ENGINE" build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$STRIX_DIR"

echo ""
echo "=== Running test suite in container ==="

# Pass remaining args (e.g. specific test files) to the container entrypoint
if [[ $# -gt 0 ]]; then
    "$CONTAINER_ENGINE" run --rm "${TMPFS_ARGS[@]}" "$IMAGE_NAME" --local "$@"
else
    "$CONTAINER_ENGINE" run --rm "${TMPFS_ARGS[@]}" "$IMAGE_NAME" --local
fi

echo ""
echo "=== Container removed. No residue on host. ==="
