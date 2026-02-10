#!/usr/bin/env bats
# Integration tests: component loading and execution flow.

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
}

teardown() {
    teardown_mocks
}

# --- All components load without error ---

@test "integration: all 9 components source without error" {
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    # If we get here, no source failed
    [ ${#COMPONENT_LIST[@]} -ge 1 ]
}

@test "integration: after sourcing all components, COMPONENT_LIST has 9 entries" {
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    echo "COMPONENT_LIST: ${COMPONENT_LIST[*]}"
    [ ${#COMPONENT_LIST[@]} -eq 9 ]
}

@test "integration: after sourcing all components, expected IDs are registered" {
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    for expected in BASE OPENCLAW LMSTUDIO LLAMACPP SYNC_LLAMA COMFYUI ZIMAGE ACE_STEP SECURITY; do
        [[ " ${COMPONENT_LIST[*]} " == *" $expected "* ]] || {
            echo "Missing component: $expected"
            return 1
        }
    done
}

@test "integration: all registered functions are callable" {
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    for id in "${COMPONENT_LIST[@]}"; do
        for func in ${COMPONENT_FUNCS[$id]}; do
            type -t "$func" | grep -q "function" || {
                echo "Function not defined: $func (component $id)"
                return 1
            }
        done
    done
}

# --- Dry-run execution of all components ---

@test "integration: all components execute in dry-run without errors" {
    DRY_RUN=true
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    for id in "${COMPONENT_LIST[@]}"; do
        for func in ${COMPONENT_FUNCS[$id]}; do
            capture "$func"
            echo "Running $func (component $id): status=$_status"
            [ "$_status" -eq 0 ] || {
                echo "Output: $_output"
                return 1
            }
        done
    done
}

# --- Component ordering ---

@test "integration: BASE component is first in load order" {
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    [ "${COMPONENT_LIST[0]}" = "BASE" ]
}

@test "integration: SECURITY component is last in load order" {
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
    local last_idx=$(( ${#COMPONENT_LIST[@]} - 1 ))
    [ "${COMPONENT_LIST[$last_idx]}" = "SECURITY" ]
}

# --- Cross-component consistency ---

@test "integration: every service user is referenced in at least one component" {
    local all_components
    all_components=$(cat "$STRIX_DIR"/components/*.sh)
    for user in lmstudio llamacpp comfyui claw hosting defense; do
        echo "$all_components" | grep -q "$user" || {
            echo "User '$user' not referenced in any component"
            return 1
        }
    done
}

@test "integration: every systemd service has a matching component that enables it" {
    local all_components
    all_components=$(cat "$STRIX_DIR"/components/*.sh)
    for service_file in "$STRIX_DIR"/systemd/*.service; do
        local service_name
        service_name=$(basename "$service_file" .service)
        echo "$all_components" | grep -q "systemctl.*enable.*$service_name" || {
            echo "No component enables service: $service_name"
            return 1
        }
    done
}

@test "integration: every systemd service is deployed by its own component (not base)" {
    local non_base_components
    non_base_components=$(cat "$STRIX_DIR"/components/[2-9]*.sh)
    for service_file in "$STRIX_DIR"/systemd/*.service; do
        local service_name
        service_name=$(basename "$service_file" .service)
        echo "$non_base_components" | grep -q "cp.*${service_name}.service.*/etc/systemd/system/" || {
            echo "No component deploys service file: $service_name"
            return 1
        }
    done
}

@test "integration: every systemd user has an ensure_user call in components" {
    local all_components
    all_components=$(cat "$STRIX_DIR"/components/*.sh)
    for f in "$STRIX_DIR"/systemd/*.service; do
        local user
        user=$(grep '^User=' "$f" | cut -d= -f2)
        [[ -n "$user" ]] || continue
        echo "$all_components" | grep -q "ensure_user $user" || {
            echo "Systemd user '$user' ($(basename "$f")) has no ensure_user call in components"
            return 1
        }
    done
}

# --- Docker compose file references ---

@test "integration: openclaw-compose.yml is referenced in LLM component" {
    grep -q "openclaw-compose.yml" "$STRIX_DIR/components/20-llm-stack.sh"
}

@test "integration: hosting-compose.yml is referenced in security component" {
    grep -q "hosting-compose.yml" "$STRIX_DIR/components/60-security.sh"
}

# --- Defense daemon references ---

@test "integration: defense daemon is referenced in security component" {
    grep -q "cisco-defense-daemon.py" "$STRIX_DIR/components/60-security.sh"
}

@test "integration: defense daemon service matches the daemon path in component" {
    local service_path
    service_path=$(grep "ExecStart" "$STRIX_DIR/systemd/cisco-defense.service" | grep -o '/home/defense/.*')
    grep -q "cisco-defense-daemon.py" <<< "$service_path"
}

# --- No hardcoded secrets ---

@test "integration: no hardcoded passwords in component scripts" {
    for f in "$STRIX_DIR"/components/*.sh; do
        if grep -Pi 'password\s*=\s*["\x27][^$]' "$f" 2>/dev/null; then
            echo "Possible hardcoded password in $(basename "$f")"
            return 1
        fi
    done
}

@test "integration: no hardcoded secrets in docker compose files" {
    for f in "$STRIX_DIR"/docker/*.yml; do
        if grep -P 'PASSWORD:\s+[^$\s{]' "$f" 2>/dev/null; then
            echo "Possible hardcoded password in $(basename "$f")"
            return 1
        fi
    done
}
