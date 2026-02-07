# Strix Halo Setup: Verification Walkthrough

Follow these steps to ensure your "round package" is correctly deployed and functional.

## Step 1: Run Provisioning

Execute the script with the force flag to apply all changes:

```bash
sudo ./provision_strix_halo.sh --force
```

## Step 2: Reboot & Check Drivers

After rebooting:

```bash
# Check for Strix Halo GPU
rocminfo | grep GFX

# Verify Kernel version (Expected 6.18+)
uname -r
```

## Step 3: Verify Persistence

All services should be `active (running)`:

```bash
sudo systemctl status llmster comfyui cisco-defense openclaw hosting
```

## Step 4: Access Remote GUI

1. Connect via RDP from your laptop.
2. Launch LM Studio: `/home/lmstudio/bin/lm-studio.AppImage`.
3. Verify models are being downloaded to `/opt/ai/models` (or linked via `~/.cache/lm-studio/models`).

## Step 5: Test OpenClaw Integration

Check if OpenClaw can reach the LM Studio server locally:

```bash
curl http://localhost:1234/v1/models
```

## Step 6: Monitor Resources

Use `rocm-smi` to watch your APU's memory and compute usage as you load models into both LM Studio and ComfyUI.
