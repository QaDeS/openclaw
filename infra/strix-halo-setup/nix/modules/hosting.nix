{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.hosting;

  hostingHome = "/home/hosting";
  quadletDir = "${hostingHome}/.config/containers/systemd";
  userSystemdDir = "${hostingHome}/.config/systemd/user";

  networkFile = ''
    [Network]
    NetworkName=hosting-net
    Driver=bridge

    [Install]
    WantedBy=default.target
  '';

  volumeFile = ''
    [Volume]
    VolumeName=supabase-data
  '';

  supabaseContainer = ''
    [Unit]
    Description=Supabase PostgreSQL
    After=hosting-net.service supabase-data.service
    PartOf=hosting.target

    [Container]
    Image=supabase/postgres:latest
    ContainerName=supabase_db
    Network=hosting-net.network
    Volume=supabase-data.volume:/var/lib/postgresql/data
    Environment=POSTGRES_PASSWORD=PLACEHOLDER_DB_PASSWORD
    AutoUpdate=registry

    [Install]
    WantedBy=hosting.target
  '';

  wordpressContainer = ''
    [Unit]
    Description=WordPress Multisite
    After=supabase.service
    PartOf=hosting.target

    [Container]
    Image=wordpress:latest
    ContainerName=wordpress_multisite
    Network=hosting-net.network
    PublishPort=${toString cfg.wordpressPort}:80
    Environment=WORDPRESS_DB_HOST=supabase_db:5432
    Environment=WORDPRESS_DB_USER=postgres
    Environment=WORDPRESS_DB_PASSWORD=PLACEHOLDER_DB_PASSWORD
    AutoUpdate=registry

    [Install]
    WantedBy=hosting.target
  '';

  hostingTarget = ''
    [Unit]
    Description=Hosting Stack (Supabase + WordPress)

    [Install]
    WantedBy=default.target
  '';
in
{
  options.services.strixHalo.hosting = {
    enable = lib.mkEnableOption "Hosting stack (Supabase + WordPress via Podman quadlets)";

    dbPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to agenix-decrypted file containing the Supabase DB password.";
    };

    wordpressPort = lib.mkOption {
      type = lib.types.int;
      default = 8080;
      description = "Host port for WordPress.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Hosting user
    users.users.hosting = {
      isSystemUser = true;
      group = "hosting";
      home = hostingHome;
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "ai-users" ];
      linger = true;
    };
    users.groups.hosting = {};

    # Ensure directories
    systemd.tmpfiles.rules = [
      "d ${hostingHome}/.config 0755 hosting hosting -"
      "d ${hostingHome}/.config/containers 0755 hosting hosting -"
      "d ${quadletDir} 0755 hosting hosting -"
      "d ${hostingHome}/.config/systemd 0755 hosting hosting -"
      "d ${userSystemdDir} 0755 hosting hosting -"
    ];

    # Deploy quadlet files + hosting.target via activation
    system.activationScripts.hosting-quadlets = lib.stringAfter [ "users" "groups" ] ''
      # Network
      install -m 0644 -o hosting -g hosting /dev/stdin ${quadletDir}/hosting-net.network <<'EOF'
      ${networkFile}
      EOF

      # Volume
      install -m 0644 -o hosting -g hosting /dev/stdin ${quadletDir}/supabase-data.volume <<'EOF'
      ${volumeFile}
      EOF

      # Supabase container — substitute password from secret file if available
      SUPABASE_CONTENT='${supabaseContainer}'
      ${lib.optionalString (cfg.dbPasswordFile != null) ''
        if [ -f ${toString cfg.dbPasswordFile} ]; then
          DB_PASS=$(cat ${toString cfg.dbPasswordFile})
          SUPABASE_CONTENT=$(echo "$SUPABASE_CONTENT" | sed "s/PLACEHOLDER_DB_PASSWORD/$DB_PASS/g")
        fi
      ''}
      echo "$SUPABASE_CONTENT" | install -m 0644 -o hosting -g hosting /dev/stdin ${quadletDir}/supabase.container

      # WordPress container — same password substitution
      WP_CONTENT='${wordpressContainer}'
      ${lib.optionalString (cfg.dbPasswordFile != null) ''
        if [ -f ${toString cfg.dbPasswordFile} ]; then
          DB_PASS=$(cat ${toString cfg.dbPasswordFile})
          WP_CONTENT=$(echo "$WP_CONTENT" | sed "s/PLACEHOLDER_DB_PASSWORD/$DB_PASS/g")
        fi
      ''}
      echo "$WP_CONTENT" | install -m 0644 -o hosting -g hosting /dev/stdin ${quadletDir}/wordpress.container

      # Hosting target (plain systemd, not quadlet)
      install -m 0644 -o hosting -g hosting /dev/stdin ${userSystemdDir}/hosting.target <<'EOF'
      ${hostingTarget}
      EOF
    '';
  };
}
