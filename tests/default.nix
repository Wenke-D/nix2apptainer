# The flake's checks: example images, one per file, each saying how to run it
{ pkgs, apptainer-tools }:

let
  callTest = file: args: pkgs.callPackage file ({ inherit apptainer-tools; } // args);
in
rec {
  image = callTest ./image.nix { };
  layer = callTest ./layer.nix { };
  layered-image = callTest ./layered-image.nix { inherit layer; };
}
