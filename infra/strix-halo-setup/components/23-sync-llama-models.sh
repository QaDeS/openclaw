#!/bin/bash

# component_name: Sync llama_models
# component_description: Watches /models and maintains flat /llama_models for llama.cpp

install_sync_llama_models() {
    log "Installing llama_models sync watcher..."

    run apt-get install -y inotify-tools

    # Install sync script
    run cp ${INFRA_DIR}/scripts/sync-llama-models.sh /usr/local/bin/sync-llama-models.sh
    run chmod +x /usr/local/bin/sync-llama-models.sh
    track_file_create /usr/local/bin/sync-llama-models.sh

    # Initial sync: populate /llama_models from /models
    if [ "$DRY_RUN" = false ]; then
        /usr/local/bin/sync-llama-models.sh
    fi

    # Install and enable systemd watcher
    run cp ${INFRA_DIR}/systemd/sync-llama-models.service /etc/systemd/system/sync-llama-models.service
    track_file_create /etc/systemd/system/sync-llama-models.service
    run systemctl daemon-reload
    run systemctl enable sync-llama-models
    track_service sync-llama-models
}

register_component "SYNC_LLAMA" "install_sync_llama_models"
