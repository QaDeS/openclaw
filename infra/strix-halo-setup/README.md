# Strix Halo Provisioning

Automated provisioning for AMD Strix Halo (GFX1151) systems. Turns a bare
Linux Mint / Ubuntu machine into a hardened, multi-user AI and web-hosting
server with a single command.

## What it sets up

| Component | Description | Port |
|-----------|-------------|------|
| **Base System** | Kernel 6.18, ROCm 7.2, GPU memory tuning, XFCE desktop + xrdp | 3389 (localhost) |
| **SSH** | Keys outside ecryptfs, hardening, fail2ban, UFW, optional UPnP | 22 |
| **Podman** | Rootless container runtime (replaces Docker) | -- |
| **OpenClaw** | Gateway deployed as a rootless podman quadlet (user `claw`) | -- |
| **LM Studio** | Desktop app for browsing/testing models (via RDP or `ssh -X`) | -- |
| **llama.cpp** | Vulkan-accelerated inference server | 11234 |
| **Sync llama_models** | Watches `/models` and maintains flat `/llama_models` for llama.cpp | -- |
| **ComfyUI** | Stable Diffusion backend optimized for RDNA 3.5 | 8188 |
| **Z-Image Turbo** | Optimized image generation pipeline on the ComfyUI venv | -- |
| **ACE Step 1.5** | Standalone music generation server (ROCm / GFX1151) | 7860 |
| **Security & Hosting** | Cisco AI Defense daemon + Supabase/WordPress via podman quadlets (user `hosting`) | 8080 |
| **Dynamic DNS** | Namecheap DDNS updater via podman quadlet (user `ddns`) | -- |

Each component is a standalone script in `components/` and can be
selected individually from the interactive menu.

## Prerequisites

- **Hardware**: AMD Strix Halo APU (GFX1151)
- **OS**: Linux Mint or Ubuntu 24.04 (Noble)
- **SSH key**: Your public key must be in `~/.ssh/authorized_keys` before
  running -- the script refuses to start if no key is found (lockout
  protection)
- **Root**: Run with `sudo`

## Quick start

```bash
# Dry-run (shows what would change, modifies nothing)
sudo ./provision_strix_halo.sh

# Apply changes (interactive component menu)
sudo ./provision_strix_halo.sh --force

# Install everything non-interactively
sudo ./provision_strix_halo.sh --force --all

# Install specific components only
sudo ./provision_strix_halo.sh --force --only BASE,COMFYUI,ACE_STEP
```

A **reboot is required** after provisioning to load the new kernel and
GPU drivers.

## CLI flags

```
--force              Apply changes (default is dry-run)
--redownload         Re-download assets even if they already exist
--cache-dir=PATH     Override download cache directory (default: .cache/)
--no-cache           Disable download cache entirely
--all                Skip menu and install all components
--only ID,...        Install specific components (comma-separated IDs)
--ssh-upnp-port=PORT External UPnP port for SSH (enables UPnP forwarding)
--ddns-fqdn=FQDN    Namecheap DDNS FQDN (enables dynamic DNS)
--history            Show provisioning run history
--undo[=TIMESTAMP]   Undo a provisioning run (default: latest)
--help, -h           Show built-in help with URLs and service commands
```

## Component IDs

Used with `--only` and shown in `--history`:

```
BASE          SSH_OUTSIDE_HOME   SSH_HARDENING   PODMAN
OPENCLAW      LMSTUDIO           LLAMACPP        SYNC_LLAMA
COMFYUI       ZIMAGE             ACE_STEP        SECURITY    DDNS
```

## Directory layout

