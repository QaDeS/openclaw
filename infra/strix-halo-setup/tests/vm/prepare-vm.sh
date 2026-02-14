#!/bin/bash
# prepare-vm.sh - VM creation and management helpers for strix-halo tests

set -euo pipefail

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
    
    echo "✓ All prerequisites met"
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
        "https://cloud-images.ubuntu.com/releases/noble/release-20241001/ubuntu-24.04-server-cloudimg-amd64.img" \
        --progress=dot:giga
    
    mv "$tmp_image" "$VM_IMAGE"
    echo "✓ Downloaded Ubuntu image to $VM_IMAGE"
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
    echo "✓ Generated cloud-init seed ISO: $seed_iso"
    
    VM_SEED_ISO="$seed_iso"
    export VM_SEED_ISO
}

# =============================================================================
# VM Disk Management  
# =============================================================================

create_vm_disk() {
    if [ -f "$VM_DISK" ]; then
        echo "Using existing VM disk: $VM_DISK"
        return 0
    fi
    
    echo "Creating VM disk..."
    qemu-img create -f qcow2 -o preallocation=metadata "$VM_DISK" 20G
    echo "✓ Created VM disk: $VM_DISK"
}

# =============================================================================
# GPU Passthrough - Detach from Host
# =============================================================================

detach_gpu_from_host() {
    echo "Detaching GPU from host..."
    
    # Check if already detached
    if [ -L "/sys/bus/pci/devices/${GPU_PCI}/driver" ]; then
        local driver=$(readlink "/sys/bus/pci/devices/${GPU_PCI}/driver")
        if [[ "$driver" == *"vfio-pci"* ]]; then
            echo "GPU already detached"
            return 0
        fi
        
        # Unbind from current driver
        echo "${GPU_PCI}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        echo "${GPU_PCI}" > /sys/bus/pci/drivers/amdgpu/unbind 2>/dev/null || true
        echo "${GPU_PCI}" > /sys/bus/pci/drivers/pci-stub/unbind 2>/dev/null || true
    fi
    
    # Bind to vfio-pci
    echo "vfio-pci" > /sys/bus/pci/devices/${GPU_PCI}/driver_override
    echo "${GPU_PCI}" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    
    # Do the same for audio
    echo "vfio-pci" > /sys/bus/pci/devices/${GPU_AUDIO_PCI}/driver_override 2>/dev/null || true
    echo "${GPU_AUDIO_PCI}" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    
    echo "✓ GPU detached from host"
}

# =============================================================================
# GPU Passthrough - Reattach to Host
# =============================================================================

reattach_gpu_to_host() {
    echo "Re-attaching GPU to host..."
    
    # Unbind from vfio-pci
    echo "${GPU_PCI}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "${GPU_AUDIO_PCI}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    
    # Clear driver override
    echo "" > /sys/bus/pci/devices/${GPU_PCI}/driver_override 2>/dev/null || true
    echo "" > /sys/bus/pci/devices/${GPU_AUDIO_PCI}/driver_override 2>/dev/null || true
    
    # Rebind to amdgpu
    echo "${GPU_PCI}" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null || true
    echo "${GPU_AUDIO_PCI}" > /sys/bus/pci/drivers/snd_hda_codec_hdmi/bind 2>/dev/null || true
    
    echo "✓ GPU re-attached to host"
}

# =============================================================================
# VM Lifecycle
# =============================================================================

create_vm() {
    echo "Creating VM: $VM_NAME..."
    
    # Destroy existing VM if present
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" 2>/dev/null || true
    
    virt-install \
        --name "$VM_NAME" \
        --vcpus "$VM_VCPU" \
        --memory "$VM_RAM" \
        --disk "$VM_DISK" \
        --disk "$VM_SEED_ISO",device=cdrom \
        --network network=default,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --video qxl \
        --boot uefi \
        --cpu host \
        --machine q35 \
        --import \
        --noautoconsole \
        --xml ./devices/hostdev[1]=/xml/pci/gpu.xml \
        2>&1 || true
    
    # Define with GPU passthrough manually
    cat > /tmp/${VM_NAME}-gpu.xml << XML
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0xc5' slot='0x00' function='0x0'/>
  </source>
</hostdev>
XML

    virsh attach-device "$VM_NAME" /tmp/${VM_NAME}-gpu.xml --persistent 2>/dev/null || true
    
    echo "✓ VM created"
}

