#!/usr/bin/env bats
# Tests for systemd service unit files.

load helpers/test_helper

SYSTEMD_DIR="$STRIX_DIR/systemd"

# --- File existence ---

@test "systemd: llmster.service exists" {
    [ -f "$SYSTEMD_DIR/llmster.service" ]
}

@test "systemd: comfyui.service exists" {
    [ -f "$SYSTEMD_DIR/comfyui.service" ]
}

@test "systemd: openclaw.service exists" {
    [ -f "$SYSTEMD_DIR/openclaw.service" ]
}

@test "systemd: hosting.service exists" {
    [ -f "$SYSTEMD_DIR/hosting.service" ]
}

@test "systemd: cisco-defense.service exists" {
    [ -f "$SYSTEMD_DIR/cisco-defense.service" ]
}

@test "systemd: ace-step.service exists" {
    [ -f "$SYSTEMD_DIR/ace-step.service" ]
}

@test "systemd: exactly 6 service units exist" {
    local count
    count=$(ls "$SYSTEMD_DIR"/*.service 2>/dev/null | wc -l)
    [ "$count" -eq 6 ]
}

# --- Required sections ---

@test "systemd: all units have [Unit] section" {
    for f in "$SYSTEMD_DIR"/*.service; do
        grep -q '^\[Unit\]' "$f" || { echo "Missing [Unit] in $(basename "$f")"; return 1; }
    done
}

@test "systemd: all units have [Service] section" {
    for f in "$SYSTEMD_DIR"/*.service; do
        grep -q '^\[Service\]' "$f" || { echo "Missing [Service] in $(basename "$f")"; return 1; }
    done
}

@test "systemd: all units have [Install] section" {
    for f in "$SYSTEMD_DIR"/*.service; do
        grep -q '^\[Install\]' "$f" || { echo "Missing [Install] in $(basename "$f")"; return 1; }
    done
}

@test "systemd: all units have Description" {
    for f in "$SYSTEMD_DIR"/*.service; do
        grep -q '^Description=' "$f" || { echo "Missing Description in $(basename "$f")"; return 1; }
    done
}

@test "systemd: all units want multi-user.target" {
    for f in "$SYSTEMD_DIR"/*.service; do
        grep -q 'WantedBy=multi-user.target' "$f" || { echo "Missing WantedBy in $(basename "$f")"; return 1; }
    done
}

# --- HSA Override ---

@test "systemd: llmster.service has HSA_OVERRIDE_GFX_VERSION=11.5.1" {
    grep -q "HSA_OVERRIDE_GFX_VERSION=11.5.1" "$SYSTEMD_DIR/llmster.service"
}

@test "systemd: comfyui.service has HSA_OVERRIDE_GFX_VERSION=11.5.1" {
    grep -q "HSA_OVERRIDE_GFX_VERSION=11.5.1" "$SYSTEMD_DIR/comfyui.service"
}

@test "systemd: cisco-defense.service has HSA_OVERRIDE_GFX_VERSION=11.5.1" {
    grep -q "HSA_OVERRIDE_GFX_VERSION=11.5.1" "$SYSTEMD_DIR/cisco-defense.service"
}

# --- User assignments ---

@test "systemd: llmster.service runs as lmstudio user" {
    grep -q "^User=lmstudio" "$SYSTEMD_DIR/llmster.service"
}

@test "systemd: comfyui.service runs as comfyui user" {
    grep -q "^User=comfyui" "$SYSTEMD_DIR/comfyui.service"
}

@test "systemd: openclaw.service runs as claw user" {
    grep -q "^User=claw" "$SYSTEMD_DIR/openclaw.service"
}

@test "systemd: hosting.service runs as hosting user" {
    grep -q "^User=hosting" "$SYSTEMD_DIR/hosting.service"
}

@test "systemd: cisco-defense.service runs as defense user" {
    grep -q "^User=defense" "$SYSTEMD_DIR/cisco-defense.service"
}

# --- Service types ---

@test "systemd: openclaw.service is type oneshot" {
    grep -q "^Type=oneshot" "$SYSTEMD_DIR/openclaw.service"
}

@test "systemd: hosting.service is type oneshot" {
    grep -q "^Type=oneshot" "$SYSTEMD_DIR/hosting.service"
}

@test "systemd: oneshot services have RemainAfterExit=yes" {
    for f in "$SYSTEMD_DIR/openclaw.service" "$SYSTEMD_DIR/hosting.service"; do
        grep -q "RemainAfterExit=yes" "$f" || { echo "Missing RemainAfterExit in $(basename "$f")"; return 1; }
    done
}

# --- Docker dependencies ---

@test "systemd: openclaw.service requires docker.service" {
    grep -q "Requires=docker.service" "$SYSTEMD_DIR/openclaw.service"
}

@test "systemd: hosting.service requires docker.service" {
    grep -q "Requires=docker.service" "$SYSTEMD_DIR/hosting.service"
}

# --- Restart policies ---

@test "systemd: long-running services have Restart=always" {
    for f in "$SYSTEMD_DIR/llmster.service" "$SYSTEMD_DIR/comfyui.service" "$SYSTEMD_DIR/cisco-defense.service" "$SYSTEMD_DIR/ace-step.service"; do
        grep -q "^Restart=always" "$f" || { echo "Missing Restart=always in $(basename "$f")"; return 1; }
    done
}

@test "systemd: llmster.service has RestartSec=10" {
    grep -q "^RestartSec=10" "$SYSTEMD_DIR/llmster.service"
}

@test "systemd: cisco-defense.service has RestartSec=30" {
    grep -q "^RestartSec=30" "$SYSTEMD_DIR/cisco-defense.service"
}

# --- ExecStart paths ---

@test "systemd: llmster.service starts AppImage with --headless" {
    grep -q "ExecStart=.*/lm-studio.AppImage --headless" "$SYSTEMD_DIR/llmster.service"
}

@test "systemd: comfyui.service starts python3 main.py with --listen" {
    grep -q "ExecStart=.*/python3 main.py --listen" "$SYSTEMD_DIR/comfyui.service"
}

@test "systemd: openclaw.service uses docker compose up -d" {
    grep -q "docker compose.*up -d" "$SYSTEMD_DIR/openclaw.service"
}

@test "systemd: openclaw.service has ExecStop for docker compose down" {
    grep -q "ExecStop=.*docker compose.*down" "$SYSTEMD_DIR/openclaw.service"
}

@test "systemd: cisco-defense.service starts the python daemon" {
    grep -q "ExecStart=.*/python3 /home/defense/cisco-defense-daemon.py" "$SYSTEMD_DIR/cisco-defense.service"
}

# --- PYTORCH_ALLOC_CONF ---

@test "systemd: GPU services have PYTORCH_ALLOC_CONF" {
    for f in "$SYSTEMD_DIR/llmster.service" "$SYSTEMD_DIR/comfyui.service" "$SYSTEMD_DIR/ace-step.service"; do
        grep -q "PYTORCH_ALLOC_CONF=expandable_segments:True" "$f" || {
            echo "Missing PYTORCH_ALLOC_CONF in $(basename "$f")"
            return 1
        }
    done
}

# --- WorkingDirectory ---

@test "systemd: comfyui.service WorkingDirectory is correct" {
    grep -q "^WorkingDirectory=/home/comfyui/ComfyUI" "$SYSTEMD_DIR/comfyui.service"
}

@test "systemd: openclaw.service WorkingDirectory is /home/claw" {
    grep -q "^WorkingDirectory=/home/claw" "$SYSTEMD_DIR/openclaw.service"
}

# --- ACE Step service ---

@test "systemd: ace-step.service runs as comfyui user" {
    grep -q "^User=comfyui" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service uses venv_rocm python" {
    grep -q "venv_rocm/bin/python" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service uses --backend pt (forces PyTorch, avoids triton)" {
    grep -q "\-\-backend pt" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service sets ACESTEP_LM_BACKEND=pt" {
    grep -q "ACESTEP_LM_BACKEND=pt" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service disables torch.compile (TORCH_COMPILE_BACKEND=eager)" {
    grep -q "TORCH_COMPILE_BACKEND=eager" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service has HSA_OVERRIDE_GFX_VERSION=11.5.1" {
    grep -q "HSA_OVERRIDE_GFX_VERSION=11.5.1" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service has MIOPEN_FIND_MODE=FAST" {
    grep -q "MIOPEN_FIND_MODE=FAST" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service WorkingDirectory is ACE-Step-1.5" {
    grep -q "^WorkingDirectory=/home/comfyui/ACE-Step-1.5" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service listens on port 7860" {
    grep -q "\-\-port 7860" "$SYSTEMD_DIR/ace-step.service"
}

@test "systemd: ace-step.service enables cpu_offload" {
    grep -q "\-\-cpu_offload true" "$SYSTEMD_DIR/ace-step.service"
}
