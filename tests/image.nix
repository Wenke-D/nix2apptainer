# An image of GNU hello, with environment, extraCommands and a compression
# level set:
#
#   nix build .#checks.x86_64-linux.image -o hello.sif
#   apptainer run hello.sif                             # Hello, world!
#   apptainer run hello.sif -g Bonjour                  # Bonjour
#   apptainer exec hello.sif sh -c 'echo "$QUOTED"'     # it's "quoted": $HOME `date` \
{ apptainer-tools, hello }:

apptainer-tools.buildImage {
  name = "hello";
  contents = [ hello ];
  runScript = ''exec hello "$@"'';

  # Read back as written, quotes, $, ` and \ included
  environment.QUOTED = "it's \"quoted\": \$HOME `date` \\";

  # A mount point for `--bind <dir>:/scratch`
  extraCommands = "mkdir scratch";

  compressionLevel = 1;
}
