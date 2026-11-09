# glibc is in the overlay, not in this image, so the image runs only with the
# overlay:
#
#   nix build .#checks.x86_64-linux.overlaid-image -o hello-overlaid
#   cd hello-overlaid
#   apptainer run --overlay coreutils.sqfs:ro hello-overlaid.sif         # Hello, world!
#   apptainer exec --overlay coreutils.sqfs:ro hello-overlaid.sif ls /   # ls from the overlay, no lib64
#   apptainer run hello-overlaid.sif     # error: overlay coreutils.sqfs is missing: ...
{
  nix2apptainer,
  overlay,
  hello,
}:

nix2apptainer.buildImage {
  name = "hello-overlaid";
  contents = [ hello ];
  overlays = [ overlay ];
  runScript = ''exec hello "$@"'';
  fhsCompat = false;
}
