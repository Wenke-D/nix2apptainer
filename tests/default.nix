{ pkgs, nix2apptainer }:

let
  callTest = file: args: pkgs.callPackage file ({ inherit nix2apptainer; } // args);
in
rec {
  image = callTest ./image.nix { };
  layer = callTest ./layer.nix { };
  layered-image = callTest ./layered-image.nix { inherit layer; };
}
