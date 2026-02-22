#!/bin/bash
# Pre-flight check script for GPU passthrough readiness
# Checks IOMMU, GPU isolation, reset_method support, and driver status

set -euo pipefail

GPU_PCI="${GPU_PCI:-0000:c5:00.0}"
GPU_AUDIO_PCI="${GPU_AUDIO_PCI:-0000:c5:00.1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

echo "============================================"
echo "GPU Passthrough Pre-flight Check"
echo "============================================"
echo ""

# 1. Check kernel version
echo "1. Kernel Version"
current_kernel=$(uname -r)
info "Running: $current_kernel"

kernel_minor=$(echo "$current_kernel" | cut -d. -f2)
kernel_patch=$(echo "$current_kernel" | cut -d. -f3 | cut -d- -f1)

if [ "$kernel_minor" -eq 18 ] && [ "$kernel_patch" -lt 4 ] 2>/dev/null; then
    warn "Kernel 6.18.0-6.18.3 has known amdgpu MES hang issues"
    warn "Consider upgrading to 6.17.9 or 6.19+"
elif [ "$kernel_minor" -ge 17 ]; then
    pass "Kernel version should support device_specific reset"
else
    warn "Kernel may be too old for optimal passthrough support"
fi
echo ""

# 2. Check IOMMU
echo "2. IOMMU Support"
if [ -d "/sys/class/iommu" ] && [ "$(ls -A /sys/class/iommu 2>/dev/null | wc -l)" -gt 0 ]; then
    pass "IOMMU is enabled"
    info "IOMMU devices: $(ls /sys/class/iommu 2>/dev/null | tr '\n' ' ')"
else
    fail "IOMMU does not appear to be enabled"
    info "Add 'amd_iommu=on iommu=pt' to kernel cmdline"
    info "Edit /etc/default/grub, then: sudo update-grub && sudo reboot"
fi
echo ""

# 3. Check GPU IOMMU group isolation
echo "3. GPU IOMMU Group Isolation"
if [ -e "/sys/bus/pci/devices/$GPU_PCI/iommu_group" ]; then
    iommu_group=$(readlink -f "/sys/bus/pci/devices/$GPU_PCI/iommu_group" | xargs basename)
    info "GPU is in IOMMU group: $iommu_group"
    
    group_devices=$(ls "/sys/kernel/iommu_groups/$iommu_group/devices/" 2>/dev/null | wc -l)
    info "Devices in group: $group_devices"
    
    if [ "$group_devices" -le 2 ]; then
        pass "GPU appears to be isolated (good for passthrough)"
    else
        warn "GPU shares IOMMU group with other devices"
        warn "This may cause issues - ACS override patch may be needed"
        echo ""
        info "Devices in group:"
        for dev in "/sys/kernel/iommu_groups/$iommu_group/devices/"*; do
            dev_name=$(basename "$dev")
            lspci -s "$dev_name" 2>/dev/null || echo "  $dev_name"
        done
    fi
else
    fail "GPU not in any IOMMU group - IOMMU may be disabled"
fi
echo ""

# 4. Check GPU exists and get info
echo "4. GPU Detection"
if [ -e "/sys/bus/pci/devices/$GPU_PCI" ]; then
    pass "GPU found at $GPU_PCI"
    
    # Get device info
    if command -v lspci &> /dev/null; then
        info "Device: $(lspci -s "$GPU_PCI" 2>/dev/null | cut -d' ' -f2- || echo "Unknown")"
    fi
    
    # Check vendor/device
    vendor=$(cat "/sys/bus/pci/devices/$GPU_PCI/vendor" 2>/dev/null || echo "unknown")
    device=$(cat "/sys/bus/pci/devices/$GPU_PCI/device" 2>/dev/null || echo "unknown")
    info "Vendor: $vendor, Device: $device"
else
    fail "GPU not found at $GPU_PCI"
    info "Check GPU_PCI variable and lspci output"
    exit 1
fi
echo ""

# 5. Check reset_method support
echo "5. GPU Reset Method Support"
if [ -f "/sys/bus/pci/devices/$GPU_PCI/reset_method" ]; then
    current_method=$(cat "/sys/bus/pci/devices/$GPU_PCI/reset_method" 2>/dev/null || echo "unknown")
    info "Current reset_method: $current_method"
    
    available_methods=$(cat "/sys/bus/pci/devices/$GPU_PCI/reset_method" 2>/dev/null || echo "")
    if echo "$available_methods" | grep -q "device_specific"; then
        pass "device_specific reset method is supported"
    else
        warn "device_specific reset method not available"
        warn "Available: $available_methods"
        info "This is normal for kernels < 5.15 or some GPUs"
    fi
    
    # Test if we can set device_specific
    if echo 'device_specific' > "/sys/bus/pci/devices/$GPU_PCI/reset_method" 2>/dev/null; then
        pass "Successfully set device_specific reset_method"
        # Restore previous value if it was different
        if [ "$current_method" != "device_specific" ] && [ "$current_method" != "unknown" ]; then
            echo "$current_method" > "/sys/bus/pci/devices/$GPU_PCI/reset_method" 2>/dev/null || true
        fi
    else
        warn "Could not set device_specific reset_method"
        info "This may be because GPU is bound to vfio-pci or in use"
    fi
