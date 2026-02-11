#!/usr/bin/env bats
# Tests for Docker Compose configuration files.

load helpers/test_helper

DOCKER_DIR="$STRIX_DIR/docker"

# --- File existence ---

@test "docker: openclaw-compose.yml exists" {
    [ -f "$DOCKER_DIR/openclaw-compose.yml" ]
}

@test "docker: hosting-compose.yml exists" {
    [ -f "$DOCKER_DIR/hosting-compose.yml" ]
}

# --- YAML validation ---

@test "docker: openclaw-compose.yml is valid YAML" {
    python3 -c "
import yaml, sys
with open('$DOCKER_DIR/openclaw-compose.yml') as f:
    yaml.safe_load(f)
print('valid')
"
}

@test "docker: hosting-compose.yml is valid YAML" {
    python3 -c "
import yaml, sys
with open('$DOCKER_DIR/hosting-compose.yml') as f:
    yaml.safe_load(f)
print('valid')
"
}

# --- openclaw-compose.yml ---

@test "docker: openclaw-compose has version key" {
    grep -q '^version:' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose defines openclaw service" {
    grep -q 'openclaw:' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose uses host network mode" {
    grep -q 'network_mode: host' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose sets NODE_ENV=production" {
    grep -q 'NODE_ENV=production' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose references LOCAL_LLM_URL" {
    grep -q 'LOCAL_LLM_URL' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose mounts /home/claw/openclaw to /app" {
    grep -q '/home/claw/openclaw:/app' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose persists .openclaw config" {
    grep -q '\.openclaw' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose references a Dockerfile" {
    grep -q 'dockerfile:' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: Dockerfile.openclaw exists" {
    [ -f "$DOCKER_DIR/Dockerfile.openclaw" ]
}

@test "docker: openclaw-compose references Dockerfile.openclaw" {
    grep -q 'Dockerfile.openclaw' "$DOCKER_DIR/openclaw-compose.yml"
}

@test "docker: openclaw-compose sets restart policy" {
    grep -q 'restart:' "$DOCKER_DIR/openclaw-compose.yml"
}

# --- hosting-compose.yml ---

@test "docker: hosting-compose has version key" {
    grep -q '^version:' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose defines supabase service" {
    grep -q 'supabase:' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose defines wordpress service" {
    grep -q 'wordpress:' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose uses supabase/postgres image" {
    grep -q 'supabase/postgres' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose uses wordpress image" {
    grep -q 'image: wordpress' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose wordpress depends_on supabase" {
    grep -q 'depends_on' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose exposes port 8080" {
    grep -q '8080:80' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose uses SUPABASE_DB_PASSWORD variable" {
    grep -q 'SUPABASE_DB_PASSWORD' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose configures WordPress multisite" {
    grep -q "MULTISITE.*true" "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose has persistent volume for supabase" {
    grep -q 'supabase_data' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose defines hosting_net network" {
    grep -q 'hosting_net' "$DOCKER_DIR/hosting-compose.yml"
}

@test "docker: hosting-compose uses bridge network driver" {
    grep -q 'driver: bridge' "$DOCKER_DIR/hosting-compose.yml"
}
