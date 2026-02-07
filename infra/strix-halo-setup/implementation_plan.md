# Strix Halo AI Environment: Final Implementation Plan

This document serves as the master plan for the Strix Halo (GFX1151) Linux Mint AI and Hosting environment.

## 1. Goal Description

To provide a secure, multi-user, hardware-accelerated environment for LLM inference (LM Studio), Stable Diffusion (ComfyUI), and web hosting (Supabase/WP), monitored by a dedicated AI defense stack.

## 2. Infrastructure Overview

- **Storage**: Centralized `/opt/ai/models` directory with group access for all AI services.
- **Acceleration**: ROCm 7.2+ integrated with the RDNA 3.5 APU.
- **Headless GUI**: Dummy Xorg display providing a 4K desktop context for RDP and GUI AppImages.

## 3. Proposed Components

### A. Core System

- **Kernel 6.18.4+**: Essential for stable Strix Halo firmware support.
- **Security**: Pubkey-only SSH, UFW firewall, and isolated service users.
- **Provisioning**: Managed via `provision_strix_halo.sh` with dry-run safety.

### B. AI Services (Persistence via Systemd)

- **LM Studio**: Headless `llmster` daemon + RDP accessible GUI.
- **ComfyUI**: Python-based SD backend.
- **Persistence**: Both services start on boot and restart on failure.

### C. Containerized Services (Docker)

- **OpenClaw**: Running as user `claw` with host-pinned configuration for easy administration.
- **Hosting Stack**: Supabase (Postgres/API) and WordPress Multisite.
- **Service Wrappers**: Systemd units manage the lifecycle of these Docker Compose stacks.

### D. Cisco AI Defense

- **Daemon**: A Python orchestrator running as user `defense`.
- **Scanners**: Real-time auditing via `a2a-scanner`, `mcp-scanner`, and `skill-scanner`.

## 4. Post-Installation & Integration

- **Shared Memory**: APU "VRAM" is mapped from system RAM; shared directory ensures models are loaded from a single source.
- **Remote Workflow**: Download models via RDP GUI -> Inference via Daemon -> Integration via OpenClaw.

## 5. Verification Plan

- **Hardware**: `rocminfo` and `rocm-smi` validation.
- **Persistence**: `systemctl` status check across all units.
- **Security**: Verified password lockout and firewall rules.
