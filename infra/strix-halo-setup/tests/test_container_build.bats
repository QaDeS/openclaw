#!/usr/bin/env bats
# test_container_build.bats — Smoke-test that the container engine can actually
# build images and run containers. Catches cgroup, polkit, and rootless runtime
# errors (like "Interactive authentication required") before the real test suite
# wastes time on a broken build.
#
# Run standalone:
#   bats tests/test_container_build.bats
#
# These tests require a working container engine (docker or podman) on the host.
# They are skipped inside the test container (--local mode).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIX_DIR="$(cd "$TESTS_DIR/.." && pwd)"

setup() {
    # Skip if running inside the test container (no nested container engine)
    if [[ -f /.dockerenv ]] || grep -qsw container /proc/1/environ 2>/dev/null; then
        skip "inside container — no nested engine available"
    fi

    # Detect container engine
    if command -v docker &>/dev/null; then
        ENGINE="docker"
    elif command -v podman &>/dev/null; then
        ENGINE="podman"
    else
        skip "no container engine (docker/podman) found"
    fi

    TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    # Clean up temp dir and any test images
    [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
    if [[ -n "${ENGINE:-}" ]]; then
        $ENGINE rmi -f strix-build-smoke 2>/dev/null || true
    fi
}

# --- Smoke tests ---

@test "container-engine: engine is responsive" {
    result="$($ENGINE info 2>&1)" && status=$? || status=$?
    if [[ $status -ne 0 ]]; then
        echo "Container engine '$ENGINE' is not responding."
        echo "Output: $result"
        if [[ "$result" == *"permission denied"* ]]; then
            echo ""
            echo "FIX: Add your user to the docker group, or use rootless podman:"
            echo "  sudo usermod -aG docker \$USER && newgrp docker"
        fi
        return 1
    fi
}

@test "container-engine: can build image with RUN step" {
    # This catches the exact cgroup/polkit error:
    #   "unable to start container process: unable to apply cgroup configuration"
    #   "Interactive authentication required"
    cat > "$TEST_TMPDIR/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN echo "build-step-ok" > /smoke-test.txt
EOF

    result="$($ENGINE build -t strix-build-smoke -f "$TEST_TMPDIR/Dockerfile" "$TEST_TMPDIR" 2>&1)" && status=$? || status=$?

    if [[ $status -ne 0 ]]; then
        echo "Container build failed (exit $status)."
        echo ""

        if [[ "$result" == *"Interactive authentication required"* ]]; then
            echo "ROOT CAUSE: systemd/polkit denies cgroup access for rootless containers."
            echo ""
            echo "FIXES (pick one):"
            echo "  1. Enable lingering for your user (recommended):"
            echo "       sudo loginctl enable-linger \$USER"
            echo ""
            echo "  2. Start a user systemd instance:"
            echo "       systemctl --user start dbus"
            echo ""
            echo "  3. Set cgroup manager to cgroupfs (bypasses systemd):"
            echo "       mkdir -p ~/.config/containers"
            echo "       echo '[engine]' >> ~/.config/containers/containers.conf"
            echo "       echo 'cgroup_manager = \"cgroupfs\"' >> ~/.config/containers/containers.conf"
            echo ""
        elif [[ "$result" == *"unable to apply cgroup"* ]] || [[ "$result" == *"cgroup"* ]]; then
            echo "ROOT CAUSE: cgroup configuration failed."
            echo ""
            echo "FIXES:"
            echo "  1. Enable lingering: sudo loginctl enable-linger \$USER"
            echo "  2. Ensure cgroup v2 is enabled: stat /sys/fs/cgroup/cgroup.controllers"
            echo "  3. Check user slice: systemctl --user status"
            echo ""
        elif [[ "$result" == *"permission denied"* ]] || [[ "$result" == *"EPERM"* ]]; then
            echo "ROOT CAUSE: permission denied during build."
            echo ""
            echo "FIXES:"
            echo "  1. For Docker: sudo usermod -aG docker \$USER && newgrp docker"
            echo "  2. For Podman: ensure /etc/subuid and /etc/subgid have entries for \$USER"
            echo ""
        fi

        echo "Full output:"
        echo "$result" | tail -30
        return 1
    fi
}

@test "container-engine: can run container with command" {
    # Depends on the build test passing — build a minimal image first
    cat > "$TEST_TMPDIR/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN echo "run-test-ok" > /smoke-test.txt
CMD ["cat", "/smoke-test.txt"]
EOF

    $ENGINE build -t strix-build-smoke -f "$TEST_TMPDIR/Dockerfile" "$TEST_TMPDIR" >/dev/null 2>&1 \
        || skip "build failed — see 'can build image with RUN step' test"

    result="$($ENGINE run --rm strix-build-smoke 2>&1)" && status=$? || status=$?

    if [[ $status -ne 0 ]]; then
        echo "Container run failed (exit $status)."
        echo "Output: $result"
        return 1
    fi

    [[ "$result" == *"run-test-ok"* ]]
}

@test "container-engine: full test-suite image builds" {
    # Build the actual test Dockerfile used by run-tests.sh.
    # This catches missing COPY targets, syntax errors, and runtime issues
    # in the real image — not just a minimal smoke test.
    result="$($ENGINE build -t strix-build-smoke -f "$TESTS_DIR/Dockerfile" "$STRIX_DIR" 2>&1)" && status=$? || status=$?

    if [[ $status -ne 0 ]]; then
        echo "Full test-suite image build failed (exit $status)."
        echo ""

        if [[ "$result" == *"Interactive authentication required"* ]]; then
            echo "ROOT CAUSE: systemd/polkit cgroup issue — see 'can build image' test for fixes."
        elif [[ "$result" == *"COPY failed"* ]] || [[ "$result" == *"not found"* ]]; then
            echo "ROOT CAUSE: missing file or directory referenced in Dockerfile."
        fi

        echo ""
        echo "Last 40 lines of build output:"
        echo "$result" | tail -40
        return 1
    fi
}
