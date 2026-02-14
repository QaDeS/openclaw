# ROCm overlay
#
# nixpkgs-unstable typically tracks ROCm closely. This overlay is a stub
# for pinning or patching ROCm packages if nixpkgs lags behind 7.2.
#
# To activate: uncomment the version override below and adjust as needed.
# The overlay is already wired into flake.nix.

final: prev: {
  # Uncomment and adjust if nixpkgs ROCm < 7.2:
  #
  # rocmPackages = prev.rocmPackages.overrideScope (rfinal: rprev: {
  #   # Example: pin rocminfo to a specific version
  #   # rocminfo = rprev.rocminfo.overrideAttrs (old: {
  #   #   version = "7.2.0";
  #   #   src = prev.fetchFromGitHub {
  #   #     owner = "ROCm";
  #   #     repo = "rocminfo";
  #   #     rev = "rocm-7.2.0";
  #   #     hash = "sha256-AAAA...";
  #   #   };
  #   # });
  # });
}
