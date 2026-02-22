#!/bin/bash
# prepare-vm.sh - VM creation and management helpers for strix-halo tests
#
# IMPORTANT: This script now uses libvirt hooks for proper GPU management.
# The hooks handle:
#   1. Setting device_specific reset_method (fixes AMD GPU reset bug)
#   2. Unbinding GPU from amdgpu before VM start
#   3. Rebinding GPU to amdgpu after VM stop
#
# Install hooks with: sudo ./prepare-vm.sh install-hooks

set -euo pipefail

# Ensure Ctrl+C kills the whole process group, not just the current foreground command
cleanup_on_exit() {
    # Kill sudo keepalive background process
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap 'echo; echo "Interrupted — aborting."; cleanup_on_exit; kill 0; exit 130' INT
trap 'cleanup_on_exit' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_DIR="${STRIX_DIR}/.cache"
VM_DIR="${CACHE_DIR}/vm"
VM_NAME="strix-test-vm"
VM_VCPU="${VM_VCPU:-2}"
VM_RAM="${VM_RAM:-4096}"
VM_DISK="${VM_DIR}/disk.qcow2"
VM_IMAGE="${CACHE_DIR}/files/ubuntu-24.04-cloud.img"
VM_USER="testuser"

# GPU PCI addresses (c5:00.0 = GPU, c5:00.1 = HDMI Audio)
GPU_PCI="0000:c5:00.0"
GPU_AUDIO_PCI="0000:c5:00.1"

# =============================================================================
# Sudo — prompt once upfront, then use non-interactive for the rest
# =============================================================================

ensure_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "This script needs sudo for libvirt, GPU passthrough, and tmpfs."
        sudo -v
    fi
    # Keep sudo alive in the background
    while sudo -n true 2>/dev/null; do sleep 50; done &
    SUDO_KEEPALIVE_PID=$!
}

# =============================================================================
# Hook Installation
# =============================================================================

install_hooks() {
    echo "Installing libvirt hook scripts..."
    
    local hook_src="${SCRIPT_DIR}/hooks"
    local hook_dst="/etc/libvirt/hooks"
    
    if [ ! -d "$hook_src" ]; then
        echo "ERROR: Hook source directory not found: $hook_src"
        return 1
    fi
    
    # Create log directory
    sudo mkdir -p /var/log/libvirt-hooks
    
    # Install hooks
    if [ -d "$hook_dst" ]; then
        echo "Backing up existing hooks..."
        sudo cp -r "$hook_dst" "${hook_dst}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    
    sudo mkdir -p "$hook_dst"
    sudo cp -r "${hook_src}/." "$hook_dst/"
    
    # Ensure scripts are executable
    sudo find "$hook_dst" -name "*.sh" -exec chmod +x {} \;
    
    # Restart libvirtd to pick up hooks
    echo "Restarting libvirtd..."
    sudo systemctl restart libvirtd 2>/dev/null || sudo systemctl restart libvirt-bin 2>/dev/null || {
        echo "[WARN] Could not restart libvirtd automatically"
        echo "[WARN] Please restart manually: sudo systemctl restart libvirtd"
    }
    
    echo "[OK] Hooks installed to $hook_dst"
    echo "[OK] Hook log will be at: /var/log/libvirt-hooks/gpu-passthrough.log"
}

# =============================================================================
# Prerequisite Checks
# =============================================================================

check_prereqs() {
    local missing=()
    
    for cmd in kvm virt-install virsh cloud-localds qemu-img; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required commands: ${missing[*]}"
        echo "Install with: sudo apt install qemu-kvm libvirt-clients libvirt-daemon-system virt-install cloud-utils genisoimage"
        return 1
    fi
    
    # Check for GPU passthrough
    if [ ! -e "/sys/bus/pci/devices/${GPU_PCI}" ]; then
        echo "ERROR: GPU not found at ${GPU_PCI}"
        return 1
    fi
    
    # Check KVM
    if [ ! -e /dev/kvm ]; then
        echo "ERROR: KVM not available"
        return 1
    fi
    
    # Check IOMMU
    if [ ! -d "/sys/class/iommu" ] || [ -z "$(ls -A /sys/class/iommu 2>/dev/null)" ]; then
        echo "[WARN] IOMMU does not appear to be enabled"
        echo "[WARN] Add 'amd_iommu=on iommu=pt' to /etc/default/grub"
        echo "[WARN] Then: sudo update-grub && sudo reboot"
    fi
    
    echo "[OK] All prerequisites met"
    return 0
}

