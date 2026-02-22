#!/bin/bash
# Libvirt hook script - runs after VM stops
# This handles proper GPU unbind from vfio-pci and rebind to amdgpu

set -e

VM_NAME="strix-test-vm"
GPU="0000:c5:00.0"
GPU_AUDIO="0000:c5:00.1"
LOG_FILE="/var/log/libvirt-hooks/gpu-passthrough.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Starting post-VM hook for $VM_NAME ==="

# Wait a moment for VM to fully release the GPU
sleep 2

# 1. Unbind from vfio-pci
current_driver=$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
log "Current GPU driver: $current_driver"

if [ "$current_driver" = "vfio-pci" ]; then
    log "Unbinding GPU from vfio-pci..."
    
    # Unbind audio first
    if [ -e "/sys/bus/pci/devices/$GPU_AUDIO/driver" ]; then
        audio_driver=$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        if [ "$audio_driver" = "vfio-pci" ]; then
            log "Unbinding audio from vfio-pci..."
            echo "$GPU_AUDIO" > "/sys/bus/pci/drivers/vfio-pci/unbind" 2>/dev/null || {
                log "[WARN] Failed to unbind audio from vfio-pci, continuing..."
            }
        fi
    fi
    
    # Unbind GPU
    if echo "$GPU" > "/sys/bus/pci/drivers/vfio-pci/unbind" 2>/dev/null; then
        log "[OK] GPU unbound from vfio-pci"
        sleep 1
    else
        log "[WARN] Failed to unbind GPU from vfio-pci (may already be unbound)"
    fi
else
    log "[INFO] GPU not bound to vfio-pci (current: $current_driver)"
fi

# 2. Clear driver_override
echo "" > "/sys/bus/pci/devices/$GPU/driver_override" 2>/dev/null || true
echo "" > "/sys/bus/pci/devices/$GPU_AUDIO/driver_override" 2>/dev/null || true
log "[OK] Cleared driver_override"

# 3. Trigger PCI rescan to rebind to amdgpu
log "Triggering PCI rescan..."
echo 1 > /sys/bus/pci/rescan
sleep 2

# 4. Check if amdgpu bound automatically
current_driver=$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
if [ "$current_driver" = "amdgpu" ]; then
    log "[OK] GPU automatically rebound to amdgpu"
else
    log "[INFO] GPU not automatically bound (current: $current_driver), attempting manual bind..."
    
    # Try to load amdgpu if not loaded
    modprobe amdgpu 2>/dev/null || true
    
    # Try manual bind
    if [ -d "/sys/bus/pci/drivers/amdgpu" ]; then
        if echo "$GPU" > "/sys/bus/pci/drivers/amdgpu/bind" 2>/dev/null; then
            log "[OK] GPU manually bound to amdgpu"
        else
            log "[WARN] Failed to manually bind GPU to amdgpu"
        fi
    else
        log "[WARN] amdgpu driver directory not found"
    fi
fi

# 5. Check audio binding
audio_driver=$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
if [ "$audio_driver" = "snd_hda_intel" ]; then
    log "[OK] Audio bound to snd_hda_intel"
elif [ "$audio_driver" = "amdgpu" ]; then
    log "[OK] Audio bound to amdgpu"
else
    log "[INFO] Audio driver: $audio_driver"
fi

# 6. Restart display manager to restore graphics
log "Restarting display manager..."
for dm in gdm3 sddm lightdm; do
    if systemctl is-active --quiet "$dm" 2>/dev/null; then
        systemctl restart "$dm" && {
            log "[OK] Restarted $dm"
            break
        } || log "[WARN] Failed to restart $dm"
    fi
done

log "=== Post-VM hook completed ==="
exit 0