```
provision_strix_halo.sh     Main entry point
components/                 One script per component (numbered for ordering)
  05-ssh.sh                   SSH keys outside ecryptfs
  07-ssh-hardening.sh         fail2ban, UFW, UPnP
  10-base.sh                  Kernel, ROCm, desktop
  11-podman.sh                Podman install
  20-llm-stack.sh             OpenClaw (node, pnpm, quadlet)
  21-lmstudio.sh              LM Studio desktop app
  22-llamacpp.sh              llama.cpp (Vulkan build)
  23-sync-llama-models.sh     Model directory sync service
  30-comfyui.sh               ComfyUI + ComfyUI Manager
  40-zimage.sh                Z-Image Turbo pipeline
  50-ace-step.sh              ACE Step 1.5 music generation
  60-security.sh              Cisco AI Defense + hosting stack
  62-ddns.sh                  Namecheap DDNS
lib/
  cache-helpers.sh            Cache-aware download wrappers
systemd/                    Service unit files
quadlet/                    Podman quadlet files (rootless containers)
docker/                     Dockerfiles and legacy compose files
defense/                    Cisco AI Defense daemon
scripts/
  backup-caches.sh            Snapshot system caches into .cache/
  restore-caches.sh           Restore .cache/ onto a new machine
  populate-cache.sh           Legacy cache population
  cleanup-stale-services.sh   Remove orphaned systemd units
  setup-ssh-for-user.sh       Standalone SSH key setup
  sync-llama-models.sh        Model sync script (deployed by component)
  upnp-ssh-refresh.sh         UPnP port mapping refresh
tests/                      Bats test suite (Docker + VM modes)
.cache/                     Download cache (git-ignored)
```

## Undo / rollback

Every `--force` run records a manifest under `/var/lib/strix-provision/`.
To undo the most recent run:

```bash
# Dry-run first
sudo ./provision_strix_halo.sh --undo

# Apply undo
sudo ./provision_strix_halo.sh --undo --force

# Undo a specific run
sudo ./provision_strix_halo.sh --undo=20260215-143022 --force

# See all past runs
sudo ./provision_strix_halo.sh --history
```

Undo restores backed-up config files, disables services, removes created
files and symlinks, and deletes UFW rules. Package installs (apt) are
noted but not auto-removed.

## Cache system

The provisioning suite caches downloads in `.cache/` (alongside the
provision script) so re-provisioning and cross-machine transfers are fast.

### What gets cached

| Subdirectory | Contents | Mechanism |
|---|---|---|
| `apt/` | `.deb` packages | `cached_apt_install` copies debs to/from `/var/cache/apt/archives/` |
| `uv/` | uv package cache | `UV_CACHE_DIR` env var passed through `sudo -u` |
| `pip/` | pip package cache | `PIP_CACHE_DIR` env var passed through `sudo -u` |
| `repos/` | Git bare repos | `cached_git_clone --reference` for fast clones |
| `podman/` | OCI image archives | `cached_podman_ensure` loads from `.tar` on restore |
| `scripts/` | Installer scripts | `cached_curl_pipe` caches piped downloads |
| `files/` | Single-file downloads | `cached_fetch` caches wget/curl targets |

### Self-populating caches

The `uv/`, `pip/`, `repos/`, `scripts/`, and `files/` caches populate
automatically during normal provisioning (the env vars and helpers route
all I/O through `.cache/`). Only `apt/` debs and `podman/` images require
an explicit backup step because they live in system locations outside
`.cache/`.

### Backing up caches

After a successful provision, capture the system caches:

```bash
sudo ./scripts/backup-caches.sh
```

This copies:
- apt `.deb` files from `/var/cache/apt/archives/`
- uv/pip caches (if not already redirected via env vars)
- Podman images for all service users (`hosting`, `ddns`, `claw`)
- Writes a `manifest.txt` with timestamps and sizes

### Transferring to a new machine

```bash
# On the source machine
rsync -a .cache/ /mnt/drive/strix-cache/

# On the target machine
rsync -a /mnt/drive/strix-cache/ .cache/
sudo ./scripts/restore-caches.sh
sudo ./provision_strix_halo.sh --force
```

`restore-caches.sh` copies the apt debs back to `/var/cache/apt/archives/`.
Everything else is read directly from `.cache/` by the provision script
via env vars and cache helpers.

