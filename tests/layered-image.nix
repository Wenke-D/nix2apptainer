# An image on the layer of layer.nix.  It holds hello and the shell but not
# glibc, which is in the layer, so it runs only with the layer as an overlay:
#
#   nix build .#checks.x86_64-linux.layer -o coreutils.sqfs
#   nix build .#checks.x86_64-linux.layered-image -o hello-layered.sif
#   apptainer run --overlay coreutils.sqfs:ro hello-layered.sif         # Hello, world!
#   apptainer exec --overlay coreutils.sqfs:ro hello-layered.sif ls /   # ls from the layer
#   apptainer run hello-layered.sif     # error: this image needs the layer ...-coreutils.sqfs
{
  apptainer-tools,
  layer,
  hello,
}:

apptainer-tools.buildImage {
  name = "hello-layered";
  contents = [ hello ];
  layers = [ layer ];
  runScript = ''exec hello "$@"'';
}
