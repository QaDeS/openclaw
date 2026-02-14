{
  description = "Strix Halo AI workstation — NixOS provisioning";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, agenix, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ (import ./overlays/rocm.nix) ];
      };
      lib = nixpkgs.lib;
      strixLib = import ./lib { inherit lib pkgs; };
    in
    {
      nixosModules = {
        default = import ./modules;
        base = import ./modules/base.nix;
        ssh = import ./modules/ssh.nix;
        podman = import ./modules/podman.nix;
        llm-stack = import ./modules/llm-stack.nix;
        comfyui = import ./modules/comfyui.nix;
        ace-step = import ./modules/ace-step.nix;
        openclaw = import ./modules/openclaw.nix;
        hosting = import ./modules/hosting.nix;
        ddns = import ./modules/ddns.nix;
      };

      nixosConfigurations.strix = lib.nixosSystem {
        inherit system;
        specialArgs = { inherit strixLib agenix; };
        modules = [
          agenix.nixosModules.default
          ./modules
          ./hosts/strix.nix
        ];
      };

      checks.${system} = import ./checks {
        inherit pkgs lib;
        nixosModules = self.nixosModules;
      };
    };
}
