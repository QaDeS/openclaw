# Strix Halo Technical Research & References

## GFX1151 / RDNA 3.5 Support

- **Kernel**: 6.18.4+ (required for stable RDNA 3.5 support).
- **ROCm**: 7.2+ (installed system-wide).
- **Memory**: APU shared memory optimizations (`amdgpu.gttsize`) are automatically applied by the script.
- **Finding**: Syncing Kernel 6.18.4+ with ROCm 7.2+ provides stable compute and graphics initialization.
- **Optimization**: `amdgpu.gttsize` is automatically set to 50% of system RAM by the provisioning script to allow the APU to address large LLMs.
- **Hardware Override**: `HSA_OVERRIDE_GFX_VERSION=11.5.1` is applied to all AI services to ensure ROCm detects the GFX1151 architecture correctly.

## Headless GPU Acceleration (LM Studio GUI)

- **Challenge**: Many GUI AppImages (like LM Studio) fail to launch or lose hardware acceleration if no display is detected by the X server.
- **Solution**: `xserver-xorg-video-dummy` creates a virtual high-resolution display (3840x2160) which satisfies the application's requirement for an "attached screen" while still allowing full ROCm compute offloading.

## Cisco AI Defense Stack

- **Role**: Secure the communication between agents (A2A) and validate the safety of Model Context Protocol (MCP) integrations.
- **Mechanism**: Periodic scanning of network traffic and agent skill definitions to prevent prompt injection or unauthorized data access.

## Shared Memory Model sharing

- **Finding**: Since GFX1151 uses Unified Memory (System RAM), multiple GPU contexts (LM Studio + ComfyUI) can share the same physical memory heap efficiently. Using a central `/opt/ai/models` path simplifies disk management and deduplicates model storage.
