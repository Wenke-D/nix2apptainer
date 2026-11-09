# glibc is in the layer, not in this image, so the image runs only with the
# layer as an overlay:
#
#   nix build .#checks.x86_64-linux.layer -o coreutils.sqfs
#   nix build .#checks.x86_64-linux.layered-image -o hello-layered.sif
#   apptainer run --overlay coreutils.sqfs:ro hello-layered.sif         # Hello, world!
#   apptainer exec --overlay coreutils.sqfs:ro hello-layered.sif ls /   # ls from the layer, no lib64
#   apptainer run hello-layered.sif     # error: this image needs the layer ...-coreutils.sqfs
{
  nix2apptainer,
  layer,
  hello,
}:

nix2apptainer.buildImage {
  name = "hello-layered";
  contents = [ hello ];
  layers = [ layer ];
  runScript = ''exec hello "$@"'';
  fhsCompat = false;
}
