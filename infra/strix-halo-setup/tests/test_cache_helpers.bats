#!/usr/bin/env bats
# Tests for lib/cache-helpers.sh (download cache functions).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
}

teardown() {
    teardown_mocks
}

# --- _cache_key ---

@test "cache: _cache_key strips https protocol" {
    local key
    key=$(_cache_key "https://example.com/foo/bar")
    [ "$key" = "example.com_foo_bar" ]
}

@test "cache: _cache_key strips http protocol" {
    local key
    key=$(_cache_key "http://example.com/path")
    [ "$key" = "example.com_path" ]
}

@test "cache: _cache_key replaces slashes with underscores" {
    local key
    key=$(_cache_key "https://get.docker.com")
    [ "$key" = "get.docker.com" ]
}

# --- cached_curl_pipe ---

@test "cache: cached_curl_pipe passes through when CACHE_DIR is empty" {
    CACHE_DIR=""
    export CACHE_DIR
    # curl is mocked, cat will just consume stdin
    capture cached_curl_pipe "https://example.com/install.sh" cat
    [ "$_status" -eq 0 ]
    assert_mock_called "mock_curl"
}

@test "cache: cached_curl_pipe uses cache hit when file exists" {
    CACHE_DIR="$TEST_TMPDIR/cache"
    export CACHE_DIR
    $_REAL_MKDIR -p "$CACHE_DIR/scripts"
    echo "cached_content" > "$CACHE_DIR/scripts/example.com_install.sh"

    capture cached_curl_pipe "https://example.com/install.sh" cat
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"cached_content"* ]]
    assert_mock_not_called "mock_curl"
}

@test "cache: cached_curl_pipe downloads on cache miss" {
    CACHE_DIR="$TEST_TMPDIR/cache"
    export CACHE_DIR
    $_REAL_MKDIR -p "$CACHE_DIR/scripts"

    capture cached_curl_pipe "https://example.com/install.sh" cat
    [ "$_status" -eq 0 ]
    assert_mock_called "mock_curl"
}

# --- cached_fetch ---

@test "cache: cached_fetch passes through when CACHE_DIR is empty" {
    CACHE_DIR=""
    export CACHE_DIR
    local dest="$TEST_TMPDIR/output"
    capture cached_fetch "https://example.com/key.gpg" "$dest"
    [ "$_status" -eq 0 ]
    assert_mock_called "mock_wget"
}

@test "cache: cached_fetch uses cache hit when file exists" {
    CACHE_DIR="$TEST_TMPDIR/cache"
    export CACHE_DIR
    $_REAL_MKDIR -p "$CACHE_DIR/files"
    echo "cached_key_data" > "$CACHE_DIR/files/example.com_key.gpg"

    local dest="$TEST_TMPDIR/output"
    capture cached_fetch "https://example.com/key.gpg" "$dest"
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"Cache hit"* ]]
    assert_mock_not_called "mock_wget"
}

# --- cached_git_clone ---

@test "cache: cached_git_clone passes through when CACHE_DIR is empty" {
    CACHE_DIR=""
    export CACHE_DIR
    capture cached_git_clone "https://github.com/foo/bar.git" "$TEST_TMPDIR/bar"
    [ "$_status" -eq 0 ]
    assert_mock_called "mock_git"
}

@test "cache: cached_git_clone passes branch when specified" {
    CACHE_DIR=""
    export CACHE_DIR
    capture cached_git_clone "https://github.com/foo/bar.git" "$TEST_TMPDIR/bar" "main"
    [ "$_status" -eq 0 ]
    assert_mock_called "mock_git.*--branch main"
}

# --- cached_pip_index_args ---

@test "cache: cached_pip_index_args returns empty when CACHE_DIR is empty" {
    CACHE_DIR=""
    export CACHE_DIR
    local result
    result=$(cached_pip_index_args torch-rocm)
    [ -z "$result" ]
}

@test "cache: cached_pip_index_args returns flags when cache exists" {
    CACHE_DIR="$TEST_TMPDIR/cache"
    export CACHE_DIR
    $_REAL_MKDIR -p "$CACHE_DIR/pip/torch-rocm"
    touch "$CACHE_DIR/pip/torch-rocm/fake.whl"

    local result
    result=$(cached_pip_index_args torch-rocm)
    [[ "$result" == *"--find-links"* ]]
    [[ "$result" == *"--no-index"* ]]
}

@test "cache: cached_pip_index_args returns empty when cache dir empty" {
    CACHE_DIR="$TEST_TMPDIR/cache"
    export CACHE_DIR
    $_REAL_MKDIR -p "$CACHE_DIR/pip/torch-rocm"
    # Empty dir — no wheels

    local result
    result=$(cached_pip_index_args torch-rocm)
    [ -z "$result" ]
}
