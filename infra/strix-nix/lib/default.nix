{ lib, pkgs, ... }:

{
  # Create a service user with standard AI workstation groups.
  # Returns an attrset suitable for users.users.<name>.
  mkServiceUser = { name, home ? "/home/${name}", extraGroups ? [] }:
    {
      isSystemUser = true;
      group = name;
      inherit home;
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "ai-users" "render" "video" ] ++ extraGroups;
    };

  # Deploy rootless Podman quadlet files for a given user.
  # quadlets: attrset of { "filename.container" = "file contents"; ... }
  # Returns tmpfiles rules + activation script snippets.
  mkUserQuadlets = { user, uid, quadlets }:
    let
      quadletDir = "/home/${user}/.config/containers/systemd";
      userSystemdDir = "/home/${user}/.config/systemd/user";
    in
    {
      # Ensure directories exist with correct ownership
      tmpfilesRules = [
        "d /home/${user}/.config 0755 ${user} ${user} -"
        "d /home/${user}/.config/containers 0755 ${user} ${user} -"
        "d ${quadletDir} 0755 ${user} ${user} -"
        "d /home/${user}/.config/systemd 0755 ${user} ${user} -"
        "d ${userSystemdDir} 0755 ${user} ${user} -"
      ];

      # Write quadlet files via activation script
      activationScript = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (filename: contents: ''
          install -m 0644 -o ${user} -g ${user} /dev/stdin ${quadletDir}/${filename} <<'QUADLET_EOF'
          ${contents}
          QUADLET_EOF
        '') quadlets
      );

      # Enable linger so user services start at boot
      lingerScript = ''
        ${pkgs.systemd}/bin/loginctl enable-linger ${user}
      '';
    };

  # Create an impure venv setup oneshot service.
  # The service creates a Python venv with ROCm PyTorch on first boot,
  # then writes a marker file keyed on a hash of the requirements.
  # Subsequent boots skip if the marker matches.
  mkImpureVenv = {
    name,                          # service name prefix
    user,                          # run-as user
    workDir,                       # where to create the venv
    venvPath ? "${workDir}/.venv", # venv location
    pythonVersion ? "3.11",        # python version for uv
    torchIndexUrl ? "https://rocm.nightlies.amd.com/v2/gfx1151/",
    requirements ? [],             # list of pip requirement strings
    extraPipArgs ? [],             # additional pip install flags
    preInstallScript ? "",         # run before pip install (in venv)
    postInstallScript ? "",        # run after pip install (in venv)
  }:
    let
      reqHash = builtins.hashString "sha256"
        (lib.concatStringsSep "\n" (lib.sort builtins.lessThan requirements));
      markerFile = "${venvPath}/.nix-marker-${reqHash}";
      requirementsTxt = pkgs.writeText "${name}-requirements.txt"
        (lib.concatStringsSep "\n" requirements);
    in
    {
      description = "${name} ROCm venv setup";
      wantedBy = [ "multi-user.target" ];
      before = [ "${name}.service" ];
      requiredBy = [ "${name}.service" ];
      unitConfig.ConditionPathExists = "!${markerFile}";

      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        WorkingDirectory = workDir;
        RemainAfterExit = true;
      };

      path = [ pkgs.git pkgs.curl ];

      script = ''
        set -euo pipefail

        # Install uv if not present
        if ! command -v uv &>/dev/null; then
          curl -LsSf https://astral.sh/uv/install.sh | sh
          export PATH="$HOME/.local/bin:$PATH"
        fi

        echo "Creating venv at ${venvPath}..."
        uv --no-config venv --clear ${lib.optionalString (pythonVersion != "") "--python ${pythonVersion}"} ${venvPath}

        source ${venvPath}/bin/activate

        ${preInstallScript}

        echo "Installing requirements from ROCm index..."
        uv --no-config pip install \
          --extra-index-url ${torchIndexUrl} \
          ${lib.concatStringsSep " " extraPipArgs} \
          -r ${requirementsTxt}

        ${postInstallScript}

        touch ${markerFile}
        echo "Venv setup complete."
      '';
    };
}