### Disabling the cache

```bash
sudo ./provision_strix_halo.sh --force --no-cache
```

### Using a custom cache directory

```bash
sudo ./provision_strix_halo.sh --force --cache-dir=/mnt/fast-ssd/cache
sudo ./scripts/backup-caches.sh /mnt/fast-ssd/cache
sudo ./scripts/restore-caches.sh /mnt/fast-ssd/cache
```

## Remote access

All services bind to localhost or LAN only. Access from outside requires
SSH tunneling:

```bash
# RDP desktop
ssh -L 3389:localhost:3389 user@strix-host
# then connect your RDP client to localhost:3389

# llama.cpp API
ssh -L 11234:localhost:11234 user@strix-host
curl http://localhost:11234/v1/models

# ComfyUI
ssh -L 8188:localhost:8188 user@strix-host

# ACE Step
ssh -L 7860:localhost:7860 user@strix-host

# WordPress
ssh -L 8080:localhost:8080 user@strix-host

# LM Studio GUI (X11 forwarding)
ssh -X user@strix-host lmstudio
```

## Service management

System-level services (run as root):

```bash
sudo systemctl status comfyui llamacpp ace-step cisco-defense sync-llama-models
sudo journalctl -u comfyui -f
```

User-level services (rootless podman quadlets):

```bash
# Hosting stack (user: hosting)
sudo -u hosting XDG_RUNTIME_DIR=/run/user/$(id -u hosting) \
  systemctl --user status hosting.target supabase wordpress

# OpenClaw (user: claw)
sudo -u claw XDG_RUNTIME_DIR=/run/user/$(id -u claw) \
  systemctl --user status openclaw

# DDNS (user: ddns)
sudo -u ddns XDG_RUNTIME_DIR=/run/user/$(id -u ddns) \
  systemctl --user status ddns-*
```

## Uploading models

```bash
# Upload to ComfyUI models directory
rsync -avP -e ssh \
  --rsync-path="sudo -u comfyui /usr/local/bin/comfyui-rsync-wrapper" \
  model.safetensors user@strix-host:/home/comfyui/ComfyUI/models/checkpoints/

# Shared model directory (accessible by all AI services)
rsync -avP model.gguf user@strix-host:/models/
```

## Security model

- **SSH**: Public-key + password (two-factor for ecryptfs home decryption).
  Root login via key only (`prohibit-password`). fail2ban bans after 5
  failed attempts.
- **Firewall**: UFW default-deny. SSH rate-limited from anywhere. All ports
  open from private networks (10.x, 172.16-31.x, 192.168.x) and
  Tailscale (100.64.x).
- **Service isolation**: Each service runs as its own user (`comfyui`,
  `llamacpp`, `hosting`, `ddns`, `claw`, `defense`). Podman containers
  run rootless.
- **GPU access**: Service users are in the `ai-users`, `render`, and
  `video` groups.

## Tests

The test suite uses [Bats](https://github.com/bats-core/bats-core) and
runs in Docker (no root required on the host):

```bash
# Run all tests in Docker
./tests/run-tests.sh

# Run a specific test file
./tests/run-tests.sh test_cache_helpers.bats

# Run tests locally (inside container or CI)
./tests/run-tests.sh --local

# Full VM end-to-end test (requires KVM + GPU passthrough)
./tests/run-tests.sh --vm
```

## User accounts

| User | Purpose | Home |
|------|---------|------|
| `comfyui` | ComfyUI, Z-Image, ACE Step | `/home/comfyui` |
| `llamacpp` | llama.cpp server | `/home/llamacpp` |
| `claw` | OpenClaw gateway | `/home/claw` |
| `hosting` | Supabase + WordPress (podman) | `/home/hosting` |
| `ddns` | DDNS updater (podman) | `/home/ddns` |
| `defense` | Cisco AI Defense daemon | `/home/defense` |
