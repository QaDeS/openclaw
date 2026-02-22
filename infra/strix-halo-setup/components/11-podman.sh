#!/bin/bash

# component_name: Podman
# component_description: Podman container runtime (rootless, replaces Docker)

install_podman() {
    log "Installing Podman..."
    run cached_apt_install podman
    undo_note "Package podman not auto-removed on undo"
}

register_component "PODMAN" "install_podman"
