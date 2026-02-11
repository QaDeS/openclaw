#!/usr/bin/env bats
# Production safety tests.
# Catches classes of bugs that silently break provisioning in the real world
# but pass in dry-run or when all components are selected.

load helpers/test_helper

setup() {
    setup_mocks
    load_provision_globals
    for f in "$STRIX_DIR"/components/*.sh; do
        source "$f"
    done
}

teardown() {
    teardown_mocks
}

# =============================================================================
# Force-mode execution: each component runs with DRY_RUN=false (mocked commands)
# Catches errors that only manifest in force mode (conditional blocks, real paths).
# =============================================================================

@test "force-mode: every component function succeeds with mocked commands" {
    DRY_RUN=false
    for id in "${COMPONENT_LIST[@]}"; do
        for func in ${COMPONENT_FUNCS[$id]}; do
            capture "$func"
            [ "$_status" -eq 0 ] || {
                echo "FAILED in force-mode: $func (component $id)"
                echo "Output: $_output"
                return 1
            }
        done
    done
}

@test "force-mode: BASE executes all 3 sub-functions" {
    DRY_RUN=false
    local funcs="${COMPONENT_FUNCS[BASE]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 3 ]
    for func in $funcs; do
        capture "$func"
        [ "$_status" -eq 0 ] || {
            echo "FAILED: $func: $_output"
            return 1
        }
    done
}

@test "force-mode: SECURITY executes all 2 sub-functions" {
    DRY_RUN=false
    local funcs="${COMPONENT_FUNCS[SECURITY]}"
    local count
    count=$(echo "$funcs" | wc -w)
    [ "$count" -eq 2 ]
    for func in $funcs; do
        capture "$func"
        [ "$_status" -eq 0 ] || {
            echo "FAILED: $func: $_output"
            return 1
        }
    done
}

# =============================================================================
# Partial selection: selecting each INDIVIDUAL component works under set -e.
# Catches the class of bug where the for loop's exit code kills the script.
# =============================================================================

@test "partial-select: selecting only the FIRST component works" {
    set -e
    declare -A selected
    for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=false; done
    selected["${COMPONENT_LIST[0]}"]=true

    INSTALL_MODES=()
    for id in "${COMPONENT_LIST[@]}"; do
        if ${selected[$id]}; then INSTALL_MODES+=("$id"); fi
    done
    [ ${#INSTALL_MODES[@]} -eq 1 ]
}

@test "partial-select: selecting only the LAST component works" {
    set -e
    declare -A selected
    for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=false; done
    local last_idx=$(( ${#COMPONENT_LIST[@]} - 1 ))
    selected["${COMPONENT_LIST[$last_idx]}"]=true

    INSTALL_MODES=()
    for id in "${COMPONENT_LIST[@]}"; do
        if ${selected[$id]}; then INSTALL_MODES+=("$id"); fi
    done
    [ ${#INSTALL_MODES[@]} -eq 1 ]
}

@test "partial-select: selecting only a MIDDLE component works" {
    set -e
    declare -A selected
    for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=false; done
    local mid_idx=$(( ${#COMPONENT_LIST[@]} / 2 ))
    selected["${COMPONENT_LIST[$mid_idx]}"]=true

    INSTALL_MODES=()
    for id in "${COMPONENT_LIST[@]}"; do
        if ${selected[$id]}; then INSTALL_MODES+=("$id"); fi
    done
    [ ${#INSTALL_MODES[@]} -eq 1 ]
}

@test "partial-select: selecting NONE results in empty INSTALL_MODES" {
    set -e
    declare -A selected
    for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=false; done

    INSTALL_MODES=()
    for id in "${COMPONENT_LIST[@]}"; do
        if ${selected[$id]}; then INSTALL_MODES+=("$id"); fi
    done
    [ ${#INSTALL_MODES[@]} -eq 0 ]
}

@test "partial-select: each component individually selectable and executable in dry-run" {
    DRY_RUN=true
    set -e
    for target_id in "${COMPONENT_LIST[@]}"; do
        # Simulate selecting only this one component
        declare -A selected
        for id in "${COMPONENT_LIST[@]}"; do selected["$id"]=false; done
        selected["$target_id"]=true

        INSTALL_MODES=()
        for id in "${COMPONENT_LIST[@]}"; do
            if ${selected[$id]}; then INSTALL_MODES+=("$id"); fi
        done

        [ ${#INSTALL_MODES[@]} -eq 1 ] || {
            echo "Selection failed for $target_id: got ${#INSTALL_MODES[@]} items"
            return 1
        }

        # Execute the selected component
        for func in ${COMPONENT_FUNCS[$target_id]}; do
            capture "$func"
            [ "$_status" -eq 0 ] || {
                echo "FAILED: $func (component $target_id): $_output"
                return 1
            }
        done
    done
}

# =============================================================================
# set -e safety: scan for dangerous patterns in provisioning scripts.
# The && pattern as the last statement in a loop body is a silent killer.
# =============================================================================

@test "set-e-safety: no bare '&& ARRAY+=' patterns in provision script" {
    # Pattern: `something && ARRAY+=(...)`  as standalone statement is unsafe
    # under set -e when it's the last command in a loop body.
    ! grep -P '\$\{.*\} && \w+\+=' "$STRIX_DIR/provision_strix_halo.sh"
}

@test "set-e-safety: no '&& expr' as last statement before done" {
    # A `false && something` as the LAST statement in a for/while loop body
    # causes set -e to kill the script. Safe when other statements follow.
    # We check: line with `&& ` immediately followed by `done` (ignoring blanks/comments).
    for f in "$STRIX_DIR"/components/*.sh "$STRIX_DIR/provision_strix_halo.sh"; do
        # Use awk: flag when a line contains && and the next non-blank/comment line is 'done'
        local bad
        bad=$(awk '
            /&&/ && !/^[[:space:]]*#/ { pending = NR; line = $0 }
            /^[[:space:]]*done/ && pending > 0 { print FILENAME ":" pending ": " line; pending = 0 }
            /^[[:space:]]*[^#[:space:]]/ && !/done/ { pending = 0 }
        ' "$f")
        if [ -n "$bad" ]; then
            echo "Unsafe && before done in $(basename "$f"):"
            echo "$bad"
            return 1
        fi
    done
}

# =============================================================================
# File reference integrity: every cp SOURCE in components exists in the repo.
# Catches "scripts/ dir not synced" and similar missing-file deployment issues.
# =============================================================================

@test "file-integrity: every cp source referencing INFRA_DIR exists" {
    local fail=0
    for f in "$STRIX_DIR"/components/*.sh; do
        # Extract paths like ${INFRA_DIR}/systemd/foo.service or ${INFRA_DIR}/scripts/bar.sh
        # Only match cp commands (the source file argument)
        grep -oP 'cp\s+\$\{?INFRA_DIR\}?/\S+' "$f" | \
            sed 's/^cp\s*//' | \
            while read -r ref; do
                # Resolve: replace ${INFRA_DIR} or $INFRA_DIR with actual path
                local resolved="${ref//\$\{INFRA_DIR\}/$STRIX_DIR}"
                resolved="${resolved//\$INFRA_DIR/$STRIX_DIR}"
                [ -e "$resolved" ] || {
                    echo "Missing file referenced in $(basename "$f"): $ref → $resolved"
                    exit 1
                }
            done || fail=1
    done
    [ "$fail" -eq 0 ]
}

