#!/usr/bin/env bats
# End-to-end tests with download cache enabled.
# Verifies that components correctly use cache helpers when CACHE_DIR is set.

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals

    # Set up a minimal cache
    CACHE_DIR="$TEST_TMPDIR/cache"
    export CACHE_DIR
    $_REAL_MKDIR -p "$CACHE_DIR"/{scripts,files,repos,pip}

    # Populate stub scripts
    echo '#!/bin/bash' > "$CACHE_DIR/scripts/get.docker.com"
    echo 'exit 0' >> "$CACHE_DIR/scripts/get.docker.com"
    echo '#!/bin/bash' > "$CACHE_DIR/scripts/deb.nodesource.com_setup_22.x"
    echo 'exit 0' >> "$CACHE_DIR/scripts/deb.nodesource.com_setup_22.x"
    echo '#!/bin/bash' > "$CACHE_DIR/scripts/astral.sh_uv_install.sh"
    echo 'exit 0' >> "$CACHE_DIR/scripts/astral.sh_uv_install.sh"
    echo '#!/bin/bash' > "$CACHE_DIR/scripts/lmstudio.ai_install.sh"
    echo 'exit 0' >> "$CACHE_DIR/scripts/lmstudio.ai_install.sh"

    # Populate stub file
    echo "FAKE_GPG_KEY" > "$CACHE_DIR/files/repo.radeon.com_rocm_rocm.gpg.key"
}

teardown() {
    teardown_mocks
}

# --- Cache integration ---

@test "e2e-cache: CACHE_DIR is exported and non-empty" {
    [ -n "$CACHE_DIR" ]
    [ -d "$CACHE_DIR" ]
}

@test "e2e-cache: cached_fetch uses cache for GPG key" {
    local dest="$TEST_TMPDIR/gpg.key"
    capture cached_fetch "https://repo.radeon.com/rocm/rocm.gpg.key" "$dest"
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"Cache hit"* ]]
    assert_mock_not_called "mock_wget"
}

@test "e2e-cache: cached_curl_pipe uses cache for install scripts" {
    capture cached_curl_pipe "https://astral.sh/uv/install.sh" cat
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"Cache hit"* ]]
    assert_mock_not_called "mock_curl"
}

@test "e2e-cache: cached_git_clone falls back to network on cache miss" {
    # No bare repos in cache — should call git
    capture cached_git_clone "https://github.com/foo/bar.git" "$TEST_TMPDIR/bar"
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"Cache miss"* ]]
    assert_mock_called "mock_git"
}

@test "e2e-cache: cached_pip_index_args returns empty for missing cache" {
    local result
    result=$(cached_pip_index_args torch-rocm-gfx1151)
    [ -z "$result" ]
}

@test "e2e-cache: cached_pip_index_args returns flags for populated cache" {
    $_REAL_MKDIR -p "$CACHE_DIR/pip/torch-rocm-gfx1151"
    touch "$CACHE_DIR/pip/torch-rocm-gfx1151/torch-2.0.whl"

    local result
    result=$(cached_pip_index_args torch-rocm-gfx1151)
    [[ "$result" == *"--find-links"* ]]
    [[ "$result" == *"--no-index"* ]]
}

# --- Component dry-run with cache ---

@test "e2e-cache: base component runs with cache in dry-run" {
    load_component "10-base.sh"
    DRY_RUN=true
    capture install_base
    [ "$_status" -eq 0 ]
}

@test "e2e-cache: security component runs with cache in dry-run" {
    load_component "60-security.sh"
    DRY_RUN=true
    capture install_cisco_defense
    [ "$_status" -eq 0 ]
}

@test "e2e-cache: ddns component runs with cache in dry-run" {
    load_component "62-ddns.sh"
    DRY_RUN=true
    DDNS_FQDN="host.example.com"
    capture install_ddns
    [ "$_status" -eq 0 ]
}