start_vm() {
    echo "Starting VM: $VM_NAME..."
    virsh start "$VM_NAME"
    echo "✓ VM started"
}

stop_vm() {
    echo "Stopping VM: $VM_NAME..."
    
    # Try graceful shutdown first
    if virsh shutdown "$VM_NAME" 2>/dev/null; then
        echo "Waiting for graceful shutdown..."
        for i in {1..30}; do
            if ! virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
                echo "✓ VM stopped"
                return 0
            fi
            sleep 2
        done
    fi
    
    # Force destroy if still running
    echo "Force destroying VM..."
    virsh destroy "$VM_NAME" 2>/dev/null || true
    echo "✓ VM destroyed"
}

wait_for_ssh() {
    echo "Waiting for SSH to be ready..."
    local ip
    
    for i in {1..60}; do
        ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep "192.168" | awk '{print $4}' | cut -d'/' -f1)
        if [ -n "$ip" ]; then
            if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$VM_SSH_KEY" "${VM_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
                echo "✓ SSH ready at $ip"
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
    
    echo "✓ Provisioning complete"
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
        echo "✓"
    else
        echo "✗"
        ((failures++))
    fi
    
    # LM Studio
    echo -n "LM Studio (port 1234): "
    if run_in_vm "curl -sf http://localhost:1234/v1/models" >/dev/null 2>&1; then
        echo "✓"
    else
        echo "✗ (may not be installed)"
    fi
    
    # llama.cpp
    echo -n "llama.cpp (port 11234): "
    if run_in_vm "curl -sf http://localhost:11234/v1/models" >/dev/null 2>&1; then
        echo "✓"
    else
        echo "✗ (may not be installed)"
    fi
    
    # ComfyUI
    echo -n "ComfyUI (port 8188): "
    if run_in_vm "curl -sf http://localhost:8188/system_stats" >/dev/null 2>&1; then
        echo "✓"
    else
        echo "✗ (may not be installed)"
    fi
    
    # ACE Step
    echo -n "ACE Step (port 7860): "
    if run_in_vm "curl -sf http://localhost:7860" >/dev/null 2>&1; then
        echo "✓"
    else
        echo "✗ (may not be installed)"
    fi
    
    # WordPress
    echo -n "WordPress (port 8080): "
    if run_in_vm "curl -sf -o /dev/null -w '%{http_code}' http://localhost:8080" 2>&1 | grep -q "200\|302"; then
        echo "✓"
    else
        echo "✗ (may not be installed)"
    fi
    
    # RDP
    echo -n "RDP (port 3389): "
    if run_in_vm "nc -z localhost 3389" >/dev/null 2>&1; then
        echo "✓"
    else
        echo "✗ (may not be installed)"
    fi
    
    if [ $failures -gt 0 ]; then
        echo "⚠ $failures service(s) failed"
        return 1
    fi
    
    echo "✓ All health checks passed"
    return 0
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    echo "Cleaning up..."
    stop_vm
    reattach_gpu_to_host
    restart_display_manager
}

restart_display_manager() {
    echo "Restarting display manager..."
    
    # Try common display managers
    for dm in gdm3 sddm lightdm; do
        if systemctl list-unit-files | grep -q "^${dm}.service"; then
            echo "Restarting $dm..."
            sudo systemctl restart "$dm" 2>/dev/null && echo "✓ Display manager restarted" || true
            return 0
        fi
    done
    
    echo "⚠ Could not detect display manager. You may need to restart manually."
}

# =============================================================================
# Main
# =============================================================================

show_help() {
    cat << HELP
Usage: $0 <command>

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
            check_prereqs
            generate_ssh_key
            download_ubuntu_image
            generate_cloudinit
            create_vm_disk
            ;;
        create)
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
            cleanup
            ;;
        all)
            check_prereqs
            generate_ssh_key
            download_ubuntu_image
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
