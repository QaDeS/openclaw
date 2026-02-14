#!/usr/bin/env bats
# test_vm_e2e.bats - End-to-end health checks for VM provisioning
#
# These tests verify that services respond correctly after provisioning.
# Run with: ./run-tests.sh --vm health

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIX_DIR="$(cd "$TESTS_DIR/.." && pwd)"

setup() {
    # Skip if not in VM mode (check for cloud-init or specific VM markers)
    if [ ! -f /var/lib/cloud/instance/boot-finished ] && [ "$(hostname)" != "strix-test-vm" ]; then
        skip "Not running in VM - these tests are for VM provisioning only"
    fi
}

# =============================================================================
# SSH Service
# =============================================================================

@test "vm-e2e: SSH service is running" {
    if ! command -v sshd >/dev/null 2>&1; then
        skip "SSH not installed"
    fi
    
    # Check SSH is running
    pgrep -x sshd >/dev/null || return 1
}

@test "vm-e2e: SSH responds on port 22" {
    if ! command -v nc >/dev/null 2>&1; then
        skip "netcat not installed"
    fi
    
    nc -z localhost 22 || return 1
}

# =============================================================================
# Base Services (if installed)
# =============================================================================

@test "vm-e2e: XRDP responds on port 3389" {
    if ! command -v nc >/dev/null 2>&1; then
        skip "netcat not installed"
    fi
    
    # Check if xrdp is installed and running
    if ! systemctl is-enabled xrdp >/dev/null 2>&1; then
        skip "xrdp not enabled"
    fi
    
    nc -z localhost 3389 || return 1
}

# =============================================================================
# LLM Services
# =============================================================================

@test "vm-e2e: LM Studio API responds" {
    if ! curl -sf --max-time 5 http://localhost:1234/v1/models >/dev/null 2>&1; then
        # Check if lmstudio service exists
        if systemctl is-enabled lmstudio >/dev/null 2>&1; then
            return 1
        fi
        skip "LM Studio not installed or not enabled"
    fi
}

@test "vm-e2e: llama.cpp API responds" {
    if ! curl -sf --max-time 5 http://localhost:11234/v1/models >/dev/null 2>&1; then
        # Check if llamacpp service exists
        if systemctl is-enabled llamacpp >/dev/null 2>&1; then
            return 1
        fi
        skip "llama.cpp not installed or not enabled"
    fi
}

@test "vm-e2e: ComfyUI responds" {
    if ! curl -sf --max-time 5 http://localhost:8188/system_stats >/dev/null 2>&1; then
        # Check if comfyui service exists
        if systemctl is-enabled comfyui >/dev/null 2>&1; then
            return 1
        fi
        skip "ComfyUI not installed or not enabled"
    fi
}

@test "vm-e2e: ACE Step responds" {
    if ! curl -sf --max-time 5 http://localhost:7860 >/dev/null 2>&1; then
        # Check if ace-step service exists
        if systemctl is-enabled ace-step >/dev/null 2>&1; then
            return 1
        fi
        skip "ACE Step not installed or not enabled"
    fi
}

@test "vm-e2e: Z-Image responds" {
    # Z-Image doesn't have a web UI by default, check process instead
    if ! pgrep -f "python.*zimage" >/dev/null 2>&1; then
        skip "Z-Image not running"
    fi
}

# =============================================================================
# Hosting Services (Podman Quadlets)
# =============================================================================

@test "vm-e2e: WordPress responds" {
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:8080 2>&1 || echo "000")
    
    if [[ "$http_code" != "200" && "$http_code" != "302" && "$http_code" != "301" ]]; then
        # Check if wordpress container exists
        if podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q wordpress; then
            return 1
        fi
        skip "WordPress not installed"
    fi
}

@test "vm-e2e: Supabase responds" {
    if ! curl -sf --max-time 5 http://localhost:5432 >/dev/null 2>&1; then
        # Check if supabase container exists
        if podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q supabase; then
            return 1
        fi
        skip "Supabase not installed"
    fi
}

@test "vm-e2e: OpenClaw responds" {
    if ! curl -sf --max-time 5 http://localhost:18789/health >/dev/null 2>&1; then
        # Check if openclaw container exists
        if podman ps -a --format "{{.Names}}" 2>/dev/null | grep -q openclaw; then
            return 1
        fi
        skip "OpenClaw not installed"
    fi
}

# =============================================================================
# Security Services
# =============================================================================

@test "vm-e2e: fail2ban is running" {
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        skip "fail2ban not installed"
    fi
    
    pgrep -x fail2ban-server >/dev/null || return 1
}

@test "vm-e2e: UFW firewall is enabled" {
    if ! command -v ufw >/dev/null 2>&1; then
        skip "ufw not installed"
    fi
    
    ufw status | grep -q "Status: active" || return 1
}

# =============================================================================
# ROCm (if GPU passthrough is working)
# =============================================================================

@test "vm-e2e: ROCm is available" {
    if ! command -v rocminfo >/dev/null 2>&1; then
        skip "ROCm not installed"
    fi
    
    # Check for GPU
    rocminfo | grep -q "GPU" || return 1
}

@test "vm-e2e: ROCm HIP devices available" {
    if ! command -v hipconfig >/dev/null 2>&1; then
        skip "HIP not installed"
    fi
    
    hipconfig --platform | grep -q "linux" || return 1
}

# =============================================================================
# Cache Verification
# =============================================================================

@test "vm-e2e: cache directory is accessible" {
    if [ -d /host-cache ]; then
        [ -d /host-cache/.cache ] || [ -d /host-cache/files ] || [ -d /host-cache/scripts ]
    elif [ -d ~/.cache ]; then
        skip "Using home cache instead of mounted host cache"
    else
        skip "No cache directory found"
    fi
}

# =============================================================================
# System Resources
# =============================================================================

@test "vm-e2e: sufficient memory available" {
    local available_mb
    available_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
    
    # Should have at least 2GB available
    [ "$available_mb" -ge 2048 ] || {
        echo "Only ${available_mb}MB available"
        return 1
    }
}

@test "vm-e2e: disk space available" {
    local available_gb
    available_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    
    # Should have at least 10GB available
    [ "$available_gb" -ge 10 ] || {
        echo "Only ${available_gb}GB available"
        return 1
    }
}
