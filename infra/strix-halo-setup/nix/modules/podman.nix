{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.podman;
in
{
  options.services.strixHalo.podman = {
    enable = lib.mkEnableOption "Podman rootless container runtime";
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    # Rootless podman requires user namespaces
    security.unprivilegedUsernsClone = true;

    environment.systemPackages = with pkgs; [
      podman-compose
    ];
  };
}
