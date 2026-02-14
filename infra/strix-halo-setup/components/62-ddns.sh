#!/bin/bash

# component_name: Dynamic DNS
# component_description: Namecheap DDNS via Podman Quadlet

install_ddns() {
    # Early return if DDNS_FQDN is empty
    if [ -z "$DDNS_FQDN" ]; then
        log "DDNS FQDN not configured; skipping DDNS setup."
        return 0
    fi

    log "Setting up Dynamic DNS for ${DDNS_FQDN}..."

    # Create ddns user at /home/ddns
    if ! id ddns &>/dev/null; then
        run useradd -m -d /home/ddns -s /bin/bash ddns
    fi

    # Create secrets directory
    run mkdir -p /home/ddns/.secrets
    run chmod 700 /home/ddns/.secrets
    run chown ddns:ddns /home/ddns/.secrets

    # Split FQDN into host + domain
    local host_part domain_part
    host_part="${DDNS_FQDN%%.*}"
    domain_part="${DDNS_FQDN#*.}"

    # Resolve DDNS secret
    local pass_file="/home/ddns/.secrets/${DDNS_FQDN}.pass"
    local ddns_secret
    ddns_secret=""
    if [ "$DRY_RUN" = false ]; then
        if [ -f "$pass_file" ]; then
            ddns_secret=$(cat "$pass_file")
            log "Using existing DDNS credential from ${pass_file}"
        elif [ -n "${DDNS_PASSWORD:-}" ]; then
            echo "$DDNS_PASSWORD" | tee "$pass_file" >/dev/null
            chmod 600 "$pass_file"
            chown ddns:ddns "$pass_file"
            ddns_secret="$DDNS_PASSWORD"
            log "Wrote DDNS credential to ${pass_file}"
        else
            warn "No DDNS credential found. Create ${pass_file} manually, then re-run."
            warn "  echo 'your-namecheap-ddns-key' | sudo tee ${pass_file}"
            warn "  sudo chmod 600 ${pass_file} && sudo chown ddns:ddns ${pass_file}"
            return 0
        fi

        # Deploy quadlet file from template
        local quadlet_dir="/home/ddns/.config/containers/systemd"
        local tmpl="${INFRA_DIR}/quadlet/ddns.container.tmpl"
        local container_name="ddns-${DDNS_FQDN}"
        local quadlet_file="${quadlet_dir}/${container_name}.container"

        mkdir -p "$quadlet_dir"
        sed -e "s|%FQDN%|${DDNS_FQDN}|g" \
            -e "s|%DOMAIN%|${domain_part}|g" \
            -e "s|%HOST%|${host_part}|g" \
            -e "s|%PASSWORD%|${ddns_secret}|g" \
            "$tmpl" > "$quadlet_file"

        chown -R ddns:ddns /home/ddns/.config
        track_file_create "$quadlet_file"
        track_podman "$container_name" "linuxshots/namecheap-ddns"

        ensure_linger ddns
        user_systemctl ddns daemon-reload
        user_systemctl ddns start "${container_name}.service"

        success "DDNS quadlet deployed: ${container_name}"
    else
        log "${YELLOW}[DRY-RUN] Will deploy DDNS quadlet for ${DDNS_FQDN}${NC}"
    fi
}

register_component "DDNS" "install_ddns"
