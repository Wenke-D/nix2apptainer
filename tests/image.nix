# nix build .#checks.x86_64-linux.image -o hello.sif
# apptainer run hello.sif                             # Hello, world!
# apptainer run hello.sif -g Bonjour                  # Bonjour
# apptainer exec hello.sif sh -c 'echo "$QUOTED"'     # it's "quoted": $HOME `date` \
# apptainer exec --nv hello.sif nvidia-smi -L         # GPU 0: ... (with an NVIDIA GPU)
{ apptainer-tools, hello }:

apptainer-tools.buildImage {
  name = "hello";
  contents = [ hello ];
  runScript = ''exec hello "$@"'';
  environment.QUOTED = "it's \"quoted\": \$HOME `date` \\";
  extraCommands = "mkdir scratch";

  compressionLevel = 1;
}
