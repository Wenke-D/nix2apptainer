{
  lib,
  runCommand,
  closureInfo,
  symlinkJoin,
  writeText,
  bashInteractive,
  squashfsTools,
  apptainer,
}:

let
  defaultApptainer = apptainer;

  compressionArgs =
    compression: level:
    [
      "-comp"
      compression
    ]
    ++ lib.optionals (level != null) [
      "-Xcompression-level"
      (toString level)
    ];
in
{
  # A read-only layer for `apptainer run --overlay <layer>:ro <image>`: a
  # squashfs holding the closure of `contents` under /nix/store.
  #
  # name, compression, compressionLevel: as for buildImage
  buildLayer =
    {
      name,
      contents,
      compression ? "gzip",
      compressionLevel ? null,
    }:
    let
      closure = closureInfo { rootPaths = contents; };

      # Named after the closure rather than $out: when Nix builds under a
      # scratch path (--check without the sandbox, content-addressed
      # derivations), it cannot rewrite that path inside the compressed
      # squashfs.
      marker = "${lib.substring 0 32 (baseNameOf "${closure}")}-${name}";
    in
    runCommand "${name}.sqfs"
      {
        nativeBuildInputs = [ squashfsTools ];
        passthru = { inherit contents closure marker; };
      }
      ''
        mkdir -p root/.layers
        xargs -a ${closure}/store-paths cp -a --parents -t root
        touch root/.layers/${marker}

        # The options `apptainer build` gives mksquashfs, so the layer reads
        # wherever the image does.
        mksquashfs root $out -noappend -all-root -quiet \
          ${lib.escapeShellArgs (compressionArgs compression compressionLevel)}
      '';

  # name:          of the derivation, which is the .sif file itself
  # contents:      packages whose top-level directories (bin, lib, share, etc,
  #                ...) are merged into the image root, as symlinks into the
  #                store, like dockerTools does
  # layers:        from buildLayer; their store paths are left out of the
  #                image, which then runs only with them as overlays (and
  #                says so otherwise).  Their contents are linked in too.
  # runScript:     shell code that `apptainer run` executes, as /bin/sh
  # environment:   variables set in every `apptainer run/exec/shell`
  # extraCommands: shell code run in the image root before it is packed, as
  #                the build user (`mkdir`, not `useradd`)
  # compression:   squashfs compressor: gzip, zstd, xz, lz4 or lzo.  Images
  #                packed with zstd need Apptainer 1.4 or later to run.
  # compressionLevel: for gzip (1-9), zstd (1-22) or lzo (1-9); null keeps
  #                mksquashfs's default (9 for gzip, 15 for zstd)
  buildImage =
    {
      name,
      contents ? [ ],
      layers ? [ ],
      runScript ? ''exec /bin/sh "$@"'',
      environment ? { },
      extraCommands ? "",
      compression ? "gzip",
      compressionLevel ? null,
      apptainer ? defaultApptainer,
    }:
    let
      rootLinks = symlinkJoin {
        name = "${name}-root";
        paths = contents ++ lib.concatMap (layer: layer.contents) layers;
      };

      runScriptFile = writeText "runscript" ''
        #!/bin/sh
        ${runScript}
      '';

      # Apptainer reads env files with its own shell interpreter, which keeps
      # the backslash of an unquoted \' (lib.escapeShellArg's 'it'\''s comes
      # out as it\'s).  Double quotes with \ " $ ` escaped read as in sh.
      quote = v: ''"${lib.escape [ "\\" "\"" "$" "`" ] (toString v)}"'';

      hasEnvironment = environment != { };
      environmentFile = writeText "90-environment.sh" (
        lib.concatStrings (lib.mapAttrsToList (n: v: "export ${n}=${quote v}\n") environment)
      );

      # Env files run before anything else in the container, even before
      # Apptainer looks at /bin/sh, which may itself be in a layer.
      layersCheckFile = writeText "00-layers.sh" (
        lib.concatMapStrings (
          layer:
          let
            file = baseNameOf (toString layer);
          in
          ''
            if [ ! -e /.layers/${layer.marker} ]; then
              echo "error: this image needs the layer ${file}: run it with --overlay ${file}:ro" >&2
              exit 1
            fi
          ''
        ) layers
      );

      # The scripts are in it for the store paths their text refers to.
      closure = closureInfo {
        rootPaths =
          contents
          ++ [
            bashInteractive
            runScriptFile
          ]
          ++ lib.optional hasEnvironment environmentFile;
      };
    in
    runCommand "${name}.sif"
      {
        nativeBuildInputs = [ apptainer ];
        passthru = { inherit layers; };
      }
      ''
        mkdir root
        pushd root >/dev/null

        comm -23 <(sort ${closure}/store-paths) \
          <(sort -u /dev/null ${lib.concatMapStringsSep " " (layer: "${layer.closure}/store-paths") layers}) \
          | xargs -r cp -a --parents -t .
        cp -a ${rootLinks}/. .

        # Copies of the store are read-only; the steps below write into them,
        # and so does `apptainer build`, which copies the tree once more.
        chmod -R u+w .

        rm -rf nix-support
        mkdir -p bin etc .singularity.d/env
        [ -e bin/sh ] || ln -s ${lib.getExe bashInteractive} bin/sh

        # Real files, not links into the store: at run time Apptainer adds the
        # calling user to them, and it skips links.
        rm -f etc/passwd etc/group
        echo "root:x:0:0:root:/root:/bin/sh" > etc/passwd
        echo "root:x:0:" > etc/group

        install -m 755 ${runScriptFile} .singularity.d/runscript
        ${lib.optionalString hasEnvironment ''
          install -m 644 ${environmentFile} .singularity.d/env/90-environment.sh
        ''}
        ${lib.optionalString (layers != [ ]) ''
          install -m 644 ${layersCheckFile} .singularity.d/env/00-layers.sh
        ''}

        ${extraCommands}

        popd >/dev/null

        # Apptainer keeps a cache under $HOME, which the sandbox does not have.
        export HOME=$TMPDIR/home
        mkdir -p $HOME

        # The build reads /etc/resolv.conf and /etc/hosts, which the sandbox
        # lacks; -B points it at stand-ins instead.
        touch resolv.conf
        echo "127.0.0.1 localhost" > hosts
        apptainer build \
          -B $PWD/resolv.conf:/etc/resolv.conf -B $PWD/hosts:/etc/hosts \
          --mksquashfs-args ${lib.escapeShellArg (lib.concatStringsSep " " (compressionArgs compression compressionLevel))} \
          $out root
      '';
}
