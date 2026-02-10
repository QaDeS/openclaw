#!/bin/bash
# sync-llama-models.sh
# Creates and maintains a flat /llama_models directory with symlinks
# compatible with llama.cpp's --models-dir router mode.
#
# Usage:
#   sync-llama-models.sh              # one-shot sync
#   sync-llama-models.sh --watch      # sync then watch /models for changes
#
# Rules (from llama.cpp link_models):
#   - Directories with mmproj files → symlink the whole directory
#   - Standalone .gguf files → symlink the file directly
#   - Skips directories with no .gguf files
#   - Skips the circular /models/models symloop
#   - Cleans up stale symlinks on each sync

set -euo pipefail

MODELS_SRC="${MODELS_SRC:-/models}"
MODELS_DST="${MODELS_DST:-/llama_models}"
DEBOUNCE_SEC="${DEBOUNCE_SEC:-3}"

log() { echo "[sync-llama-models] $(date '+%H:%M:%S') $1"; }

# --- Sync logic -----------------------------------------------------------
sync_models() {
    mkdir -p "$MODELS_DST"
    local added=0 removed=0

    # 1) Remove stale symlinks (targets that disappeared)
    for link in "$MODELS_DST"/*; do
        [ -L "$link" ] || continue
        if [ ! -e "$link" ]; then
            log "REMOVE (stale): $(basename "$link")"
            rm -f "$link"
            ((removed++)) || true
        fi
    done

    # 2) Walk /models and create flat symlinks
    while IFS= read -r dir; do
        # Skip if no .gguf files
        shopt -s nullglob
        ggufs=("$dir"/*.gguf)
        shopt -u nullglob
        [[ ${#ggufs[@]} -eq 0 ]] && continue

        dirname=$(basename "$dir")
        has_mmproj=false
        for f in "${ggufs[@]}"; do
            [[ "$(basename "$f")" == mmproj* ]] && { has_mmproj=true; break; }
        done

        if $has_mmproj; then
            # Multimodal model — symlink the whole directory
            target="$MODELS_DST/$dirname"
            if [ ! -e "$target" ]; then
                ln -s "$dir" "$target"
                log "LINK DIR:  $dirname -> $dir"
                ((added++)) || true
            fi
        else
            # Single model(s) — symlink each .gguf individually
            for f in "${ggufs[@]}"; do
                fname=$(basename "$f")
                target="$MODELS_DST/$fname"
                if [ ! -e "$target" ]; then
                    ln -s "$f" "$target"
                    log "LINK FILE: $fname -> $f"
                    ((added++)) || true
                fi
            done
        fi
    done < <(find "$MODELS_SRC" -mindepth 2 -maxdepth 3 -type d \
                ! -path "$MODELS_SRC/models" ! -path "$MODELS_SRC/models/*" 2>/dev/null | sort)

    log "Sync complete: +${added} added, -${removed} stale removed ($(ls "$MODELS_DST" 2>/dev/null | wc -l) total)"
}

# --- Watch mode ------------------------------------------------------------
watch_models() {
    if ! command -v inotifywait &>/dev/null; then
        log "ERROR: inotifywait not found — install inotify-tools"
        exit 1
    fi

    log "Watching $MODELS_SRC for changes (debounce: ${DEBOUNCE_SEC}s)..."

    # inotifywait: recursive watch for file/dir create, delete, move, close-write
    # --monitor keeps it running; we debounce by consuming events for DEBOUNCE_SEC
    while true; do
        # Block until something changes
        inotifywait -r -q \
            -e create -e delete -e moved_to -e moved_from -e close_write \
            --exclude '/\.' \
            "$MODELS_SRC" >/dev/null 2>&1

        # Debounce: drain rapid-fire events (e.g. multi-file LM Studio download)
        log "Change detected, waiting ${DEBOUNCE_SEC}s to settle..."
        sleep "$DEBOUNCE_SEC"

        # Drain any queued events by running a short non-blocking wait
        timeout 1 inotifywait -r -q \
            -e create -e delete -e moved_to -e moved_from -e close_write \
            --exclude '/\.' \
            "$MODELS_SRC" >/dev/null 2>&1 || true

        sync_models
    done
}

# --- Main ------------------------------------------------------------------
log "Models source: $MODELS_SRC"
log "Models dest:   $MODELS_DST"

# Initial sync always runs
sync_models

if [[ "${1:-}" == "--watch" ]]; then
    watch_models
fi
