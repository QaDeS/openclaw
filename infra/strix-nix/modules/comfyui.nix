{ config, lib, pkgs, strixLib ? {}, ... }:

let
  cfg = config.services.strixHalo.comfyui;
  baseCfg = config.services.strixHalo.base;

  comfyuiHome = "/home/comfyui";
  comfyuiDir = "${comfyuiHome}/ComfyUI";
  venvPath = "${comfyuiDir}/.venv";
  torchIndexUrl = "https://rocm.nightlies.amd.com/v2/gfx1151/";

  # Requirements for the ROCm venv — torch must be first to avoid CUDA fallback
  requirements = [
    "torch"
    "torchvision"
    "torchaudio"
  ];

  reqHash = builtins.hashString "sha256"
    (lib.concatStringsSep "\n" (lib.sort builtins.lessThan requirements));
  markerFile = "${venvPath}/.nix-marker-${reqHash}";
in
{
  options.services.strixHalo.comfyui = {
    enable = lib.mkEnableOption "ComfyUI image generation backend (ROCm)";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/comfyanonymous/ComfyUI.git";
    };

    managerRepo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/ltdrdata/ComfyUI-Manager.git";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 8188;
    };
  };

  config = lib.mkIf cfg.enable {
    # Service user
    users.users.comfyui = {
      isSystemUser = true;
      group = "comfyui";
      home = comfyuiHome;
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "ai-users" "render" "video" ];
    };
    users.groups.comfyui = {};

    # Clone ComfyUI + Manager on first boot
    systemd.services.comfyui-clone = {
      description = "Clone ComfyUI repository";
      wantedBy = [ "multi-user.target" ];
      before = [ "comfyui-setup.service" ];
      requiredBy = [ "comfyui-setup.service" ];
      unitConfig.ConditionPathExists = "!${comfyuiDir}";

      serviceConfig = {
        Type = "oneshot";
        User = "comfyui";
        Group = "comfyui";
        RemainAfterExit = true;
      };

      path = [ pkgs.git pkgs.openssh ];

      script = ''
        set -euo pipefail
        git clone --depth 1 ${cfg.repo} ${comfyuiDir}
        git clone --depth 1 ${cfg.managerRepo} ${comfyuiDir}/custom_nodes/ComfyUI-Manager

        # ComfyUI-Manager settings
        mkdir -p ${comfyuiDir}/user/default
        cat > ${comfyuiDir}/user/default/comfy.settings.json <<'JSON'
        {
          "ComfyUI-Manager.ModelDownloadMethod": "server-only"
        }
        JSON
      '';
    };

    # Impure venv setup — installs ROCm PyTorch from nightlies
    systemd.services.comfyui-setup = {
      description = "ComfyUI ROCm venv setup";
      wantedBy = [ "multi-user.target" ];
      before = [ "comfyui.service" ];
      requiredBy = [ "comfyui.service" ];
      unitConfig.ConditionPathExists = "!${markerFile}";

      serviceConfig = {
        Type = "oneshot";
        User = "comfyui";
        Group = "comfyui";
        WorkingDirectory = comfyuiDir;
        RemainAfterExit = true;
        # Generous timeout for large pip installs
        TimeoutStartSec = "30min";
      };

      path = [ pkgs.git pkgs.curl pkgs.stdenv.cc ];

      script = ''
        set -euo pipefail
        export PATH="$HOME/.local/bin:$PATH"

        # Install uv if not present
        if ! command -v uv &>/dev/null; then
          curl -LsSf https://astral.sh/uv/install.sh | sh
          export PATH="$HOME/.local/bin:$PATH"
        fi

        echo "Creating ComfyUI venv at ${venvPath}..."
        uv --no-config venv --clear ${venvPath}
        source ${venvPath}/bin/activate

        # ROCm PyTorch first (before requirements.txt pulls CUDA torch)
        echo "Installing ROCm PyTorch..."
        uv --no-config pip install \
          --extra-index-url ${torchIndexUrl} \
          torch torchvision torchaudio

        # Verify ROCm torch
        python -c "import torch; assert hasattr(torch.version, 'hip'), 'Expected ROCm torch'" || {
          echo "ERROR: Got CUDA torch instead of ROCm. Reinstalling..."
          uv --no-config pip install --force-reinstall \
            --extra-index-url ${torchIndexUrl} \
            torch torchvision torchaudio
        }

        # ComfyUI dependencies
        echo "Installing ComfyUI requirements..."
        uv --no-config pip install -r ${comfyuiDir}/requirements.txt

        # ComfyUI-Manager dependencies
        if [ -f ${comfyuiDir}/custom_nodes/ComfyUI-Manager/requirements.txt ]; then
          uv --no-config pip install -r ${comfyuiDir}/custom_nodes/ComfyUI-Manager/requirements.txt
        fi

        touch ${markerFile}
        echo "ComfyUI venv setup complete."
      '';
    };

    # Main ComfyUI service
    systemd.services.comfyui = {
      description = "ComfyUI Backend Service";
      after = [ "network.target" "comfyui-setup.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "comfyui";
        Group = "comfyui";
        WorkingDirectory = comfyuiDir;
        ExecStart = "${venvPath}/bin/python main.py --listen ${cfg.listenAddress} --port ${toString cfg.port}";
        Restart = "always";
        RestartSec = 10;
      };

      environment = {
        HSA_OVERRIDE_GFX_VERSION = baseCfg.hsaOverrideGfxVersion;
        PYTORCH_ALLOC_CONF = "expandable_segments:True";
      };
    };

    # Operator can rsync files as comfyui user without password
    security.sudo.extraRules = [{
      groups = [ "ai-users" ];
      commands = [{
        command = "${pkgs.rsync}/bin/rsync";
        options = [ "NOPASSWD" ];
      }];
      runAs = "comfyui";
    }];
  };
}
