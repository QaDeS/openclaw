{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.base;
in
{
  options.services.strixHalo.base = {
    enable = lib.mkEnableOption "Strix Halo base system (ROCm, GPU, desktop)";

    hsaOverrideGfxVersion = lib.mkOption {
      type = lib.types.str;
      default = "11.5.1";
      description = "HSA_OVERRIDE_GFX_VERSION for Strix Halo gfx1151.";
    };

    sharedModelDir = lib.mkOption {
      type = lib.types.str;
      default = "/models";
      description = "Shared model directory accessible by all AI services.";
    };

    gttSizeMb = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "amdgpu.gttsize kernel param in MB. null = auto (total_mem / 2).";
    };

    enableDesktop = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable XFCE desktop with xrdp for remote access.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Kernel parameters for AMD GPU
    boot.kernelParams = [
      "amdgpu.gttsize=${toString (
        if cfg.gttSizeMb != null
        then cfg.gttSizeMb
        # Default: half of 128GB = 65536 MB (adjust in hosts/strix.nix)
        else 65536
      )}"
    ];

    # ROCm packages
    hardware.amdgpu = {
      initrd.enable = true;
      opencl.enable = true;
    };

    # ROCm SDK and tools
    environment.systemPackages = with pkgs; [
      rocmPackages.rocminfo
      rocmPackages.rocm-smi
      rocmPackages.clr
      rocmPackages.hip-common
      vulkan-tools
      vulkan-loader
      vulkan-headers
      mesa
      clinfo
    ] ++ lib.optionals cfg.enableDesktop [
      xfce.xfce4-terminal
      xfce.thunar
    ];

    # Global HSA override via environment
    environment.variables = {
      HSA_OVERRIDE_GFX_VERSION = cfg.hsaOverrideGfxVersion;
    };

    # Shared model directory
    users.groups.ai-users = {};

    systemd.tmpfiles.rules = [
      # setgid directory so files inherit group ownership
      "d ${cfg.sharedModelDir} 2775 root ai-users -"
      # Flat symlink tree for llama.cpp (/llama_models → flat view of /models)
      "d /llama_models 0755 root ai-users -"
    ];

    # XFCE desktop + xrdp (bound to localhost only, access via SSH tunnel)
    services.xserver = lib.mkIf cfg.enableDesktop {
      enable = true;
      desktopManager.xfce.enable = true;
      displayManager.lightdm.enable = true;
      videoDrivers = [ "amdgpu" ];
    };

    services.xrdp = lib.mkIf cfg.enableDesktop {
      enable = true;
      defaultWindowManager = "xfce4-session";
      # Bind to localhost only — access via SSH tunnel
      port = 3389;
    };
  };
}
