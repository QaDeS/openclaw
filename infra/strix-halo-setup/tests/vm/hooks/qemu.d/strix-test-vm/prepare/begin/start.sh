#!/bin/bash
# Libvirt hook script - runs before VM starts
# This handles proper GPU unbind from amdgpu and bind to vfio-pci

set -e

VM_NAME="strix-test-vm"
GPU="0000:c5:00.0"
GPU_AUDIO="0000:c5:00.1"
LOG_FILE="/var/log/libvirt-hooks/gpu-passthrough.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Starting pre-VM hook for $VM_NAME ==="

# 1. Check if GPU exists
if [ ! -e "/sys/bus/pci/devices/$GPU" ]; then
    log "ERROR: GPU $GPU not found!"
    exit 1
fi

# 2. Set device_specific reset method (CRITICAL for AMD GPU reset bug fix)
# This must be done BEFORE unbinding from amdgpu
if [ -f "/sys/bus/pci/devices/$GPU/reset_method" ]; then
    current_method=$(cat "/sys/bus/pci/devices/$GPU/reset_method" 2>/dev/null || echo "unknown")
    log "Current reset_method: $current_method"
    
    # Check if device_specific is available
    if grep -q "device_specific" "/sys/bus/pci/devices/$GPU/reset_method" 2>/dev/null; then
        log "WARNING: device_specific not in reset_method list, trying to set anyway..."
    fi
    
    # Try to set device_specific reset method
    if echo 'device_specific' > "/sys/bus/pci/devices/$GPU/reset_method" 2>/dev/null; then
        log "[OK] Set reset_method to device_specific"
    else
        log "[WARN] Could not set device_specific reset_method (may need kernel 5.15+)"
        log "[WARN] Continuing with default reset method - VM may hang on shutdown!"
    fi
else
    log "[WARN] reset_method file not found - kernel may be too old"
fi

# 3. Check current driver
current_driver=$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
log "Current GPU driver: $current_driver"

# 4. If bound to amdgpu, unbind it
if [ "$current_driver" = "amdgpu" ]; then
    log "Unbinding GPU from amdgpu..."
    
    # Unbind audio first (if bound to snd_hda_intel)
    if [ -e "/sys/bus/pci/devices/$GPU_AUDIO/driver" ]; then
        audio_driver=$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
        if [ "$audio_driver" = "snd_hda_intel" ]; then
            log "Unbinding audio from snd_hda_intel..."
            echo "$GPU_AUDIO" > "/sys/bus/pci/devices/$GPU_AUDIO/driver/unbind" 2>/dev/null || {
                log "[WARN] Failed to unbind audio, continuing anyway..."
            }
        fi
    fi
    
    # Unbind the GPU
    if echo "$GPU" > "/sys/bus/pci/drivers/amdgpu/unbind" 2>/dev/null; then
        log "[OK] GPU unbound from amdgpu"
        sleep 1
    else
        log "[ERROR] Failed to unbind GPU from amdgpu!"
        log "[ERROR] Check if GPU is in use by display (X11/Wayland)"
        exit 1
    fi
elif [ "$current_driver" = "vfio-pci" ]; then
    log "[OK] GPU already bound to vfio-pci"
else
    log "[INFO] GPU not bound to any driver (may be unbound or using different driver)"
fi

# 5. Bind to vfio-pci
current_driver=$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
if [ "$current_driver" != "vfio-pci" ]; then
    log "Binding GPU to vfio-pci..."
    
    # Load vfio-pci module if not loaded
    modprobe vfio-pci 2>/dev/null || true
    
    # Add device ID to vfio-pci
    vendor=$(cat "/sys/bus/pci/devices/$GPU/vendor" 2>/dev/null)
    device=$(cat "/sys/bus/pci/devices/$GPU/device" 2>/dev/null)
    if [ -n "$vendor" ] && [ -n "$device" ]; then
        echo "$vendor $device" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    fi
    
    # Try to bind
    if echo "$GPU" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null; then
        log "[OK] GPU bound to vfio-pci"
    else
        # Try driver_override method
        log "Trying driver_override method..."
        echo "vfio-pci" > "/sys/bus/pci/devices/$GPU/driver_override" 2>/dev/null || true
        echo "$GPU" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || {
            log "[ERROR] Failed to bind GPU to vfio-pci"
            exit 1
        }
    fi
    
    # Bind audio as well
    if echo "$GPU_AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null; then
        log "[OK] Audio bound to vfio-pci"
    else
        log "[WARN] Could not bind audio to vfio-pci"
    fi
else
    log "[OK] GPU already bound to vfio-pci"
fi

# 6. Final verification
final_driver=$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
if [ "$final_driver" = "vfio-pci" ]; then
    log "[OK] GPU successfully bound to vfio-pci - VM can start"
else
    log "[ERROR] GPU not bound to vfio-pci (current: $final_driver)"
    exit 1
fi

log "=== Pre-VM hook completed ==="
exit 0
