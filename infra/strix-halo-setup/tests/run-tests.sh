#!/bin/bash
# run-tests.sh — Build and run the strix provisioning test suite in Docker.
#
# Usage:
#   From anywhere (automatically finds strix-halo-setup):
#     ./infra/strix-halo-setup/tests/run-tests.sh            # build + run in Docker
#     ./infra/strix-halo-setup/tests/run-tests.sh --local    # run bats directly (inside container or CI)
#     ./infra/strix-halo-setup/tests/run-tests.sh --no-tmpfs # disable tmpfs overlay (low RAM)
#
#   Filter tests:
#     ./infra/strix-halo-setup/tests/run-tests.sh test_force_mode.bats
#     ./infra/strix-halo-setup/tests/run-tests.sh --local test_shellcheck.bats

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "${1:-}" == "--local" ]]; then
    shift
    cd "$SCRIPT_DIR"
    if [[ $# -gt 0 ]]; then
        exec bats --tap "$@"
    else
        exec bats --tap ./*.bats
    fi
fi

# --- Docker mode ---

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
