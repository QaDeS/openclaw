{ config, lib, pkgs, ... }:

let
  cfg = config.services.strixHalo.llmStack;
  baseCfg = config.services.strixHalo.base;

  syncLlamaModelsScript = pkgs.writeShellScript "sync-llama-models" ''
    set -euo pipefail
    MODELS_SRC="''${MODELS_SRC:-/models}"
    MODELS_DST="''${MODELS_DST:-/llama_models}"
    DEBOUNCE_SEC="''${DEBOUNCE_SEC:-3}"

    log() { echo "[sync-llama-models] $(date '+%H:%M:%S') $1"; }

    sync_models() {
        mkdir -p "$MODELS_DST"
        local added=0 removed=0

        for link in "$MODELS_DST"/*; do
            [ -L "$link" ] || continue
            if [ ! -e "$link" ]; then
                log "REMOVE (stale): $(basename "$link")"
                rm -f "$link"
                ((removed++)) || true
            fi
        done

        while IFS= read -r dir; do
            shopt -s nullglob
            ggufs=("$dir"/*.gguf)
            shopt -u nullglob
            [[ ''${#ggufs[@]} -eq 0 ]] && continue
            dirname=$(basename "$dir")
            has_mmproj=false
            for f in "''${ggufs[@]}"; do
                [[ "$(basename "$f")" == mmproj* ]] && { has_mmproj=true; break; }
            done
            if $has_mmproj; then
                target="$MODELS_DST/$dirname"
                if [ ! -e "$target" ]; then
                    ln -s "$dir" "$target"
                    log "LINK DIR:  $dirname -> $dir"
                    ((added++)) || true
                fi
            else
                for f in "''${ggufs[@]}"; do
                    fname=$(basename "$f")
                    target="$MODELS_DST/$fname"
                    if [ ! -e "$target" ]; then
                        ln -s "$f" "$target"
                        log "LINK FILE: $fname -> $f"
                        ((added++)) || true
                    fi
                done
            fi
        done < <(${pkgs.findutils}/bin/find "$MODELS_SRC" -mindepth 2 -maxdepth 3 -type d \
                    ! -path "$MODELS_SRC/models" ! -path "$MODELS_SRC/models/*" 2>/dev/null | sort)

        log "Sync complete: +''${added} added, -''${removed} stale removed ($(ls "$MODELS_DST" 2>/dev/null | wc -l) total)"
    }

    log "Models source: $MODELS_SRC"
    log "Models dest:   $MODELS_DST"
    sync_models

    if [[ "''${1:-}" == "--watch" ]]; then
        log "Watching $MODELS_SRC for changes (debounce: ''${DEBOUNCE_SEC}s)..."
        while true; do
            ${pkgs.inotify-tools}/bin/inotifywait -r -q \
                -e create -e delete -e moved_to -e moved_from -e close_write \
                --exclude '/\.' "$MODELS_SRC" >/dev/null 2>&1
            log "Change detected, waiting ''${DEBOUNCE_SEC}s to settle..."
            sleep "$DEBOUNCE_SEC"
            ${pkgs.coreutils}/bin/timeout 1 ${pkgs.inotify-tools}/bin/inotifywait -r -q \
                -e create -e delete -e moved_to -e moved_from -e close_write \
                --exclude '/\.' "$MODELS_SRC" >/dev/null 2>&1 || true
            sync_models
        done
    fi
  '';
in
{
  options.services.strixHalo.llmStack = {
    enable = lib.mkEnableOption "LLM inference stack";

    llamacpp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable llama.cpp server with Vulkan backend.";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 11234;
        description = "llama.cpp server listen port.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
      };

      contextSize = lib.mkOption {
        type = lib.types.int;
        default = 204800;
        description = "Context window size (-c flag).";
      };

      gpuLayers = lib.mkOption {
        type = lib.types.int;
        default = 99;
        description = "Number of GPU layers (-ngl flag).";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "-fa" "on" ];
        description = "Extra arguments for llama-server.";
      };
    };

    syncModels = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable sync-llama-models watcher service.";
      };
    };

    ollama = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Ollama server.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # llama.cpp server
    (lib.mkIf cfg.llamacpp.enable {
      # User for llama.cpp
      users.users.llamacpp = {
        isSystemUser = true;
        group = "llamacpp";
        home = "/home/llamacpp";
        createHome = true;
        shell = pkgs.bash;
        extraGroups = [ "ai-users" "render" "video" ];
      };
      users.groups.llamacpp = {};

      # llama.cpp built with Vulkan support
      environment.systemPackages = [
        (pkgs.llama-cpp.override { vulkanSupport = true; })
      ];

      # Symlink models dir for the llamacpp user
      systemd.tmpfiles.rules = [
        "L /home/llamacpp/models - - - - /models"
      ];

      systemd.services.llamacpp = {
        description = "llama.cpp Server (Vulkan)";
        after = [ "network-online.target" "sync-llama-models.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          User = "llamacpp";
          Group = "llamacpp";
          ExecStart = lib.concatStringsSep " " ([
            "${(pkgs.llama-cpp.override { vulkanSupport = true; })}/bin/llama-server"
            "--models-dir /llama_models"
            "--host ${cfg.llamacpp.host}"
            "--port ${toString cfg.llamacpp.port}"
            "-ngl ${toString cfg.llamacpp.gpuLayers}"
            "-c ${toString cfg.llamacpp.contextSize}"
          ] ++ cfg.llamacpp.extraArgs);

          Restart = "always";
          RestartSec = 5;
          StartLimitIntervalSec = 60;
          StartLimitBurst = 5;

          NoNewPrivileges = true;
          ProtectHome = "read-only";
          ReadOnlyPaths = [ "/models" "/llama_models" ];
        };

        environment = {
          GGML_VK_VISIBLE_DEVICES = "0";
        };
      };
    })

    # Model sync watcher
    (lib.mkIf cfg.syncModels.enable {
      systemd.services.sync-llama-models = {
        description = "Sync /models to flat /llama_models for llama.cpp";
        after = [ "local-fs.target" ];
        before = [ "llamacpp.service" ];
        wants = lib.optional cfg.llamacpp.enable "llamacpp.service";
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStartPre = "${syncLlamaModelsScript}";
          ExecStart = "${syncLlamaModelsScript} --watch";
          Restart = "always";
          RestartSec = 10;
        };

        path = [ pkgs.inotify-tools pkgs.findutils pkgs.coreutils ];
      };
    })

    # Ollama
    (lib.mkIf cfg.ollama.enable {
      services.ollama = {
        enable = true;
        acceleration = "rocm";
        environmentVariables = {
          HSA_OVERRIDE_GFX_VERSION = baseCfg.hsaOverrideGfxVersion;
        };
      };
    })
  ]);
}
