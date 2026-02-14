{ ... }:

{
  imports = [
    ./base.nix
    ./ssh.nix
    ./podman.nix
    ./llm-stack.nix
    ./comfyui.nix
    ./ace-step.nix
    ./openclaw.nix
    ./hosting.nix
    ./ddns.nix
  ];
}
