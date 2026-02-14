{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.aceStep;
  baseCfg = config.services.strixHalo.base;

  aceStepHome = "/home/comfyui/ACE-Step-1.5";
  venvPath = "${aceStepHome}/venv_rocm";
  torchIndexUrl = "https://rocm.nightlies.amd.com/v2/gfx1151/";

  requirements = [
    "torch"
    "torchvision"
    "torchaudio"
    "transformers>=4.51.0,<4.58.0"
    "diffusers"
    "accelerate>=1.12.0"
    "gradio==6.2.0"
    "fastapi"
    "uvicorn[standard]"
    "vector-quantize-pytorch"
    "numba"
    "einops"
    "scipy"
    "loguru"
  ];

  reqHash = builtins.hashString "sha256"
    (lib.concatStringsSep "\n" (lib.sort builtins.lessThan requirements));
  markerFile = "${venvPath}/.nix-marker-${reqHash}";

  requirementsTxt = pkgs.writeText "ace-step-requirements.txt"
    (lib.concatStringsSep "\n" requirements);
in
{
  options.services.strixHalo.aceStep = {
    enable = lib.mkEnableOption "ACE-Step 1.5 music generation (ROCm)";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/ACE-Step/ACE-Step-1.5.git";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 7860;
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
    };

    modelUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://huggingface.co/ACE-Step/ACE-Step-v1-3.5B/resolve/main/ace_step_1.5_turbo_aio.safetensors";
      description = "URL for the ACE-Step model checkpoint.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ACE-Step shares the comfyui user (same as bash provisioning)
    # comfyui user is created in comfyui.nix; if ace-step is used standalone,
    # ensure the user exists
    users.users.comfyui = {
      isSystemUser = true;
      group = "comfyui";
      home = "/home/comfyui";
      createHome = true;
      shell = pkgs.bash;
      extraGroups = [ "ai-users" "render" "video" ];
    };
    users.groups.comfyui = {};

    # Clone ACE-Step repo
    systemd.services.ace-step-clone = {
      description = "Clone ACE-Step 1.5 repository";
      wantedBy = [ "multi-user.target" ];
      before = [ "ace-step-setup.service" ];
      requiredBy = [ "ace-step-setup.service" ];
      unitConfig.ConditionPathExists = "!${aceStepHome}";

      serviceConfig = {
        Type = "oneshot";
        User = "comfyui";
        Group = "comfyui";
        RemainAfterExit = true;
      };

      path = [ pkgs.git pkgs.openssh ];

      script = ''
        set -euo pipefail
        git clone --depth 1 ${cfg.repo} ${aceStepHome}
        # Symlink checkpoints to shared models dir
        ln -sf /models ${aceStepHome}/checkpoints
      '';
    };

    # Impure venv setup — ROCm PyTorch from nightlies
    systemd.services.ace-step-setup = {
      description = "ACE-Step ROCm venv setup";
      wantedBy = [ "multi-user.target" ];
      before = [ "ace-step.service" ];
      requiredBy = [ "ace-step.service" ];
      unitConfig.ConditionPathExists = "!${markerFile}";

      serviceConfig = {
        Type = "oneshot";
        User = "comfyui";
        Group = "comfyui";
        WorkingDirectory = aceStepHome;
        RemainAfterExit = true;
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

        echo "Creating ACE-Step venv at ${venvPath}..."
        uv --no-config venv --clear --seed --python 3.11 ${venvPath}
        source ${venvPath}/bin/activate

        # ROCm PyTorch FIRST (before transitive deps pull CUDA)
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

        # Application requirements
        echo "Installing ACE-Step requirements..."
        uv --no-config pip install \
          --extra-index-url ${torchIndexUrl} \
          -r ${requirementsTxt}

        # Install nano-vllm with --no-deps (CUDA-specific wheel, we just need the Python code)
        if [ -d ${aceStepHome}/nano-vllm ]; then
          uv --no-config pip install --no-deps ${aceStepHome}/nano-vllm
        fi

        # Install ACE-Step itself with --no-deps to prevent re-resolving torch
        uv --no-config pip install --no-deps -e ${aceStepHome}

        touch ${markerFile}
        echo "ACE-Step venv setup complete."
      '';
    };

    # Main ACE-Step service
    systemd.services.ace-step = {
      description = "ACE Step 1.5 Music Generation Server";
      after = [ "network.target" "ace-step-setup.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "comfyui";
        Group = "comfyui";
        WorkingDirectory = aceStepHome;
        ExecStart = lib.concatStringsSep " " [
          "${venvPath}/bin/python"
          "-u"
          "acestep/acestep_v15_pipeline.py"
          "--port ${toString cfg.port}"
          "--server-name ${cfg.listenAddress}"
          "--backend pt"
          "--cpu_offload true"
        ];
        Restart = "always";
        RestartSec = 10;
      };

      environment = {
        ACESTEP_LM_BACKEND = "pt";
        TORCH_COMPILE_BACKEND = "eager";
        MIOPEN_FIND_MODE = "FAST";
        HSA_OVERRIDE_GFX_VERSION = baseCfg.hsaOverrideGfxVersion;
        PYTORCH_ALLOC_CONF = "expandable_segments:True";
      };
    };
  };
}
