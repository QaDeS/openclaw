#!/bin/bash
# prepare-vm.sh - VM creation and management helpers for strix-halo tests

set -euo pipefail

# Ensure Ctrl+C kills the whole process group, not just the current foreground command
cleanup_on_exit() {
    # Kill sudo keepalive background process
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap 'echo; echo "Interrupted — aborting."; cleanup_on_exit; kill 0; exit 130' INT
trap 'cleanup_on_exit' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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
    
    echo "[OK] All prerequisites met"
    return 0
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
# GPU Passthrough - Detach from Host using virsh
# =============================================================================

detach_gpu_from_host() {
    echo "Detaching GPU from host (using virsh)..."
    
    # Detach GPU and audio via libvirt (timeout prevents hang if already detached)
    if sudo sudo timeout 10 virsh nodedev-detach pci_0000_c5_00_0 2>/dev/null; then
        echo "  [OK] Detached GPU c5:00.0"
    else
        echo "  [OK] GPU c5:00.0 already detached or unavailable"
    fi

    if sudo sudo timeout 10 virsh nodedev-detach pci_0000_c5_00_1 2>/dev/null; then
        echo "  [OK] Detached HDMI Audio c5:00.1"
    else
        echo "  [OK] HDMI Audio c5:00.1 already detached or unavailable"
    fi
    
    echo "[OK] GPU detached from host"
}

# =============================================================================
# GPU Passthrough - Reattach to Host using virsh
# =============================================================================

reattach_gpu_to_host() {
    echo "Re-attaching GPU to host (using virsh)..."
    
    # Reattach GPU and audio via libvirt (timeout prevents hang if already attached)
    if sudo sudo timeout 10 virsh nodedev-reattach pci_0000_c5_00_0 2>/dev/null; then
        echo "  [OK] Reattached GPU c5:00.0"
    else
        echo "  [OK] GPU c5:00.0 already attached or unavailable"
    fi

    if sudo sudo timeout 10 virsh nodedev-reattach pci_0000_c5_00_1 2>/dev/null; then
        echo "  [OK] Reattached HDMI Audio c5:00.1"
    else
        echo "  [OK] HDMI Audio c5:00.1 already attached or unavailable"
    fi
    
    echo "[OK] GPU re-attached to host"
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
        --noautoconsole || true

    echo "  Attaching GPU passthrough device..."
    # Define with GPU passthrough manually
    cat > /tmp/${VM_NAME}-gpu.xml << 'XML'
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0xc5' slot='0x00' function='0x0'/>
  </source>
</hostdev>
XML

    sudo timeout 10 virsh attach-device "$VM_NAME" /tmp/${VM_NAME}-gpu.xml --persistent 2>/dev/null || true

    echo "[OK] VM created"
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
    
    # Mount host cache into VM
    run_in_vm "sudo mkdir -p /host-cache"
    # Note: 9pfs mounting requires special setup, using scp instead for now
    
    # Copy provisioning scripts to VM
    echo "Copying provisioning scripts to VM..."
    copy_to_vm "${STRIX_DIR}" "/home/${VM_USER}/strix-halo-setup"
    
    # Copy cache to VM
    if [ -d "$CACHE_DIR" ]; then
        echo "Copying cache to VM..."
        copy_to_vm "$CACHE_DIR" "/home/${VM_USER}/.cache"
    fi
    
    # Run provisioning with override for SSH key check
    run_in_vm "cd /home/${VM_USER}/strix-halo-setup && \
        CACHE_DIR=/home/${VM_USER}/.cache \
        SSH_USERS='${VM_USER}' \
        FORCE_SSH_KEY_CHECK=true \
        ./provision_strix_halo.sh --all --force"
    
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
    
    # LM Studio
    echo -n "LM Studio (port 1234): "
    if run_in_vm "curl -sf http://localhost:1234/v1/models" >/dev/null 2>&1; then
        echo "[OK]"
    else
        echo "[FAIL] (may not be installed)"
    fi
    
    # llama.cpp
    echo -n "llama.cpp (port 11234): "
    if run_in_vm "curl -sf http://localhost:11234/v1/models" >/dev/null 2>&1; then
        echo "[OK]"
    else
        echo "[FAIL] (may not be installed)"
    fi
    
    # ComfyUI
    echo -n "ComfyUI (port 8188): "
    if run_in_vm "curl -sf http://localhost:8188/system_stats" >/dev/null 2>&1; then
        echo "[OK]"
    else
        echo "[FAIL] (may not be installed)"
    fi
    
    # ACE Step
    echo -n "ACE Step (port 7860): "
    if run_in_vm "curl -sf http://localhost:7860" >/dev/null 2>&1; then
        echo "[OK]"
    else
        echo "[FAIL] (may not be installed)"
    fi
    
    # WordPress
    echo -n "WordPress (port 8080): "
    if run_in_vm "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080" 2>&1 | grep -q "200\|302"; then
        echo "[OK]"
    else
        echo "[FAIL] (may not be installed)"
    fi
    
    # RDP
    echo -n "RDP (port 3389): "
    if run_in_vm "nc -z localhost 3389" >/dev/null 2>&1; then
        echo "[OK]"
    else
        echo "[FAIL] (may not be installed)"
    fi
    
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
    reattach_gpu_to_host
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
    setup        Check prereqs, generate keys, download image
    create       Create and start VM
    provision    Run provisioning inside VM
    health       Run health checks
    stop         Stop VM
    cleanup      Stop VM and reattach GPU
    all          Run full test cycle (setup -> create -> provision -> health -> cleanup)

Environment:
    VM_VCPU      Number of CPUs (default: 2)
    VM_RAM       RAM in MB (default: 4096)
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
            ;;
        create)
            ensure_sudo
            detach_gpu_from_host
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
            check_prereqs
            generate_ssh_key
            download_ubuntu_image
            mkdir -p "$VM_DIR"
            setup_tmpfs
            generate_cloudinit
            create_vm_disk
            detach_gpu_from_host
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