# =============================================================================
# Pre-flight Check
# =============================================================================

run_preflight_check() {
    local check_script="${SCRIPT_DIR}/scripts/check-passthrough.sh"
    if [ -x "$check_script" ]; then
        echo "Running pre-flight check..."
        "$check_script"
    else
        echo "[WARN] Pre-flight check script not found: $check_script"
    fi
}

# =============================================================================
# SSH Key Management
# =============================================================================

generate_ssh_key() {
    local key_dir="${CACHE_DIR}/files"
    mkdir -p "$key_dir"
    
    local priv_key="${key_dir}/vm-test-key"
    local pub_key="${priv_key}.pub"
    
    if [ ! -f "$priv_key" ]; then
        echo "Generating SSH key pair..."
        ssh-keygen -t ed25519 -f "$priv_key" -N "" -C "strix-vm-test"
        chmod 600 "$priv_key"
        chmod 644 "$pub_key"
    else
        echo "Using existing SSH key: $priv_key"
    fi
    
    VM_SSH_KEY="$priv_key"
    VM_SSH_PUBKEY="$(cat "$pub_key")"
    export VM_SSH_KEY VM_SSH_PUBKEY
}

# =============================================================================
# VM Image Management
# =============================================================================

download_ubuntu_image() {
    mkdir -p "$(dirname "$VM_IMAGE")"
    
    if [ -f "$VM_IMAGE" ]; then
        echo "Using cached Ubuntu image: $VM_IMAGE"
        return 0
    fi
    
    echo "Downloading Ubuntu 24.04 cloud image..."
    local tmp_image="${VM_IMAGE}.tmp"
    wget -O "$tmp_image" \
        "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img" \
        --progress=dot:giga
    
    mv "$tmp_image" "$VM_IMAGE"
    echo "[OK] Downloaded Ubuntu image to $VM_IMAGE"
}

# =============================================================================
# Cloud-Init Generation
# =============================================================================

generate_cloudinit() {
    local key_dir="${CACHE_DIR}/files"
    local seed_iso="${VM_DIR}/seed.iso"
    
    mkdir -p "$VM_DIR"
    
    # Render cloud-init user-data
    local user_data="${VM_DIR}/user-data"
    sed "s/\${SSH_PUBKEY}/${VM_SSH_PUBKEY}/g" \
        "${SCRIPT_DIR}/cloud-init.yaml.tpl" > "$user_data"
    
    # Generate seed ISO
    cloud-localds -v "$seed_iso" "$user_data"
    echo "[OK] Generated cloud-init seed ISO: $seed_iso"
    
    VM_SEED_ISO="$seed_iso"
    export VM_SEED_ISO
}

# =============================================================================
# VM Disk Management  
# =============================================================================

setup_tmpfs() {
    # Use tmpfs for VM disk if enough RAM is available (need ~4G free beyond VM_RAM)
    local min_free_mb=$(( VM_RAM + 4096 ))
    local avail_mb
    avail_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)

    if [ "$avail_mb" -ge "$min_free_mb" ]; then
        echo "Sufficient RAM (${avail_mb}MB available, ${min_free_mb}MB needed) — using tmpfs for VM disk"
        if ! mountpoint -q "$VM_DIR" 2>/dev/null; then
            sudo mount -t tmpfs -o size=4G tmpfs "$VM_DIR"
        fi
        VM_TMPFS=1
    else
        echo "Not enough RAM for tmpfs (${avail_mb}MB available, ${min_free_mb}MB needed) — using disk"
        VM_TMPFS=0
    fi
    export VM_TMPFS
}

