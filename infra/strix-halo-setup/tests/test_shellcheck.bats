#!/usr/bin/env bats
# Static analysis: shellcheck on all shell scripts.

load helpers/test_helper

STRIX="$STRIX_DIR"

@test "shellcheck: provision_strix_halo.sh passes (excluding known bugs)" {
    # SC2066: glob inside double quotes (known bug on line 118, tested in test_force_mode.bats)
    # SC2162: read without -r (cosmetic; backslash mangling irrelevant for confirmation prompts)
    run shellcheck -s bash -e SC2086,SC2034,SC2155,SC2046,SC2044,SC2066,SC2162 "$STRIX/provision_strix_halo.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "shellcheck: 10-base.sh passes" {
    run shellcheck -s bash -e SC2086,SC2034,SC2155 "$STRIX/components/10-base.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "shellcheck: 20-llm-stack.sh passes" {
    run shellcheck -s bash -e SC2086,SC2034,SC2155 "$STRIX/components/20-llm-stack.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "shellcheck: 30-comfyui.sh passes" {
    run shellcheck -s bash -e SC2086,SC2034,SC2155 "$STRIX/components/30-comfyui.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "shellcheck: 40-zimage.sh passes" {
    run shellcheck -s bash -e SC2086,SC2034,SC2155 "$STRIX/components/40-zimage.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "shellcheck: 50-ace-step.sh passes" {
    run shellcheck -s bash -e SC2086,SC2034,SC2155 "$STRIX/components/50-ace-step.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "shellcheck: 60-security.sh passes" {
    run shellcheck -s bash -e SC2086,SC2034,SC2155 "$STRIX/components/60-security.sh"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "all shell scripts have bash shebang" {
    for f in "$STRIX/provision_strix_halo.sh" "$STRIX"/components/*.sh; do
        head -1 "$f" | grep -q "#!/bin/bash" || {
            echo "Missing bash shebang in: $f"
            return 1
        }
    done
}

@test "no shell scripts contain CRLF line endings" {
    for f in "$STRIX/provision_strix_halo.sh" "$STRIX"/components/*.sh; do
        if grep -Prl '\r$' "$f" 2>/dev/null; then
            echo "CRLF line endings detected in: $f"
            return 1
        fi
    done
}
