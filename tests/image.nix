# nix build .#checks.x86_64-linux.image -o hello
# cd hello
# apptainer run hello.sif                             # Hello, world!
# apptainer run hello.sif -g Bonjour                  # Bonjour
# apptainer exec hello.sif sh -c 'echo "$QUOTED"'     # it's "quoted": $HOME `date` \
# apptainer exec --nv hello.sif nvidia-smi -L         # GPU 0: ... (with an NVIDIA GPU)
{ nix2apptainer, hello }:

nix2apptainer.buildImage {
  name = "hello";
  contents = [ hello ];
  runScript = ''exec hello "$@"'';
  environment.QUOTED = "it's \"quoted\": \$HOME `date` \\";

  compressionLevel = 1;
}
