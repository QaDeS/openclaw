{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.ddns;

  ddnsHome = "/home/ddns";
  quadletDir = "${ddnsHome}/.config/containers/systemd";

  # Split FQDN into host + domain parts for Namecheap API
  hostPart = lib.head (lib.splitString "." cfg.fqdn);
  domainPart = lib.concatStringsSep "."
    (lib.tail (lib.splitString "." cfg.fqdn));

  containerFile = fqdn: host: domain: ''
    [Unit]
    Description=Namecheap DDNS for ${fqdn}

    [Container]
    Image=linuxshots/namecheap-ddns
    ContainerName=ddns-${fqdn}
    Environment=DOMAIN=${domain}
    Environment=HOST=${host}
    Environment=PASSWORD=PLACEHOLDER_DDNS_PASSWORD
    AutoUpdate=registry

    [Service]
    Restart=on-failure
    RestartSec=30

    [Install]
    WantedBy=default.target
  '';
in
{
  options.services.strixHalo.ddns = {
    enable = lib.mkEnableOption "Namecheap Dynamic DNS updater (Podman quadlet)";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "home.example.com";
      description = "Fully qualified domain name for DDNS updates.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to agenix-decrypted file containing the Namecheap DDNS password.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.fqdn != "") {
    # DDNS user
    users.users.ddns = {
      isSystemUser = true;
      group = "ddns";
      home = ddnsHome;
      createHome = true;
      shell = pkgs.bash;
      linger = true;
    };
    users.groups.ddns = {};

    # Ensure directories
    systemd.tmpfiles.rules = [
      "d ${ddnsHome}/.config 0755 ddns ddns -"
      "d ${ddnsHome}/.config/containers 0755 ddns ddns -"
      "d ${quadletDir} 0755 ddns ddns -"
      "d ${ddnsHome}/.secrets 0700 ddns ddns -"
    ];

    # Deploy quadlet via activation
    system.activationScripts.ddns-quadlet = lib.stringAfter [ "users" "groups" ] ''
      DDNS_CONTENT='${containerFile cfg.fqdn hostPart domainPart}'
      ${lib.optionalString (cfg.passwordFile != null) ''
        if [ -f ${toString cfg.passwordFile} ]; then
          DDNS_PASS=$(cat ${toString cfg.passwordFile})
          DDNS_CONTENT=$(echo "$DDNS_CONTENT" | sed "s/PLACEHOLDER_DDNS_PASSWORD/$DDNS_PASS/g")
        fi
      ''}
      echo "$DDNS_CONTENT" | install -m 0600 -o ddns -g ddns /dev/stdin \
        ${quadletDir}/ddns-${cfg.fqdn}.container
    '';
  };
}
