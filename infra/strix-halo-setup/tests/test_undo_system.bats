#!/usr/bin/env bats

# Test suite for the backup / undo / history infrastructure.
# Sources the real functions from provision_strix_halo.sh (not the test stubs)
# so we exercise init_run_state, backup_file, manifest_record, show_history, do_undo.

load helpers/test_helper

# --- helpers ---

# Source the REAL backup/undo functions from the provisioning script.
# The script guards `main "$@"` behind BASH_SOURCE[0]==$0, so sourcing
# only defines functions and runs the top-level variable init (harmless).
_load_real_undo_functions() {
    # Save current set options, source the script (which sets -eo pipefail),
    # then restore to bats-friendly settings.
    local _old_opts
    _old_opts=$(set +o)
    export DRY_RUN=false
    export INFRA_DIR="$STRIX_DIR"
    source "$STRIX_DIR/provision_strix_halo.sh" 2>/dev/null || true
    # Restore set options (bats needs set +e)
    eval "$_old_opts" 2>/dev/null || true
    set +e

    # Restore our test log/warn/error/success (script defines ANSI versions)
    log()     { echo "[INFO] $1"; }
    warn()    { echo "[WARN] $1"; }
    success() { echo "[SUCCESS] $1"; }
    error()   { echo "[ERROR] $1"; return 1; }
}

# Call init_run_state and propagate its globals back.
# (capture runs in a subshell, losing variable assignments)
_init_state() {
    init_run_state
}

setup() {
    setup_mocks
    load_provision_globals
    # Load the real implementations (overrides the stubs from load_provision_globals)
    _load_real_undo_functions
    # Re-point state at temp dir (sourcing the script resets these)
    STATE_DIR="$TEST_TMPDIR/strix-provision"
    $_REAL_MKDIR -p "$STATE_DIR/manifests" "$STATE_DIR/backups"
    DRY_RUN=false
    SUDO_USER="testuser"
    CURRENT_COMPONENT="TEST_COMP"
}

teardown() {
    teardown_mocks
}

# ---- init_run_state ----

@test "init_run_state creates dirs and manifest" {
    _init_state
    [ -n "$RUN_TS" ]
    [ -d "$BACKUP_DIR" ]
    [ -f "$MANIFEST_FILE" ]
    # Manifest should contain header lines
    grep -q "STRIX_RUN_MANIFEST v1" "$MANIFEST_FILE"
    grep -q "# timestamp:" "$MANIFEST_FILE"
    grep -q "# user: testuser" "$MANIFEST_FILE"
}

@test "init_run_state in dry-run skips file creation" {
    DRY_RUN=true
    # Remove pre-created dirs
    rm -rf "$STATE_DIR"
    _init_state
    [ -n "$RUN_TS" ]
    # No backup dir created (STATE_DIR itself was removed)
    [ ! -d "$STATE_DIR/backups/$RUN_TS" ]
}

# ---- backup_file ----

@test "backup_file copies file and records in manifest" {
    _init_state
    local src="$TEST_TMPDIR/original.conf"
    echo "original content" > "$src"

    backup_file "$src"

    # Check backup exists
    local flat
    flat=$(echo "$src" | sed 's|^/||; s|/|-|g')
    [ -f "${BACKUP_DIR}/${flat}" ]

    # Check manifest has backup_file entry
    grep -q "backup_file" "$MANIFEST_FILE"
}

@test "backup_file is idempotent within a run" {
    _init_state
    local src="$TEST_TMPDIR/idempotent.conf"
    echo "v1" > "$src"

    backup_file "$src"
    # Modify original
    echo "v2" > "$src"
    backup_file "$src"

    # Backup should still contain v1 (first copy wins)
    local flat
    flat=$(echo "$src" | sed 's|^/||; s|/|-|g')
    grep -q "v1" "${BACKUP_DIR}/${flat}"

    # Only one backup_file entry in manifest
    local count
    count=$(grep -c "backup_file" "$MANIFEST_FILE")
    [ "$count" -eq 1 ]
}

@test "backup_file skips missing files" {
    _init_state
    backup_file "/nonexistent/path/file.txt"
    # No entry in manifest
    ! grep -q "backup_file" "$MANIFEST_FILE"
}

# ---- manifest_record ----

@test "manifest_record writes tab-separated line" {
    _init_state
    manifest_record "create_file" "SSH" "/etc/ssh/config"

    local line
    line=$(grep "create_file" "$MANIFEST_FILE")
    # Should be tab-separated
    [[ "$line" == *$'\t'"SSH"$'\t'* ]]
}

@test "manifest_record skipped in dry-run" {
    _init_state
    DRY_RUN=true
    manifest_record "create_file" "SSH" "/etc/ssh/config"
    # grep returns 1 when not found
    ! grep -q "create_file" "$MANIFEST_FILE"
}

# ---- tracking helpers ----

@test "track_file_create records in manifest" {
    _init_state
    track_file_create "/etc/test.conf"
    grep -q "create_file" "$MANIFEST_FILE"
    grep -q "/etc/test.conf" "$MANIFEST_FILE"
}

@test "track_service records in manifest" {
    _init_state
    track_service "myservice"
    grep -q "enable_service" "$MANIFEST_FILE"
    grep -q "myservice" "$MANIFEST_FILE"
}

@test "track_ufw_rule records in manifest" {
    _init_state
    track_ufw_rule "limit 22/tcp"
    grep -q "add_ufw_rule" "$MANIFEST_FILE"
    grep -q "limit 22/tcp" "$MANIFEST_FILE"
}

