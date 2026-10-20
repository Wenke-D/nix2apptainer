{ apptainer-tools, coreutils }:

apptainer-tools.buildLayer {
  name = "coreutils";
  contents = [ coreutils ];
}