else
    warn "reset_method file not found - kernel may be too old"
    info "Consider upgrading to kernel 5.15+ for better reset support"
fi
echo ""

# 6. Check current driver binding
echo "6. Driver Binding Status"
current_driver=$(readlink -f "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
info "GPU driver: $current_driver"

if [ "$current_driver" = "amdgpu" ]; then
    pass "GPU bound to amdgpu (ready for unbind)"
elif [ "$current_driver" = "vfio-pci" ]; then
    pass "GPU bound to vfio-pci (ready for passthrough)"
else
    warn "GPU not bound to amdgpu or vfio-pci"
    info "Current driver: $current_driver"
fi

# Check audio driver
if [ -e "/sys/bus/pci/devices/$GPU_AUDIO_PCI" ]; then
    audio_driver=$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO_PCI/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    info "Audio driver: $audio_driver"
fi
echo ""

# 7. Check vfio-pci module
echo "7. VFIO-PCI Module"
if lsmod | grep -q "^vfio_pci"; then
    pass "vfio-pci module is loaded"
else
    warn "vfio-pci module not loaded"
    info "Run: sudo modprobe vfio-pci"
fi
echo ""

# 8. Check for boot framebuffer issues
echo "8. Boot Framebuffer"
if grep -q "BOOTFB\|efifb\|vesafb" /proc/iomem 2>/dev/null; then
    info "Boot framebuffer detected in memory map"
    if grep -q "BOOTFB" /proc/iomem 2>/dev/null; then
        warn "BOOTFB present - may need 'video=efifb:off' in kernel cmdline"
    fi
else
    pass "No boot framebuffer in memory map (good for passthrough)"
fi
echo ""

# 9. Check libvirt hooks
echo "9. Libvirt Hook Scripts"
hook_dir="/etc/libvirt/hooks/qemu.d/strix-test-vm"
if [ -d "$hook_dir" ]; then
    pass "Hook directory exists: $hook_dir"
    if [ -x "$hook_dir/prepare/begin/start.sh" ]; then
        pass "Start hook script exists and is executable"
    else
        warn "Start hook script missing or not executable"
    fi
    if [ -x "$hook_dir/release/end/stop.sh" ]; then
        pass "Stop hook script exists and is executable"
    else
        warn "Stop hook script missing or not executable"
    fi
else
    warn "Hook directory not found: $hook_dir"
    info "Hooks need to be installed for proper GPU reset"
fi
echo ""

# 10. Summary and recommendations
echo "============================================"
echo "Summary"
echo "============================================"

issues=0

# Count issues
if [ ! -d "/sys/class/iommu" ] || [ "$(ls -A /sys/class/iommu 2>/dev/null | wc -l)" -eq 0 ]; then
    ((issues++)) || true
fi

if [ "$current_driver" != "amdgpu" ] && [ "$current_driver" != "vfio-pci" ]; then
    ((issues++)) || true
fi

if [ ! -f "/sys/bus/pci/devices/$GPU_PCI/reset_method" ]; then
    ((issues++)) || true
fi

if [ "$issues" -eq 0 ]; then
    pass "System appears ready for GPU passthrough!"
    echo ""
    info "Next steps:"
    info "  1. Ensure hook scripts are installed:"
    info "     sudo mkdir -p /etc/libvirt/hooks"
    info "     sudo cp -r tests/vm/hooks/* /etc/libvirt/hooks/"
    info "  2. Restart libvirt: sudo systemctl restart libvirtd"
    info "  3. Run: sudo tests/run-tests.sh --vm all"
else
    warn "Found $issues potential issue(s) - review above"
    echo ""
    info "Recommended fixes:"
    if [ ! -d "/sys/class/iommu" ] || [ "$(ls -A /sys/class/iommu 2>/dev/null | wc -l)" -eq 0 ]; then
        info "  • Enable IOMMU: Add 'amd_iommu=on iommu=pt' to /etc/default/grub"
    fi
    if [ "$current_driver" != "amdgpu" ] && [ "$current_driver" != "vfio-pci" ]; then
        info "  • Check GPU driver binding"
    fi
    if [ ! -f "/sys/bus/pci/devices/$GPU_PCI/reset_method" ]; then
        info "  • Consider upgrading kernel: ./install-kernel.sh 6.17.9"
    fi
fi

echo ""
info "For detailed logs, check:"
info "  dmesg | grep -i vfio"
info "  dmesg | grep -i amdgpu"
info "  /var/log/libvirt-hooks/gpu-passthrough.log (after running VM)"
