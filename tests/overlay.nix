{ nix2apptainer, coreutils }:

nix2apptainer.buildOverlay {
  name = "coreutils";
  contents = [ coreutils ];
}
