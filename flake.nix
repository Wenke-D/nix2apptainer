{
  description = "Apptainer (SIF) images from Nix store paths, built in the Nix sandbox";

  # Only for the checks: the functions themselves take the caller's packages.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # pkgs.apptainer-tools.  Without the overlay, from a flake that has this
      # one as the input apptainer-tools: pkgs.callPackage apptainer-tools { }
      overlays.default = final: prev: {
        apptainer-tools = final.callPackage ./. { };
      };

      # Example images (tests/), which build only if the functions work
      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs;
          apptainer-tools = pkgs.callPackage ./. { };
        }
      );
    };
}
