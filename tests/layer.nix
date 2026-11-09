{ nix2apptainer, coreutils }:

nix2apptainer.buildLayer {
  name = "coreutils";
  contents = [ coreutils ];
}
