{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.ssh;
in
{
  options.services.strixHalo.ssh = {
    enable = lib.mkEnableOption "SSH hardening with ecryptfs-safe key storage";

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "mk" "claw" ];
      description = "Users allowed SSH access. Keys stored outside ecryptfs.";
    };

    permitRootLogin = lib.mkOption {
      type = lib.types.str;
      default = "prohibit-password";
      description = "PermitRootLogin setting.";
    };

    maxAuthTries = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Maximum SSH authentication attempts.";
    };

    disablePasswordAuth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable password authentication (only enable if key-based auth confirmed working).";
    };

    enableFail2ban = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fail2ban SSH jail.";
    };

    fail2banMaxRetry = lib.mkOption {
      type = lib.types.int;
      default = 5;
    };

    fail2banBanTime = lib.mkOption {
      type = lib.types.str;
      default = "3600";
    };

    fail2banFindTime = lib.mkOption {
      type = lib.types.str;
      default = "600";
    };

    enableFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NixOS firewall with SSH rate-limiting and private network access.";
    };

    upnpPort = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "External UPnP port for SSH. null = disabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    # SSH server configuration
    services.openssh = {
      enable = true;
      settings = {
        # Store authorized_keys outside ecryptfs-encrypted home
        AuthorizedKeysFile = "/etc/ssh/users/%u/.ssh/authorized_keys .ssh/authorized_keys";
        PermitRootLogin = cfg.permitRootLogin;
        PubkeyAuthentication = "yes";
        MaxAuthTries = cfg.maxAuthTries;
        PasswordAuthentication = !cfg.disablePasswordAuth;
        KbdInteractiveAuthentication = !cfg.disablePasswordAuth;
      };
    };

    # Create /etc/ssh/users/<user>/.ssh/ for each allowed user
    systemd.tmpfiles.rules = lib.concatMap (user: [
      "d /etc/ssh/users/${user} 0755 ${user} ${user} -"
      "d /etc/ssh/users/${user}/.ssh 0700 ${user} ${user} -"
      "f /etc/ssh/users/${user}/.ssh/authorized_keys 0600 ${user} ${user} -"
    ]) cfg.allowedUsers;

    # PAM: NixOS doesn't include pam_ecryptfs by default.
    # On Ubuntu, the bash scripts comment out pam_ecryptfs lines in /etc/pam.d/sshd.
    # On NixOS this is a non-issue since PAM is declarative and ecryptfs modules
    # aren't included unless explicitly enabled.

    # Profile script: auto-mount ecryptfs after login if available
    environment.etc."profile.d/ecryptfs-mount.sh" = {
      mode = "0644";
      text = ''
        # Auto-mount ecryptfs private dir after SSH login
        if command -v ecryptfs-mount-private &>/dev/null; then
          if [ -d "$HOME/.Private" ] && [ ! -d "$HOME/Private" -o -z "$(ls -A "$HOME/Private" 2>/dev/null)" ]; then
            ecryptfs-mount-private 2>/dev/null || true
          fi
        fi
      '';
    };

    # SSH user setup hook: script run when new users are created
    environment.etc."local/sbin/setup-ssh-for-user" = {
      mode = "0755";
      text = ''
        #!/bin/bash
        # Create SSH key directory outside home for new users
        USER="$1"
        [ -z "$USER" ] && exit 0
        SSH_DIR="/etc/ssh/users/$USER/.ssh"
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        touch "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        chown -R "$USER:$USER" "/etc/ssh/users/$USER"
      '';
    };

    # Fail2ban
    services.fail2ban = lib.mkIf cfg.enableFail2ban {
      enable = true;
      jails.sshd = {
        settings = {
          enabled = true;
          maxretry = cfg.fail2banMaxRetry;
          bantime = cfg.fail2banBanTime;
          findtime = cfg.fail2banFindTime;
          filter = "sshd";
          action = "iptables-multiport[name=SSH, port=ssh, protocol=tcp]";
        };
      };
    };

    # Firewall
    networking.firewall = lib.mkIf cfg.enableFirewall {
      enable = true;
      allowedTCPPorts = [ 22 ];
      # Allow all traffic from private networks + Tailscale
      trustedInterfaces = [];
      extraCommands = ''
        # Private networks (LAN access)
        iptables -A INPUT -s 10.0.0.0/8 -j ACCEPT
        iptables -A INPUT -s 172.16.0.0/12 -j ACCEPT
        iptables -A INPUT -s 192.168.0.0/16 -j ACCEPT
        # Tailscale CGNAT range
        iptables -A INPUT -s 100.64.0.0/10 -j ACCEPT
      '';
    };

    # UPnP SSH port forwarding timer
    systemd.services.upnp-ssh = lib.mkIf (cfg.upnpPort != null) {
      description = "Refresh UPnP SSH port mapping";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          script = pkgs.writeShellScript "upnp-ssh-refresh" ''
            ${pkgs.miniupnpc}/bin/upnpc -d ${toString cfg.upnpPort} TCP 2>/dev/null || true
            ${pkgs.miniupnpc}/bin/upnpc -e "SSH Strix Halo" -r 22 ${toString cfg.upnpPort} TCP 3600
          '';
        in "${script}";
      };
    };

    systemd.timers.upnp-ssh = lib.mkIf (cfg.upnpPort != null) {
      description = "Periodic UPnP SSH port mapping refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30min";
        Unit = "upnp-ssh.service";
      };
    };

    environment.systemPackages = lib.optionals (cfg.upnpPort != null) [
      pkgs.miniupnpc
    ];
  };
}
