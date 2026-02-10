#!/usr/bin/env bats
# Tests for 23-sync-llama-models.sh (Sync llama_models component).

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    load_component "23-sync-llama-models.sh"
}

teardown() {
    teardown_mocks
}

# --- Registration ---

@test "sync_llama: registers as SYNC_LLAMA component" {
    [[ " ${COMPONENT_LIST[*]} " == *" SYNC_LLAMA "* ]]
}

@test "sync_llama: registers install_sync_llama_models function" {
    [[ "${COMPONENT_FUNCS[SYNC_LLAMA]}" == *"install_sync_llama_models"* ]]
}

# --- Dry-run execution ---

@test "sync_llama: install_sync_llama_models runs in dry-run without errors" {
    DRY_RUN=true
    capture install_sync_llama_models
    [ "$_status" -eq 0 ]
}

@test "sync_llama: install_sync_llama_models mentions sync watcher" {
    DRY_RUN=true
    capture install_sync_llama_models
    [[ "$_output" == *"sync watcher"* ]] || [[ "$_output" == *"llama_models"* ]]
}

@test "sync_llama: would install inotify-tools in dry-run" {
    DRY_RUN=true
    capture install_sync_llama_models
    [[ "$_output" == *"inotify-tools"* ]]
}

@test "sync_llama: would copy sync script to /usr/local/bin in dry-run" {
    DRY_RUN=true
    capture install_sync_llama_models
    [[ "$_output" == *"sync-llama-models.sh"*"/usr/local/bin"* ]]
}

@test "sync_llama: would enable sync-llama-models service in dry-run" {
    DRY_RUN=true
    capture install_sync_llama_models
    [[ "$_output" == *"systemctl"*"enable"*"sync-llama-models"* ]]
}

# --- Script content checks ---

@test "sync_llama: component_name header is Sync llama_models" {
    grep -q "^# component_name: Sync llama_models" "$STRIX_DIR/components/23-sync-llama-models.sh"
}

@test "sync_llama: component_description header is present" {
    grep -q "^# component_description:" "$STRIX_DIR/components/23-sync-llama-models.sh"
}

# --- Sync script content checks ---

@test "sync_llama: sync script exists" {
    [ -f "$STRIX_DIR/scripts/sync-llama-models.sh" ]
}

@test "sync_llama: sync script is executable" {
    [ -x "$STRIX_DIR/scripts/sync-llama-models.sh" ]
}

@test "sync_llama: sync script supports --watch flag" {
    grep -q "\-\-watch" "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script uses inotifywait for watching" {
    grep -q "inotifywait" "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script defaults to /models source" {
    grep -q 'MODELS_SRC.*:-/models' "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script defaults to /llama_models dest" {
    grep -q 'MODELS_DST.*:-/llama_models' "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script handles mmproj multimodal models" {
    grep -q "mmproj" "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script cleans up stale symlinks" {
    grep -q "stale" "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script has debounce for rapid changes" {
    grep -q "DEBOUNCE_SEC" "$STRIX_DIR/scripts/sync-llama-models.sh"
}

@test "sync_llama: sync script skips /models/models symloop" {
    grep -q 'MODELS_SRC/models' "$STRIX_DIR/scripts/sync-llama-models.sh"
}
