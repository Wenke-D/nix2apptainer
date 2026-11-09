{
  description = "Generate apptainer image from Nix closure";

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
      lib.setup = pkgs: pkgs.callPackage ./. { };

      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs;
          nix2apptainer = self.lib.setup pkgs;
        }
      );
    };
}