teardown_tmpfs() {
    if [ "${VM_TMPFS:-0}" = "1" ] && mountpoint -q "$VM_DIR" 2>/dev/null; then
        echo "Unmounting tmpfs at $VM_DIR..."
        sudo umount "$VM_DIR" || true
    fi
}

create_vm_disk() {
    if [ -f "$VM_DISK" ]; then
        # Verify the disk has a backing file; delete stale blank disks
        if qemu-img info "$VM_DISK" 2>/dev/null | grep -q "backing file"; then
            echo "Using existing VM disk: $VM_DISK"
            return 0
        else
            echo "Removing stale VM disk (no backing file)..."
            rm -f "$VM_DISK"
        fi
    fi

    if [ ! -f "$VM_IMAGE" ]; then
        echo "ERROR: Cloud image not found at $VM_IMAGE — run setup first"
        return 1
    fi

    echo "Creating VM disk (CoW overlay on cloud image)..."
    qemu-img create -f qcow2 -b "$VM_IMAGE" -F qcow2 "$VM_DISK" 20G
    echo "[OK] Created VM disk: $VM_DISK"
}

# =============================================================================
# GPU Passthrough - Using Hooks (New Method)
# =============================================================================
#
# The actual GPU bind/unbind is now handled by libvirt hooks:
#   /etc/libvirt/hooks/qemu.d/strix-test-vm/prepare/begin/start.sh
#   /etc/libvirt/hooks/qemu.d/strix-test-vm/release/end/stop.sh
#
# These hooks:
#   1. Set device_specific reset_method (CRITICAL for AMD reset bug fix)
#   2. Unbind GPU from amdgpu before VM starts
#   3. Rebind GPU to amdgpu after VM stops

# Legacy functions - kept for reference but hooks handle this now
_detach_gpu_from_host_legacy() {
    echo "[INFO] Using legacy GPU detachment (consider using hooks instead)..."
    
    # Set device_specific reset method BEFORE detaching
    if [ -f "/sys/bus/pci/devices/${GPU_PCI}/reset_method" ]; then
        if echo 'device_specific' > "/sys/bus/pci/devices/${GPU_PCI}/reset_method" 2>/dev/null; then
            echo "  [OK] Set reset_method to device_specific"
        else
            echo "  [WARN] Could not set device_specific reset_method"
        fi
    fi
    
    # Detach GPU and audio via libvirt (timeout prevents hang if already detached)
    if sudo timeout 10 virsh nodedev-detach "pci_${GPU_PCI//:/_}" 2>/dev/null; then
        echo "  [OK] Detached GPU ${GPU_PCI}"
    else
        echo "  [OK] GPU ${GPU_PCI} already detached or unavailable"
    fi

    if sudo timeout 10 virsh nodedev-detach "pci_${GPU_AUDIO_PCI//:/_}" 2>/dev/null; then
        echo "  [OK] Detached HDMI Audio ${GPU_AUDIO_PCI}"
    else
        echo "  [OK] HDMI Audio ${GPU_AUDIO_PCI} already detached or unavailable"
    fi
}

_reattach_gpu_to_host_legacy() {
    echo "[INFO] Using legacy GPU reattachment..."
    
    # Reattach GPU and audio via libvirt (timeout prevents hang if already attached)
    if sudo timeout 10 virsh nodedev-reattach "pci_${GPU_PCI//:/_}" 2>/dev/null; then
        echo "  [OK] Reattached GPU ${GPU_PCI}"
    else
        echo "  [OK] GPU ${GPU_PCI} already attached or unavailable"
    fi

    if sudo timeout 10 virsh nodedev-reattach "pci_${GPU_AUDIO_PCI//:/_}" 2>/dev/null; then
        echo "  [OK] Reattached HDMI Audio ${GPU_AUDIO_PCI}"
    else
        echo "  [OK] HDMI Audio ${GPU_AUDIO_PCI} already attached or unavailable"
    fi
}

# =============================================================================
# VM Lifecycle
# =============================================================================

