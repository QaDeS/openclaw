#!/usr/bin/env bats
# Tests for container configuration files (Quadlet + Dockerfile).

load helpers/test_helper

DOCKER_DIR="$STRIX_DIR/docker"
QUADLET_DIR="$STRIX_DIR/quadlet"

# --- Dockerfile ---

@test "docker: Dockerfile.openclaw exists" {
    [ -f "$DOCKER_DIR/Dockerfile.openclaw" ]
}

# --- Legacy compose files kept for reference ---

@test "docker: hosting-compose.yml exists" {
    [ -f "$DOCKER_DIR/hosting-compose.yml" ]
}

@test "docker: openclaw-compose.yml exists" {
    [ -f "$DOCKER_DIR/openclaw-compose.yml" ]
}

# --- Quadlet files (primary container config) ---

@test "quadlet: all hosting quadlet files exist" {
    [ -f "$QUADLET_DIR/hosting.target" ]
    [ -f "$QUADLET_DIR/hosting-net.network" ]
    [ -f "$QUADLET_DIR/supabase-data.volume" ]
    [ -f "$QUADLET_DIR/supabase.container" ]
    [ -f "$QUADLET_DIR/wordpress.container" ]
}

@test "quadlet: openclaw.container exists" {
    [ -f "$QUADLET_DIR/openclaw.container" ]
}

@test "quadlet: ddns.container.tmpl exists" {
    [ -f "$QUADLET_DIR/ddns.container.tmpl" ]
}

@test "quadlet: supabase uses supabase/postgres image" {
    grep -q 'Image=supabase/postgres' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: wordpress uses wordpress image" {
    grep -q 'Image=wordpress:latest' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: wordpress exposes port 8080" {
    grep -q 'PublishPort=8080:80' "$QUADLET_DIR/wordpress.container"
}

@test "quadlet: supabase has SUPABASE_DB_PASSWORD placeholder" {
    grep -q 'SUPABASE_DB_PASSWORD' "$QUADLET_DIR/supabase.container"
}

@test "quadlet: openclaw uses host network" {
    grep -q 'Network=host' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: openclaw sets NODE_ENV=production" {
    grep -q 'NODE_ENV=production' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: openclaw references LOCAL_LLM_URL" {
    grep -q 'LOCAL_LLM_URL' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: openclaw mounts /home/claw/openclaw to /app" {
    grep -q '/home/claw/openclaw:/app' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: openclaw persists .openclaw config" {
    grep -q '\.openclaw' "$QUADLET_DIR/openclaw.container"
}

@test "quadlet: ddns template uses namecheap-ddns image" {
    grep -q 'linuxshots/namecheap-ddns' "$QUADLET_DIR/ddns.container.tmpl"
}

@test "quadlet: hosting-net uses bridge driver" {
    grep -q 'Driver=bridge' "$QUADLET_DIR/hosting-net.network"
}

@test "quadlet: supabase-data volume defined" {
    grep -q 'VolumeName=supabase-data' "$QUADLET_DIR/supabase-data.volume"
}
