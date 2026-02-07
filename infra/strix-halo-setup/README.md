# Strix Halo AI & Hosting Infrastructure Setup

This directory contains a comprehensive automated provisioning suite for setting up a secure, multi-user AI and hosting environment on **AMD Strix Halo (GFX1151)** systems running Linux Mint.

## 🚀 Overview

The setup transforms a Strix Halo machine into a hardened AI powerhouse capable of running:

- **LM Studio** (Headless daemon with GPU acceleration and RDP access)
- **ComfyUI** (RDNA 3.5 optimized backend with **Z-Image Turbo** support)
- **ACE Step 1.5** (Music Generation optimized for GFX1151)
- **OpenClaw** (Deployed directly from local checkout for rapid dev)
- **Hosting Stack** (Supabase and WordPress Multisite)
- **Cisco AI Defense** (Automated agent security and monitoring)

## 📖 Documentation

- [Implementation Plan](implementation_plan.md) - Master project roadmap and architecture.
- [Research Notes](research_notes.md) - Technical findings on Strix Halo and ROCm.
- [Walkthrough](walkthrough.md) - Step-by-step verification guide.

## 📁 Directory Structure

```text
infra/strix-halo-setup/
├── provision_strix_halo.sh   # Main hardware-hardened setup script
├── systemd/                  # Persistence for all service daemons
│   ├── llmster.service       # LM Studio Daemon
│   ├── comfyui.service       # Stable Diffusion backend
│   ├── cisco-defense.service # AI Security Orchestrator
│   ├── openclaw.service      # OpenClaw Docker wrapper
│   └── hosting.service       # Supabase/WP Stack wrapper
├── docker/                   # Containerized service stacks
│   ├── openclaw-compose.yml
│   └── hosting-compose.yml
└── defense/                  # Monitoring logic
    └── cisco-defense-daemon.py
```

## 🛠 Prerequisites

- **Hardware**: AMD Strix Halo / GFX1151 APU.
- **OS**: Linux Mint (Ubuntu/Jammy based).
- **Kernel**: 6.18.4+ (required for stable RDNA 3.5 support).
- **ROCm**: 7.2+ (installed system-wide).
- **Memory**: APU shared memory optimizations are applied by the script.

## ⚙️ Installation

The installer is designed with extreme safety guardrails to prevent hardware mismatch or SSH lockout.

### 1. Interactive Selection

Run the script to see the installation menu:

```bash
sudo ./provision_strix_halo.sh --force
```

Options include:

- **Full Installation**: Deploys the entire hardware and AI stack.
- **LLM Stack**: LM Studio + OpenClaw (Local Checkout).
- **Image/Music Stack**: ComfyUI + Z-Image Turbo + ACE Step 1.5.
- **Security Only**: Cisco AI Defense scanners.

### 2. Automated Flags

The installer applies hardware-specific overrides:

- `HSA_OVERRIDE_GFX_VERSION=11.5.1`
- `PYTORCH_ALLOC_CONF=expandable_segments:True`
- `amdgpu.gttsize` (Calculated as 50% of system RAM)
  _Note: You will be asked to type "I UNDERSTAND THE RISKS" to continue._

### 3. Reboot

A reboot is **strictly required** to initialize the GFX1151 drivers and ROCm stack.

## � Post-Installation & Initialization

After reboot, follow these steps to hook up all components:

### 1. Mount & Point Models

The script automatically symlinks `~/.cache/lm-studio/models` to `/opt/ai/models`. To initialize your external models:

- **Mount your external drive**:
  ```bash
  sudo mount /dev/sdX1 /opt/ai/models
  ```
- **Symlink external folder** (if already mounted):
  ```bash
  # As the 'lmstudio' user
  ln -sf /path/to/your/external/models/* /opt/ai/models/
  ```
- **Permissions**: Ensure the models are readable by the group:
  ```bash
  sudo chown -R :ai-users /opt/ai/models
  sudo chmod -R g+r /opt/ai/models
  ```

### 2. Launch LM Studio GUI Remotely

To download new models or use the UI:

1.  **Connect via RDP**: Use your laptop's RDP client (Remmina, MS RDP, etc.) to connect to the Strix Halo IP.
2.  **Open Terminal** within the RDP session.
3.  **Run the GUI**:
    ```bash
    /home/lmstudio/bin/lm-studio.AppImage
    ```
4.  **Settings**: In LM Studio settings, verify the "Models Directory" is pointing to `/home/lmstudio/.cache/lm-studio/models` (which redirects to the shared `/opt/ai/models`).

### 3. Verify Component Communication

- **LM Studio Daemon**: Check if the HTTP server is up:
  ```bash
  curl http://localhost:1234/v1/models
  ```
- **OpenClaw Hook-up**:
  Ensure OpenClaw's `.env` (managed as `claw` user) points to the LM Studio daemon:
  ```text
  LMSTUDIO_BASE_URL=http://localhost:1234/v1
  ```

### 3. Shared GPU Acceleration

Both LM Studio and ComfyUI use the ROCm stack. Verify they see the GPU:

```bash
# Verify ROCm
rocminfo | grep GFX

# Monitor Usage
rocm-smi
```

## �🔒 Security & Remote Access

- **SSH**: Password authentication is disabled. **Ensure your laptop's public key is in `~/.ssh/authorized_keys`** of the sudo user before running.
- **RDP (TCP 3389)**: Connect via any RDP client to access the GPU-accelerated 4K virtual desktop.
- **Firewall**: UFW is enabled and configured for SSH, RDP, and Hosting ports.

## 🧠 Model Sharing (Unified Memory)

All AI users (`lmstudio`, `comfyui`) are part of the `ai-users` group.

- **Path**: `/opt/ai/models`
- **Tip**: Load models into this shared path to avoid redundant storage and maximize Strix Halo's large unified memory buffer.

## 🛡 Cisco AI Defense

The `defense` user runs a service that orchestrates:

- `a2a-scanner`: Monitoring Agent-to-Agent protocol security.
- `mcp-scanner`: Validating Model Context Protocol security.
- `skill-scanner`: Real-time auditing of agent capabilities.
  Logs are available at `/var/log/cisco-defense.log`.
