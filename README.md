# nix2apptainer

Export Nix packages as Apptainer (SIF) images.

`buildImage` packs Nix packages and their closure into one `.sif` file, which
runs with `apptainer run` on a machine that has Apptainer but no Nix, such as
an HPC cluster. The image is an ordinary derivation: an unprivileged
`apptainer build` packs it in the Nix sandbox, without a VM, so the builder
needs neither KVM nor root.

`buildLayer` puts the heavy dependencies that rarely change (a toolchain, MPI,
CUDA) into a separate layer file. You build it and copy it to the cluster
once, and again only when something in its closure changes. An image built on
the layer leaves those dependencies out, so a change to your own code means
rebuilding and copying only that smaller image.

## Quick start

```nix
nix2apptainer.buildImage {
  name = "hello";
  contents = [ hello ];
  runScript = ''exec hello "$@"'';
}
```

`nix2apptainer` stands for the library: `tools` in the flake under
[Adding it to your project](#adding-it-to-your-project), or
`pkgs.nix2apptainer` with the overlay. The output of the derivation is the
`.sif` file itself. [tests/image.nix](tests/image.nix) is this example with a
few more options set. To build and run it from a clone of this repository:

```bash
nix build .#checks.x86_64-linux.image -o hello.sif   # aarch64-linux on ARM
apptainer run hello.sif -g Bonjour                   # Bonjour
```

To run an image, a machine needs only Apptainer, plus the image's layers if
it has any. With zstd compression it needs Apptainer 1.4 or later (see
[`buildImage`](#buildimage)).

## Adding it to your project

From a flake:

```nix
{
  inputs.nix2apptainer.url = "github:Wenke-D/nix2apptainer";
  inputs.nix2apptainer.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, nix2apptainer, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      tools = pkgs.callPackage nix2apptainer { };
    in
    {
      packages.x86_64-linux.image = tools.buildImage { /* ... */ };
    };
}
```

The flake also has `overlays.default`, which adds `pkgs.nix2apptainer`.
Without flakes, pass a checkout of this repository to `callPackage`:
`pkgs.callPackage ./nix2apptainer { }`. Either way the images are built from
the caller's packages; the flake's own `nixpkgs` input is used only for the
checks.

Images build only on Linux, and the checks are defined for x86_64-linux and
aarch64-linux. From macOS, use a Linux remote builder, or Nix in a Linux
container such as the `nixos/nix` Docker image. To build in the Nix sandbox
there, as on a regular builder, set `sandbox = true` (the image turns it off)
and run the container with `--privileged`, without which Nix cannot set the
sandbox up. The builds still run as Nix's unprivileged build users.

## Layers

A layer is a squashfs file that holds the closure of some packages under
`/nix/store`. An image built with `layers = [ layer ]` leaves out every store
path that the layer holds, and at run time Apptainer mounts the layer over the
image with `--overlay <layer>:ro`. The cluster needs nothing for this beyond
an Apptainer version that supports `--overlay`. Here the layer holds MPI:

```nix
let
  mpi = nix2apptainer.buildLayer {
    name = "mpi";
    contents = [ openmpi ];
  };
in
nix2apptainer.buildImage {
  name = "solver";
  contents = [ my-solver ];
  layers = [ mpi ];
  runScript = ''exec my-solver "$@"'';
}
```

```bash
apptainer run --overlay mpi.sqfs:ro solver.sif
```

This example is an illustration and has not been built; `my-solver` stands
for your own package. `mpi.sqfs` and `solver.sif` are the outputs of `mpi` and
of the image. The layer is a derivation of its own, so expose it as a package
next to the image to build it (an image also lists its layers in
`image.layers`).

When only `my-solver` changes, only the image is rebuilt and copied to the
cluster. The layer changes when anything in its closure does, for example
after a nixpkgs update. Its store path then changes too, and images already on
the cluster keep needing the layer they were built on, so keep the old layer
file until those images are replaced.

An image leaves out only the store paths that match the layer's exactly; any
others are copied into the image as usual. Build the layer and the images from
the same package set, and several images can share one layer.

Before anything else runs in the container (for `run`, `exec` and `shell`
alike), an image checks for each of its layers. Run without one, it stops with
an error that names the missing layer, instead of failing later on a missing
library. The check looks for a marker that the layer derives from the store
paths it holds, not for its file name. The error names the layer by the base
name of its store path (`<hash>-<name>.sqfs`). A layer built from other
packages, such as an outdated copy, fails with the same error, and the file
can have any name on the cluster.

`layers` is a list; pass one `--overlay` per layer. Each layer holds the full
closure of its own `contents`, so two layers can both contain glibc. The
`contents` of each layer are linked into the image root (`/bin`, `/lib` and so
on) like the image's own, so `mpirun` from the layer is on the `PATH`.

[tests/layer.nix](tests/layer.nix) and
[tests/layered-image.nix](tests/layered-image.nix) are an image of `hello` on
a layer that holds coreutils and its closure, glibc included:

```bash
nix build .#checks.x86_64-linux.layer -o coreutils.sqfs
nix build .#checks.x86_64-linux.layered-image -o hello-layered.sif
apptainer run --overlay coreutils.sqfs:ro hello-layered.sif   # Hello, world!
apptainer run hello-layered.sif   # error: this image needs the layer ...-coreutils.sqfs
```

## NVIDIA GPUs

With `--nv`, Apptainer makes the NVIDIA driver of the host available in the
container:

- It binds the driver libraries into `/.singularity.d/libs` and adds that
  directory to `LD_LIBRARY_PATH`. A program from Nix finds `libcuda` there.
- It binds host tools such as `nvidia-smi` into `/usr/bin`. A conventional
  distribution built these tools, so they look for the dynamic loader at
  `/lib64/ld-linux-x86-64.so.2`. Programs from Nix name a loader in the store
  instead.

So that the host tools run, every image has a link at that path to the glibc
loader in the image. On aarch64-linux the link is
`/lib/ld-linux-aarch64.so.1`. The image of [tests/image.nix](tests/image.nix)
shows it:

```bash
nix build .#checks.x86_64-linux.image -o hello.sif
apptainer exec --nv hello.sif nvidia-smi -L   # GPU 0: <model> (UUID: ...)
```

The host tools then run on the glibc of the image, which must be at least as
new as the glibc they were built for. Other programs built for a
conventional distribution also start with the loader, such as tools
installed under `$HOME`, which Apptainer mounts by default. They can still
fail on other libraries that they expect from the distribution, such as
`libstdc++`.

`fhsCompat = false` leaves the link out. The host tools then fail:

```
FATAL:   exec /usr/bin/nvidia-smi failed: a shared library is likely missing in the image
```

## Compared with nixpkgs' `singularity-tools`

nixpkgs' `singularity-tools.buildImage` boots a Linux VM
(`vmTools.runInLinuxVM`), formats a scratch ext3 disk in it, and runs
`singularity build` there as root. Apptainer can pack a plain directory into a
SIF without privileges, and `nix2apptainer` relies on that: it copies the
closure into a directory and runs `apptainer build` as the build user, in the
ordinary Nix sandbox.

| | `singularity-tools` | `nix2apptainer` |
| --- | --- | --- |
| How the image is made | `singularity build` as root in a VM | `apptainer build` as the build user, in the Nix sandbox |
| Builder | needs the `kvm` system feature | any Linux builder: remote, CI, a container |
| Sizes to set in advance | `diskSize` (the scratch disk) and `memSize` of the VM, 1024 MiB each by default | none |
| Program that builds the image | `singularity` argument, default `pkgs.singularity` (SingularityCE) | `apptainer` argument, default `pkgs.apptainer` |
| Links in the image root | `bin/*` of each package, in `/bin` | `bin`, `lib`, `share`, `etc`, ... of each package, merged as in `dockerTools` |
| Environment variables | no argument | `environment` |
| Compression | gzip | `compression`, `compressionLevel` (gzip, zstd, xz, lz4, lzo) |
| Layers | none | `buildLayer`, `layers` |
| Setup script | `runAsRoot`, as root | `extraCommands`, as the build user |

The cost of building without root is that `extraCommands` runs as the build
user: `mkdir` and writing files work, `useradd` and `chown` do not. Apptainer
runs the container as the calling user and adds that user to `/etc/passwd` at
run time, so images rarely need either.

## Reference

### `buildImage`

| Argument | Default | Meaning |
| --- | --- | --- |
| `name` | required | The output is the file `<name>.sif` |
| `contents` | `[ ]` | Packages whose closure is copied in and whose top-level directories are merged into the image root, as links into the store |
| `layers` | `[ ]` | Layers from `buildLayer`. Their store paths are left out of the image, which then runs only with them as overlays |
| `runScript` | `exec /bin/sh "$@"` | Shell code that `apptainer run` executes with `/bin/sh` |
| `environment` | `{ }` | Variables set in every `apptainer run`, `exec` and `shell`, read back exactly as written (quotes, `$`, `` ` `` and `\` included) |
| `extraCommands` | `""` | Shell code run in the image root before it is packed, as the build user |
| `compression` | `"gzip"` | mksquashfs compressor: `gzip`, `zstd`, `xz`, `lz4` or `lzo` |
| `compressionLevel` | `null` | 1-9 for gzip and lzo, 1-22 for zstd, none for xz and lz4; `null` keeps the mksquashfs default (9 for gzip, 15 for zstd) |
| `fhsCompat` | `true` | Adds the conventional paths that programs not built by Nix look for. For now this is only the dynamic loader, which the host tools of `--nv` need (see [NVIDIA GPUs](#nvidia-gpus)). `false` leaves them out |
| `apptainer` | `pkgs.apptainer` | The Apptainer that builds the image |

Every Apptainer version reads gzip. zstd at a low level packs many times
faster, but the image then needs Apptainer 1.4 or later to run (1.3 rejects
zstd).

Besides `contents`, every image has bash as `/bin/sh` (unless `contents` or a
layer brings its own) and an `/etc/passwd` and `/etc/group` that hold only
root. Unless `fhsCompat = false`, it also has the glibc loader at
`/lib64/ld-linux-x86-64.so.2` (`/lib/ld-linux-aarch64.so.1` on
aarch64-linux). `image.layers` lists the layers an image needs.

### `buildLayer`

| Argument | Default | Meaning |
| --- | --- | --- |
| `name` | required | The output is the file `<name>.sqfs` |
| `contents` | required | Packages whose closure the layer holds |
| `compression` | `"gzip"` | As for `buildImage` |
| `compressionLevel` | `null` | As for `buildImage` |

`buildLayer` runs mksquashfs with the options that `apptainer build` gives it,
so an Apptainer that reads an image also reads a layer with the same
compression.

[default.nix](default.nix) documents the same arguments next to the code.

## Tests

`nix flake check` builds the examples in [tests/](tests/) for the system it
runs on; `nix flake check --all-systems` builds them for x86_64-linux and
aarch64-linux, which needs a builder for each. The checks build the images but
do not run them. The comment at the top of each file shows how to run its
image, and the commands under Quick start, at the end of Layers and under
NVIDIA GPUs come from there. On 2026-11-04 they all gave the output shown on
x86_64-linux, with Apptainer 1.5.3 and an NVIDIA GPU. On 2026-10-19 all
except the `--nv` command gave the output shown on aarch64-linux (with
`aarch64-linux` in place of `x86_64-linux`) and Apptainer 1.5.1. The `--nv`
command has not been run on aarch64-linux.

## Acknowledgement

The development of this tool was assisted by LLMs and AI agents.
