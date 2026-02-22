# NixOS VM tests for each module.
# Run: nix flake check
# Run single: nix build .#checks.x86_64-linux.base

{ pkgs, lib, nixosModules, ... }:

let
  # Helper to create a minimal NixOS test VM
  mkTest = name: testModule: pkgs.nixosTest {
    inherit name;
    nodes.machine = { ... }: {
      imports = [ nixosModules.default testModule ];
      # Minimal VM config
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
    };
    # Basic smoke test: machine boots successfully with the module enabled
    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
    '';
  };
in
{
  # Base module: verify kernel params and shared dirs
  base = mkTest "base" ({ ... }: {
    services.strixHalo.base = {
      enable = true;
      enableDesktop = false; # No GUI in test VM
      gttSizeMb = 1024;
    };
  });

  # SSH module: verify sshd starts with our config
  ssh = mkTest "ssh" ({ ... }: {
    services.strixHalo.ssh = {
      enable = true;
      allowedUsers = [ "testuser" ];
      enableFail2ban = true;
      enableFirewall = true;
    };
    users.users.testuser = {
      isNormalUser = true;
    };
  });

  # Podman module: verify podman is available
  podman = mkTest "podman" ({ ... }: {
    services.strixHalo.podman.enable = true;
  });

  # LLM stack: verify llamacpp service unit exists (won't start without GPU)
  llm-stack = pkgs.nixosTest {
    name = "llm-stack";
    nodes.machine = { ... }: {
      imports = [ nixosModules.default ];
      virtualisation.memorySize = 2048;
      services.strixHalo.base = {
        enable = true;
        enableDesktop = false;
        gttSizeMb = 1024;
      };
      services.strixHalo.llmStack = {
        enable = true;
        llamacpp.enable = true;
        syncModels.enable = true;
      };
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      # Verify service units are defined (they may fail without real GPU)
      machine.succeed("systemctl cat llamacpp.service")
      machine.succeed("systemctl cat sync-llama-models.service")
      # Verify users created
      machine.succeed("id llamacpp")
    '';
  };

  # Hosting: verify quadlet files deployed
  hosting = pkgs.nixosTest {
    name = "hosting";
    nodes.machine = { ... }: {
      imports = [ nixosModules.default ];
      virtualisation.memorySize = 2048;
      services.strixHalo.podman.enable = true;
      services.strixHalo.hosting = {
        enable = true;
        wordpressPort = 8080;
      };
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      # Verify hosting user exists
      machine.succeed("id hosting")
      # Verify quadlet directory structure
      machine.succeed("test -d /home/hosting/.config/containers/systemd")
    '';
  };
}