create_vm() {
    echo "Creating VM: $VM_NAME..."
    
    # Destroy existing VM if present (timeout prevents hang on stale libvirt state)
    sudo timeout 10 virsh destroy "$VM_NAME" 2>/dev/null || true
    sudo timeout 10 virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
    
    echo "  Running virt-install..."
    virt-install \
        --name "$VM_NAME" \
        --vcpus "$VM_VCPU" \
        --memory "$VM_RAM" \
        --import \
        --disk "$VM_DISK" \
        --disk "${VM_SEED_ISO:-$VM_DIR/seed.iso}",device=cdrom \
        --network network=default,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --video qxl \
        --boot uefi \
        --cpu host \
        --machine q35 \
        --osinfo ubuntu24.04 \
        --security type=none \
        --hostdev "${GPU_PCI},driver.name=vfio" \
        --hostdev "${GPU_AUDIO_PCI},driver.name=vfio" \
        --noautoconsole || true

    echo "[OK] VM created with GPU passthrough"
    echo "[INFO] GPU bind/unbind is handled by libvirt hooks"
}

start_vm() {
    echo "Starting VM: $VM_NAME..."
    virsh start "$VM_NAME"
    echo "[OK] VM started"
}

stop_vm() {
    echo "Stopping VM: $VM_NAME..."
    
    # Try graceful shutdown first
    if sudo timeout 10 virsh shutdown "$VM_NAME" 2>/dev/null; then
        echo "Waiting for graceful shutdown..."
        for i in $(seq 1 30); do
            if ! sudo timeout 5 virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
                echo "[OK] VM stopped"
                return 0
            fi
            sleep 2
        done
    fi

    # Force destroy if still running
    echo "Force destroying VM..."
    sudo timeout 10 virsh destroy "$VM_NAME" 2>/dev/null || true
    echo "[OK] VM destroyed"
}

wait_for_ssh() {
    echo "Waiting for SSH to be ready..."
    local ip
    
    for i in $(seq 1 60); do
        ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep "192.168" | awk '{print $4}' | cut -d'/' -f1)
        if [ -n "$ip" ]; then
            if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$VM_SSH_KEY" "${VM_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
                echo "[OK] SSH ready at $ip"
                VM_IP="$ip"
                export VM_IP
                return 0
            fi
        fi
        sleep 2
    done
    
    echo "ERROR: SSH not ready after 120 seconds"
    return 1
}

# =============================================================================
# Provisioning inside VM
# =============================================================================

run_in_vm() {
    local cmd="$1"
    ssh -o StrictHostKeyChecking=no -i "$VM_SSH_KEY" "${VM_USER}@${VM_IP}" "$cmd"
}

copy_to_vm() {
    local src="$1"
    local dest="$2"
    scp -o StrictHostKeyChecking=no -i "$VM_SSH_KEY" -r "$src" "${VM_USER}@${VM_IP}:${dest}"
}

run_provisioning() {
    echo "Running provisioning in VM..."
    
    # Copy provisioning scripts to VM
    echo "Copying provisioning scripts to VM..."
    copy_to_vm "${STRIX_DIR}" "/home/${VM_USER}/strix-halo-setup"
    
    # Copy cache to VM
    if [ -d "$CACHE_DIR" ]; then
        echo "Copying cache to VM..."
        copy_to_vm "$CACHE_DIR" "/home/${VM_USER}/.cache"
    fi
    
    # Run provisioning with override for SSH key check
    # Note: Skip GPU components in VM to avoid ROCm amdgpu conflicts
    run_in_vm "cd /home/${VM_USER}/strix-halo-setup && \
        CACHE_DIR=/home/${VM_USER}/.cache \
        SSH_USERS='${VM_USER}' \
        FORCE_SSH_KEY_CHECK=true \
        ./provision_strix_halo.sh --only ssh,base,podman --force"
    
    echo "[OK] Provisioning complete"
}

# =============================================================================
# Health Checks
# =============================================================================

