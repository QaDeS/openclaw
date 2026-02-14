#!/usr/bin/env bats
# Tests for Podman Quadlet files and deployment.

load helpers/test_helper

QUADLET_DIR="$STRIX_DIR/quadlet"

# --- File existence ---

@test "quadlet: hosting.target exists" {
    [ -f "$QUADLET_DIR/hosting.target" ]
}

@test "quadlet: hosting-net.network exists" {
    [ -f "$QUADLET_DIR/hosting-net.network" ]
}

@test "quadlet: supabase-data.volume exists" {
    [ -f "$QUADLET_DIR/supabase-data.volume" ]
}

@test "quadlet: supabase.container exists" {
    [ -f "$QUADLET_DIR/supabase.container" ]
}

@test "quadlet: wordpress.container exists" {
    [ -f "$QUADLET_DIR/wordpress.container" ]
}

@test "quadlet: openclaw.container exists" {
    [ -f "$QUADLET_DIR/openclaw.container" ]
}

@test "quadlet: ddns.container.tmpl exists" {
    [ -f "$QUADLET_DIR/ddns.container.tmpl" ]
}

# --- INI syntax (all quadlet files have [Unit] or [Pod] or [Network] or [Volume] section) ---

@test "quadlet: hosting.target has [Unit] section" {
    grep -q '^\[Unit\]' "$QUADLET_DIR/hosting.target"
}

@test "quadlet: hosting-net.network has [Network] section" {
    grep -q '^\[Network\]' "$QUADLET_DIR/hosting-net.network"
}

@test "quadlet: supabase-data.volume has [Volume] section" {
    grep -q '^\[Volume\]' "$QUADLET_DIR/supabase-data.volume"
}

@test "quadlet: supabase.container has [Container] section" {
    grep -q '^\[Container\]' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: wordpress.container has [Container] section" {
    grep -q '^\[Container\]' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: openclaw.container has [Container] section" {
    grep -q '^\[Container\]' "$QUADLET_DIR/openclaw.container"
}

# --- Content checks ---

@test "quadlet: supabase uses supabase/postgres image" {
    grep -q 'Image=supabase/postgres' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: wordpress uses wordpress image" {
    grep -q 'Image=wordpress:latest' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: wordpress exposes port 8080" {
    grep -q 'PublishPort=8080:80' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: supabase has password placeholder" {
    grep -q '%SUPABASE_DB_PASSWORD%' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: wordpress has password placeholder" {
    grep -q '%SUPABASE_DB_PASSWORD%' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: openclaw uses host network" {
    grep -q 'Network=host' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: openclaw has LOCAL_LLM_URL placeholder" {
    grep -q '%LOCAL_LLM_URL%' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: openclaw mounts /home/claw/openclaw" {
    grep -q '/home/claw/openclaw:/app' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: ddns template has FQDN placeholder" {
    grep -q '%FQDN%' "$QUADLET_DIR/ddns.container.tmpl"
}

@test "quadlet: ddns template uses namecheap-ddns image" {
    grep -q 'linuxshots/namecheap-ddns' "$QUADLET_DIR/ddns.container.tmpl"
}

# --- Hosting pod references ---

@test "quadlet: supabase references hosting target via PartOf" {
    grep -q 'PartOf=hosting.target' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: wordpress references hosting target via PartOf" {
    grep -q 'PartOf=hosting.target' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: supabase uses hosting-net network" {
    grep -q 'Network=hosting-net' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: supabase uses supabase-data volume" {
    grep -q 'Volume=supabase-data' "$QUADLET_DIR/supabase.container"
}

# --- Template substitution ---

@test "quadlet: ddns template substitution works" {
    local result
    result=$(sed -e 's|%FQDN%|test.example.com|g' \
                 -e 's|%DOMAIN%|example.com|g' \
                 -e 's|%HOST%|test|g' \
                 -e 's|%PASSWORD%|secret123|g' \
                 "$QUADLET_DIR/ddns.container.tmpl")
    [[ "$result" == *"ContainerName=ddns-test.example.com"* ]]
    [[ "$result" == *"DOMAIN=example.com"* ]]
    [[ "$result" == *"HOST=test"* ]]
    [[ "$result" == *"PASSWORD=secret123"* ]]
}
