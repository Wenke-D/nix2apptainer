# apptainer-tools

Apptainer (SIF) images from Nix store paths, built in the ordinary Nix
sandbox: no VM, no root, no fakeroot.

```nix
apptainer-tools.buildImage {
  name = "hello";
  contents = [ hello ];
  runScript = ''exec hello "$@"'';
}
```

The derivation is the `.sif` file itself. Run it with the host's Apptainer.
`tests/image.nix` is this example with a few more options set:

```bash
nix build .#checks.x86_64-linux.image -o hello.sif
apptainer run hello.sif -g Bonjour
```

## Compared with nixpkgs' `singularity-tools`

`singularity-tools.buildImage` builds the image inside a Linux VM
(`vmTools.runInLinuxVM`). The builder needs KVM, and the image is put
together on a scratch ext3 disk whose size (`diskSize`) and memory
(`memSize`) are fixed in advance.

`apptainer-tools` copies the closure into a directory and lets
`apptainer build` pack that directory into a SIF, which needs no privileges.
This runs as the build user in the ordinary sandbox, so any Linux builder
works: remote, CI, with or without KVM. The cost is that `extraCommands`
runs as the build user too (`mkdir` works, `useradd` does not).

On top of that it has:

- **Layers.** `buildLayer` packs the heavy part that rarely changes (a
  toolchain, MPI, CUDA) into a squashfs, used with
  `apptainer run --overlay <layer>:ro`. An image built with
  `layers = [ layer ]` leaves out the layer's store paths. A rebuild then
  packs, and a cluster receives, only what changed. Run without its layer,
  the image stops with an error that names the layer.
- **`environment`.** Variables set in every `run`, `exec` and `shell`.
  They are quoted so that Apptainer's env-file reader reads them back as
  written.
- **`contents` merged into the image root.** Their `bin`, `lib`, `share`,
  `etc` and so on become links into the store, as in `dockerTools`.
- **`compression`, `compressionLevel`.** The mksquashfs compressor. zstd at
  a low level packs many times faster than gzip, but the image then needs
  Apptainer 1.4 or later to run (1.3 rejects zstd).

## Use

From a flake:

```nix
{
  inputs.apptainer-tools.url = "<this repository>";
  inputs.apptainer-tools.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, apptainer-tools, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      tools = pkgs.callPackage apptainer-tools { };
    in
    {
      packages.x86_64-linux.image = tools.buildImage { /* ... */ };
    };
}
```

You can also use `overlays.default`, which adds `pkgs.apptainer-tools`.
Without flakes, call `default.nix` the same way:
`pkgs.callPackage ./apptainer-tools { }`. The images are built from the
caller's packages either way. This flake's own `nixpkgs` is only used for
the checks.

`default.nix` documents every argument of `buildImage` and `buildLayer`.

## Tests

`nix flake check` builds the examples in `tests/` for x86_64-linux and
aarch64-linux, which needs a builder for each. To build one:
`nix build .#checks.x86_64-linux.image`. Each file shows how to run its
image.
