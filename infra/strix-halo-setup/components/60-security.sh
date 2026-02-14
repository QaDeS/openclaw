#!/bin/bash

# component_name: Security & Hosting
# component_description: Cisco AI Defense and Web Hosting Stack

install_cisco_defense() {
    log "Installing Cisco AI Defense..."
    ensure_user defense
    run cp ${INFRA_DIR}/defense/cisco-defense-daemon.py /home/defense/
    run chown defense:defense /home/defense/cisco-defense-daemon.py
    if [ "$DRY_RUN" = false ]; then
        sudo -u defense bash -c "source '${CACHE_HELPERS}' && cached_curl_pipe 'https://astral.sh/uv/install.sh' sh"
        # Install available scanners as uv tools (a2a-scanner/skill-scanner not yet on PyPI)
        sudo -u defense /home/defense/.local/bin/uv --no-config tool install mcp-scan --python 3.11
    fi
    track_file_create /home/defense/cisco-defense-daemon.py
    run cp ${INFRA_DIR}/systemd/cisco-defense.service /etc/systemd/system/cisco-defense.service
    track_file_create /etc/systemd/system/cisco-defense.service
    run systemctl daemon-reload
    run systemctl enable cisco-defense
    track_service cisco-defense
}

install_hosting_stack() {
    log "Installing Web Hosting Stack (Supabase + WordPress) via Podman Quadlet..."
    ensure_user hosting

    # Deploy quadlet files for rootless podman
    local quadlet_dir="/home/hosting/.config/containers/systemd"
    run mkdir -p "$quadlet_dir"

    if [ "$DRY_RUN" = false ]; then
        log "Generating hosting secrets..."
        local pg_pass
        pg_pass=$(openssl rand -hex 16)

        # Deploy quadlet files with password substitution
        for qfile in hosting.pod hosting-net.network supabase-data.volume supabase.container wordpress.container; do
            local src="${INFRA_DIR}/quadlet/${qfile}"
            if [ -f "$src" ]; then
                sed "s|%SUPABASE_DB_PASSWORD%|${pg_pass}|g" "$src" > "${quadlet_dir}/${qfile}"
                track_file_create "${quadlet_dir}/${qfile}"
            fi
        done

        chown -R hosting:hosting /home/hosting/.config
        ensure_linger hosting
        user_systemctl hosting daemon-reload
        user_systemctl hosting start hosting-pod.service
    else
        run echo "deploy quadlet files for hosting stack"
        run echo "enable linger + start hosting-pod.service for hosting user"
    fi

    track_service "hosting-pod (user@hosting)"
}

register_component "SECURITY" "install_cisco_defense" "install_hosting_stack"