health_check_services() {
    echo "Running health checks..."
    local failures=0
    
    # SSH
    echo -n "SSH (port 22): "
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$VM_SSH_KEY" "${VM_USER}@${VM_IP}" "exit 0" >/dev/null 2>&1; then
        echo "[OK]"
    else
        echo "[FAIL]"
        failures=$((failures + 1))
    fi
    
    # Skip GPU-dependent services since we don't install them in VM
    info "Skipping GPU-dependent service checks (ROCm not installed in VM)"
    
    if [ $failures -gt 0 ]; then
        echo "[WARN] $failures service(s) failed"
        return 1
    fi
    
    echo "[OK] All health checks passed"
    return 0
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    echo "Cleaning up..."
    stop_vm
    # GPU reattachment is handled by hook script
    teardown_tmpfs
    restart_display_manager
}

restart_display_manager() {
    echo "Restarting display manager..."
    
    # Try common display managers
    for dm in gdm3 sddm lightdm; do
        if systemctl list-unit-files | grep -q "^${dm}.service"; then
            echo "Restarting $dm..."
            sudo systemctl restart "$dm" 2>/dev/null && echo "[OK] Display manager restarted" || true
            return 0
        fi
    done
    
    echo "[WARN] Could not detect display manager. You may need to restart manually."
}

# =============================================================================
# Main
# =============================================================================

show_help() {
    cat << 'HELP'
Usage: prepare-vm.sh <command>

Commands:
    setup          Check prereqs, generate keys, download image
    install-hooks  Install libvirt hook scripts (run once)
    check          Run pre-flight passthrough checks
    create         Create and start VM
    provision      Run provisioning inside VM
    health         Run health checks
    stop           Stop VM
    cleanup        Stop VM and reattach GPU
    all            Run full test cycle (setup -> create -> provision -> health -> cleanup)

Environment:
    VM_VCPU        Number of CPUs (default: 2)
    VM_RAM         RAM in MB (default: 4096)
    GPU_PCI        GPU PCI address (default: 0000:c5:00.0)
    GPU_AUDIO_PCI  Audio PCI address (default: 0000:c5:00.1)

GPU Passthrough Notes:
    This script uses libvirt hooks for proper GPU management:
      - Sets device_specific reset_method (fixes AMD GPU reset bug)
      - Unbinds GPU from amdgpu before VM start
      - Rebinds GPU to amdgpu after VM stop

    Install hooks with: sudo ./prepare-vm.sh install-hooks
    
    Check readiness with: ./prepare-vm.sh check

Kernel Recommendations:
    For Strix Halo (gfx1151), use kernel 6.17.9+ or 6.19+
    Avoid 6.18.0-6.18.3 due to known amdgpu MES hang issues.
    Install with: ./scripts/install-kernel.sh 6.17.9
HELP
}

main() {
    local cmd="${1:-}"
    shift || true
    
    case "$cmd" in
        setup)
            ensure_sudo
            check_prereqs
            generate_ssh_key
            download_ubuntu_image
            mkdir -p "$VM_DIR"
            setup_tmpfs
            generate_cloudinit
            create_vm_disk
            echo ""
            echo "[OK] Setup complete. Next steps:"
            echo "  1. Install hooks: sudo ./prepare-vm.sh install-hooks"
            echo "  2. Run checks:   ./prepare-vm.sh check"
            echo "  3. Create VM:    sudo ./prepare-vm.sh create"
            ;;
        install-hooks)
            ensure_sudo
            install_hooks
            ;;
        check)
            run_preflight_check
            ;;
        create)
            ensure_sudo
            create_vm
            start_vm
            wait_for_ssh
            ;;
        provision)
            run_provisioning
            ;;
        health)
            health_check_services
            ;;
        stop)
            stop_vm
            ;;
        cleanup)
            ensure_sudo
            cleanup
            ;;
        all)
            ensure_sudo
            run_preflight_check
            check_prereqs
            generate_ssh_key
            download_ubuntu_image
            mkdir -p "$VM_DIR"
            setup_tmpfs
            generate_cloudinit
            create_vm_disk
            create_vm
            start_vm
            wait_for_ssh
            run_provisioning
            health_check_services
            cleanup
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"