@test "file-integrity: scripts/ directory exists" {
    [ -d "$STRIX_DIR/scripts" ]
}

@test "file-integrity: sync-llama-models.sh exists in scripts/" {
    [ -f "$STRIX_DIR/scripts/sync-llama-models.sh" ]
    [ -x "$STRIX_DIR/scripts/sync-llama-models.sh" ]
}

# =============================================================================
# Component isolation: each component can be sourced + executed independently
# without depending on another component having run first.
# =============================================================================

@test "isolation: each component sources independently without errors" {
    for f in "$STRIX_DIR"/components/*.sh; do
        # Fresh state for each component
        COMPONENT_LIST=()
        declare -A COMPONENT_FUNCS=()
        declare -A COMPONENT_NAMES=()

        source "$f"
        [ ${#COMPONENT_LIST[@]} -ge 1 ] || {
            echo "Component $(basename "$f") registered nothing"
            return 1
        }
    done
}

@test "isolation: each component runs in dry-run after standalone sourcing" {
    DRY_RUN=true
    for f in "$STRIX_DIR"/components/*.sh; do
        COMPONENT_LIST=()
        declare -A COMPONENT_FUNCS=()
        declare -A COMPONENT_NAMES=()

        source "$f"
        for id in "${COMPONENT_LIST[@]}"; do
            for func in ${COMPONENT_FUNCS[$id]}; do
                capture "$func"
                [ "$_status" -eq 0 ] || {
                    echo "FAILED (isolated): $func from $(basename "$f"): $_output"
                    return 1
                }
            done
        done
    done
}

# =============================================================================
# Service ↔ component consistency: every service that a component enables
# is also copied by that same component (not left to another component).
# =============================================================================

@test "consistency: components that enable a custom service also deploy its unit file" {
    local fail=0
    for f in "$STRIX_DIR"/components/*.sh; do
        local content
        content=$(cat "$f")
        # Find all "systemctl enable <name>" calls
        echo "$content" | grep -oP 'systemctl.*enable\s+\K\S+' | while read -r svc; do
            # Skip system packages (xrdp, docker, etc.) — only check services we own
            [ -f "$STRIX_DIR/systemd/${svc}.service" ] || continue
            echo "$content" | grep -q "cp.*${svc}.service" || {
                echo "$(basename "$f") enables '$svc' but doesn't deploy ${svc}.service"
                exit 1
            }
        done || fail=1
    done
    [ "$fail" -eq 0 ]
}

@test "consistency: every systemd service file has valid [Unit], [Service], [Install]" {
    for f in "$STRIX_DIR"/systemd/*.service; do
        local name
        name=$(basename "$f")
        grep -q '^\[Unit\]' "$f"     || { echo "$name: missing [Unit]"; return 1; }
        grep -q '^\[Service\]' "$f"  || { echo "$name: missing [Service]"; return 1; }
        grep -q '^\[Install\]' "$f"  || { echo "$name: missing [Install]"; return 1; }
        grep -q '^Description=' "$f" || { echo "$name: missing Description"; return 1; }
        grep -q '^ExecStart=' "$f" || grep -q '^ExecStartPre=' "$f" || {
            echo "$name: missing ExecStart/ExecStartPre"
            return 1
        }
    done
}

# =============================================================================
# --only flag: verify that every registered component ID works with --only.
# =============================================================================

@test "only-flag: every component ID is valid for --only selection" {
    for id in "${COMPONENT_LIST[@]}"; do
        [[ -n "${COMPONENT_NAMES[$id]+x}" ]] || {
            echo "Component $id has no name registered"
            return 1
        }
        [[ -n "${COMPONENT_FUNCS[$id]+x}" ]] || {
            echo "Component $id has no functions registered"
            return 1
        }
    done
}

@test "only-flag: is_installed function handles all registered component IDs" {
    # The real is_installed (not the test mock) should have a case for every ID.
    # We check the source file directly.
    for id in "${COMPONENT_LIST[@]}"; do
        grep -q "${id})" "$STRIX_DIR/provision_strix_halo.sh" || {
            echo "is_installed() missing case for: $id"
            return 1
        }
    done
}
