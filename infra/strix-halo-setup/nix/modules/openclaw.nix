{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.openclaw;

  clawHome = "/home/claw";
  openclawDir = "${clawHome}/openclaw";
  quadletDir = "${clawHome}/.config/containers/systemd";

  containerFile = ''
    [Unit]
    Description=OpenClaw Daemon

    [Container]
    Image=localhost/openclaw:latest
    ContainerName=openclaw_daemon
    Network=host
    Volume=${openclawDir}:/app
    Volume=${clawHome}/.openclaw:/root/.openclaw
    Environment=NODE_ENV=production
    Environment=LOCAL_LLM_URL=${cfg.localLlmUrl}

    [Service]
    Restart=on-failure
    RestartSec=10

    [Install]
    WantedBy=default.target
  '';
in
{
  options.services.strixHalo.openclaw = {
    enable = lib.mkEnableOption "OpenClaw daemon (Podman quadlet)";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/QaDeS/openclaw.git";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "strix";
    };

    localLlmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:11234/v1";
      description = "URL of the local LLM API endpoint.";
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to agenix-decrypted env file for OpenClaw secrets.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Service user
    users.users.claw = {
      isSystemUser = true;
      group = "claw";
      home = clawHome;
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "ai-users" "render" "video" ];
      linger = true;
    };
    users.groups.claw = {};

    # Ensure quadlet directory exists
    systemd.tmpfiles.rules = [
      "d ${clawHome}/.config 0755 claw claw -"
      "d ${clawHome}/.config/containers 0755 claw claw -"
      "d ${quadletDir} 0755 claw claw -"
      "d ${clawHome}/.openclaw 0700 claw claw -"
    ];

    # Clone repo + build container image on first boot
    systemd.services.openclaw-setup = {
      description = "Clone OpenClaw and build container image";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!${openclawDir}";

      serviceConfig = {
        Type = "oneshot";
        User = "claw";
        Group = "claw";
        RemainAfterExit = true;
        TimeoutStartSec = "15min";
      };

      path = with pkgs; [ git nodejs pnpm podman ];

      script = ''
        set -euo pipefail

        # Clone
        git clone --branch ${cfg.branch} --depth 1 ${cfg.repo} ${openclawDir}
        cd ${openclawDir}

        # Build
        pnpm install --frozen-lockfile
        pnpm build

        # Write env file
        cat > ${clawHome}/.openclaw/env <<ENV
        LOCAL_LLM_URL=${cfg.localLlmUrl}
        ENV

        # Build container image
        if [ -f docker/Dockerfile.openclaw ]; then
          podman build -t localhost/openclaw:latest -f docker/Dockerfile.openclaw .
        fi
      '';
    };

    # Deploy quadlet file via activation script
    system.activationScripts.openclaw-quadlet = lib.stringAfter [ "users" "groups" ] ''
      install -m 0644 -o claw -g claw /dev/stdin ${quadletDir}/openclaw.container <<'EOF'
      ${containerFile}
      EOF
    '';
  };
}
