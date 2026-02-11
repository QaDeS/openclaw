#!/bin/bash

# component_name: Dynamic DNS
# component_description: Namecheap DDNS via Docker container

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
    if command -v docker &>/dev/null; then
        run usermod -aG docker ddns
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

        # Stop + rm existing container (idempotent)
        local container_name="ddns-${DDNS_FQDN}"
        docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || true

        # Run DDNS container
        docker run -d \
            --name "$container_name" \
            --restart always \
            -e DOMAIN="$domain_part" \
            -e HOST="$host_part" \
            -e PASSWORD="$ddns_secret" \
            linuxshots/namecheap-ddns

        success "DDNS container started: ${container_name}"
    else
        log "${YELLOW}[DRY-RUN] Will deploy DDNS container for ${DDNS_FQDN}${NC}"
    fi
}

register_component "DDNS" "install_ddns"
