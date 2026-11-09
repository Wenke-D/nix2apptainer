# nix2apptainer: Pack Nix packages into Apptainer images

The library provides two features:

1. Pack a Nix package and its full closure into a `.sif` file, and run the file
   with Apptainer (`buildImage`).
2. Split the heavy dependencies that rarely change into an overlay
   (`buildOverlay`). A change in the other dependencies of the image then does
   not need a full rebuild of the `.sif` file.

This library uses the Nix flakes feature.

## Quick start

1. Add nix2apptainer as an input of your flake.
2. Call `nix2apptainer.lib.setup pkgs` to use the same packages as your flake.
3. Call `buildImage` on the packages to pack.

Example:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nix2apptainer = {
    url = "github:Wenke-D/nix2apptainer";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nix2apptainer, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      n2apt = nix2apptainer.lib.setup pkgs;
    in
    {
      packages.x86_64-linux.default = n2apt.buildImage {
        name = "hello";
        contents = [ pkgs.hello ];
        runScript = ''exec hello "$@"'';
      };
    };
}
```

Build the image into the directory `hello`, which then holds `hello.sif`:

```bash
nix build -o hello
```

## Features

### `buildImage`

To generate a SIF image from a Nix derivation, use `buildImage`. It takes the
full closure of that derivation and packs it into a `.sif` file. The output is a
directory that holds this file and the overlays (see below) of the image. Check
[default.nix](default.nix) for the parameters.

To follow Linux and Apptainer conventions, the image also holds:

- Bash as `/bin/sh`, if no user package provides it.
- An `/etc/passwd` and an `/etc/group` that hold only root. Apptainer needs
  these files to add the calling user at runtime.
- With `fhsCompat` set to `true` (the default), a link to the glibc loader at
  `/lib64/ld-linux-x86-64.so.2`, or at `/lib/ld-linux-aarch64.so.1` on
  aarch64-linux.

### `buildOverlay`

Some dependencies in the closure of your package rarely change, but others
change often. Each change still causes a full rebuild of the image.

To avoid these unnecessary rebuilds, put the stable part of the closure into an
Apptainer overlay, and put only the part that changes into the `.sif` file. The
`.sif` file then builds fast. Run it with the overlay, so that the whole closure
exists at runtime.

`buildOverlay` takes the same `compressionType` and `compressionLevel` arguments
as `buildImage`. Each call sets its own.

This example puts MPI, HDF5 and the CUDA toolkit into one overlay and builds the
application image without them. `my-solver` stands for your application that
uses MPI, HDF5 and CUDA.

```nix
let
  heavy_deps = n2apt.buildOverlay {
    name = "heavy_deps";
    contents = [
      pkgs.openmpi
      pkgs.hdf5
      pkgs.cudaPackages.cudatoolkit
    ];
  };
in
{
  packages.x86_64-linux.solver_images = n2apt.buildImage {
    name = "solver";
    contents = [ my-solver ];
    overlays = [ heavy_deps ];
    runScript = ''exec my-solver "$@"'';
  };
}
```

---

Build the image directory with the following command:

```bash
nix build .#solver_images -o solver_images
```

The directory `solver_images` holds `solver.sif` and `heavy_deps.sqfs`. As long
as MPI, HDF5 and CUDA do not change, an update to the solver code makes this
command rebuild only the `.sif` file.

---

At runtime, use the image together with the overlay:

```sh
apptainer run --overlay solver_images/heavy_deps.sqfs:ro solver_images/solver.sif
```

Check [default.nix](default.nix) for the parameters of `buildOverlay`.

Use the same `pkgs` for the overlay and the image. Otherwise, the image won't
find its dependencies in the overlay.

The generated image stops with an error when it runs without its paired
overlay, or with an outdated copy of it:

```
error: overlay heavy_deps.sqfs is missing: run this image with --overlay heavy_deps.sqfs:ro

error: overlay heavy_deps.sqfs is outdated: use the copy built with this image
```

## How it works

### Building an image

`buildImage` runs these steps:

1. It computes the closure of `contents`, Bash, the scripts that it adds and,
   with `fhsCompat`, glibc.
2. It copies that closure into a directory.
3. It merges the top-level directories of `contents` into the root of the
   directory as links into the store.
4. It adds `/bin/sh`, `/etc/passwd`, `/etc/group`, and the run script and
   environment files in `.singularity.d`.
5. It runs `apptainer build`, which packs the directory into the `<name>.sif`
   file.
6. It puts the `<name>.sif` file in the output directory.

### Building an image with overlays

With `overlays`, `buildImage` changes these steps:

- **Step 2** skips the store paths that the overlays hold.
- **Step 3** also merges the top-level directories of the `contents` of each
  overlay. These links resolve only when the overlays are mounted.
- **Step 4** also adds an environment file, `00-overlays.sh`, that checks for
  each overlay (missing or outdated) at runtime.
- **Step 6** also puts each overlay into the output directory.

### Building an overlay

1. `buildOverlay` copies the closure of `contents` into a directory.
2. It adds a marker file at `/.overlays/<name>/<hash>`. The hash is derived from
   the overlay's store paths.
3. `mksquashfs` packs the directory into the overlay file.

### Checking overlays at runtime

1. Apptainer mounts the overlay over the image.
2. Apptainer runs `00-overlays.sh` with its own shell interpreter, so the check
   also works when `/bin/sh` is in the missing overlay.
3. The script looks for the marker of each overlay.
4. If the `/.overlays/<name>` directory does not exist, the overlay is missing,
   and the image stops with the matching error above.
5. If the directory exists but holds a different hash, the overlay is outdated,
   and the image stops with the matching error above.
6. If every marker matches, the container runs the requested program.

## Why this tool

nixpkgs' `singularity-tools.buildImage` has been out of date for a long time
(last updated in November 2024). It still boots a Linux VM
(`vmTools.runInLinuxVM`), formats a scratch ext3 disk in it, and runs
`singularity build` there as root. This is no longer necessary, as Apptainer can
pack a plain directory into a SIF file without privileges. nix2apptainer takes
advantage of this, so it also builds under a Nix that runs in a user namespace.

nix2apptainer provides more options for building the image. The `environment`,
`compressionType` and `compressionLevel` arguments expose what Apptainer already
supports.

The overlay feature saves unnecessary rebuilds of applications.

## Development

- `nix flake check` builds the examples in [tests/](tests/) for the current
  system.
- `nix flake check --all-systems` builds them for x86_64-linux and
  aarch64-linux, and needs a builder for each.

## License

[MIT](LICENSE)

## Acknowledgements

LLMs and AI agents helped contribute to this project.
