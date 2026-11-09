# Last run as each file's comment shows on x86_64-linux with Apptainer 1.5.3.
{ pkgs, nix2apptainer }:

let
  callTest = file: args: pkgs.callPackage file ({ inherit nix2apptainer; } // args);
in
rec {
  image = callTest ./image.nix { };
  overlay = callTest ./overlay.nix { };
  overlaid-image = callTest ./overlaid-image.nix { inherit overlay; };
}
