# Concrete host configuration for the Strix Halo workstation.
# This enables all modules with machine-specific settings.

{ config, lib, pkgs, ... }:

{
  # Hardware — replace with your generated hardware-configuration.nix
  # imports = [ ./hardware-configuration.nix ];

  networking.hostName = "strix";

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ─── Strix Halo modules ───────────────────────────────────────────

  services.strixHalo.base = {
    enable = true;
    # 128 GB RAM → 64 GB GTT (half of total)
    gttSizeMb = 65536;
    enableDesktop = true;
  };

  services.strixHalo.ssh = {
    enable = true;
    allowedUsers = [ "mk" "claw" ];
    disablePasswordAuth = false; # Enable after confirming key-based auth works
    enableFail2ban = true;
    enableFirewall = true;
    # upnpPort = 2222; # Uncomment to enable UPnP SSH forwarding
  };

  services.strixHalo.podman.enable = true;

  services.strixHalo.llmStack = {
    enable = true;
    llamacpp = {
      enable = true;
      port = 11234;
      contextSize = 204800;
    };
    syncModels.enable = true;
    ollama.enable = false;
  };

  services.strixHalo.comfyui = {
    enable = true;
    port = 8188;
  };

  services.strixHalo.aceStep = {
    enable = true;
    port = 7860;
  };

  services.strixHalo.openclaw = {
    enable = true;
    branch = "strix";
    localLlmUrl = "http://localhost:11234/v1";
  };

  services.strixHalo.hosting = {
    enable = true;
    wordpressPort = 8080;
    # dbPasswordFile = config.age.secrets.supabase-db-password.path;
  };

  # services.strixHalo.ddns = {
  #   enable = true;
  #   fqdn = "home.example.com";
  #   passwordFile = config.age.secrets.ddns-password.path;
  # };

  # ─── agenix secrets ───────────────────────────────────────────────

  # age.secrets.supabase-db-password = {
  #   file = ../secrets/supabase-db-password.age;
  #   owner = "hosting";
  # };
  # age.secrets.ddns-password = {
  #   file = ../secrets/ddns-password.age;
  #   owner = "ddns";
  # };
  # age.secrets.openclaw-env = {
  #   file = ../secrets/openclaw-env.age;
  #   owner = "claw";
  # };

  # ─── Users ─────────────────────────────────────────────────────────

  users.users.mk = {
    isNormalUser = true;
    extraGroups = [ "wheel" "ai-users" "render" "video" ];
    openssh.authorizedKeys.keys = [
      # Add your SSH public key(s) here
    ];
  };

  # ─── System ────────────────────────────────────────────────────────

  time.timeZone = "UTC";
  system.stateVersion = "24.11";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "mk" ];
  };

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    tmux
    curl
    wget
    ripgrep
    fd
  ];
}
