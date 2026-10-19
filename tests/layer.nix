# A layer holding the closure of coreutils, glibc included, for the image of
# layered-image.nix:
#
#   nix build .#checks.x86_64-linux.layer -o coreutils.sqfs
{ apptainer-tools, coreutils }:

apptainer-tools.buildLayer {
  name = "coreutils";
  contents = [ coreutils ];
}