@test "track_docker records in manifest" {
    _init_state
    track_docker "my-container" "my-image:latest"
    grep -q "docker_container" "$MANIFEST_FILE"
    grep -q "my-container" "$MANIFEST_FILE"
}

@test "undo_note records in manifest" {
    _init_state
    undo_note "Packages not auto-removed"
    grep -q "undo_note" "$MANIFEST_FILE"
    grep -q "Packages not auto-removed" "$MANIFEST_FILE"
}

# ---- show_history ----

@test "show_history lists runs" {
    # Create a fake manifest
    local ts="20260213-120000"
    cat > "$STATE_DIR/manifests/${ts}.manifest" <<EOF
# STRIX_RUN_MANIFEST v1
# timestamp: ${ts}
# components: SSH_OUTSIDE_HOME,BASE
# user: mk
EOF

    capture show_history
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"20260213-120000"* ]]
    [[ "$_output" == *"applied"* ]]
    [[ "$_output" == *"SSH_OUTSIDE_HOME,BASE"* ]]
}

@test "show_history shows undone status" {
    local ts="20260213-130000"
    cat > "$STATE_DIR/manifests/${ts}.manifest" <<EOF
# STRIX_RUN_MANIFEST v1
# timestamp: ${ts}
# components: BASE
# user: mk
EOF
    echo "Undone" > "$STATE_DIR/manifests/${ts}.manifest.undone"

    capture show_history
    [[ "$_output" == *"undone"* ]]
}

@test "show_history with no runs" {
    rm -rf "$STATE_DIR/manifests"/*
    capture show_history
    [[ "$_output" == *"No provisioning runs recorded"* ]]
}

# ---- resolve_manifest ----

@test "resolve_manifest by timestamp" {
    local ts="20260213-140000"
    touch "$STATE_DIR/manifests/${ts}.manifest"

    local result
    result=$(resolve_manifest "$ts")
    [[ "$result" == *"${ts}.manifest" ]]
}

@test "resolve_manifest returns empty for missing timestamp" {
    local result
    result=$(resolve_manifest "99990101-000000") || true
    [ -z "$result" ]
}

@test "find_latest_manifest skips undone" {
    local ts1="20260213-100000"
    local ts2="20260213-110000"
    touch "$STATE_DIR/manifests/${ts1}.manifest"
    touch "$STATE_DIR/manifests/${ts2}.manifest"
    echo "Undone" > "$STATE_DIR/manifests/${ts2}.manifest.undone"

    local result
    result=$(find_latest_manifest)
    [[ "$result" == *"${ts1}.manifest" ]]
}

# ---- do_undo ----

@test "do_undo restores backed-up files" {
    _init_state
    local ts="$RUN_TS"

    # Create a file, back it up, modify it
    local target="$TEST_TMPDIR/target.conf"
    echo "original" > "$target"
    backup_file "$target"
    echo "modified" > "$target"

    # Add components header so manifest is valid
    sed -i "2a # components: TEST" "$MANIFEST_FILE"

    # Undo
    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]

    # File should be restored
    grep -q "original" "$target"
    # .undone sidecar should exist
    [ -f "${MANIFEST_FILE}.undone" ]
}

@test "do_undo removes created files" {
    _init_state
    local ts="$RUN_TS"

    local created="$TEST_TMPDIR/created.conf"
    echo "new file" > "$created"
    track_file_create "$created"

    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]
    [ ! -f "$created" ]
}

@test "do_undo disables services" {
    _init_state
    local ts="$RUN_TS"

    track_service "test-svc"

    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]
    # systemctl mock should have been called with disable
    assert_mock_called "mock_systemctl disable test-svc"
}

@test "do_undo removes symlinks" {
    _init_state
    local ts="$RUN_TS"

    local link_path="$TEST_TMPDIR/my-link"
    $_REAL_LN -sf "$TEST_TMPDIR" "$link_path"
    track_symlink "$link_path" "$TEST_TMPDIR"

    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]
    [ ! -L "$link_path" ]
}

@test "do_undo emits warning for undo_note" {
    _init_state
    local ts="$RUN_TS"

    undo_note "Packages not auto-removed"

    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"Non-reversible"* ]]
    [[ "$_output" == *"Packages not auto-removed"* ]]
}

@test "double undo errors" {
    _init_state
    local ts="$RUN_TS"
    echo "Undone" > "${MANIFEST_FILE}.undone"

    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -ne 0 ]
    [[ "$_output" == *"already been undone"* ]]
}

@test "undo with missing manifest errors" {
    UNDO_TARGET="99990101-000000"
    capture do_undo
    [ "$_status" -ne 0 ]
    [[ "$_output" == *"No manifest found"* ]]
}

@test "do_undo warns on missing backup file" {
    _init_state
    local ts="$RUN_TS"

    # Manually write a backup_file entry pointing to nonexistent backup
    manifest_record "backup_file" "TEST" "/etc/fake.conf" "/nonexistent/backup"

    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]
    [[ "$_output" == *"Backup missing"* ]]
}

@test "do_undo dry-run doesn't modify files" {
    _init_state
    local ts="$RUN_TS"

    local target="$TEST_TMPDIR/dryrun.conf"
    echo "original" > "$target"
    backup_file "$target"
    echo "modified" > "$target"

    DRY_RUN=true
    UNDO_TARGET="$ts"
    capture do_undo
    [ "$_status" -eq 0 ]

    # File should still be modified
    grep -q "modified" "$target"
    # No .undone sidecar
    [ ! -f "${MANIFEST_FILE}.undone" ]
    [[ "$_output" == *"DRY-RUN"* ]]
}
