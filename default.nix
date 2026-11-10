{
  lib,
  stdenv,
  runCommand,
  closureInfo,
  buildEnv,
  linkFarmFromDrvs,
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
  # A read-only overlay for `apptainer run --overlay <overlay>:ro <image>`: a
  # squashfs holding the closure of `contents` under /nix/store.
  #
  # name:          the overlay file is <name>.sqfs
  # compressionType, compressionLevel: as for buildImage
  buildOverlay =
    {
      name,
      contents,
      compressionType ? "gzip",
      compressionLevel ? null,
    }:
    let
      closure = closureInfo { rootPaths = contents; };

      # Named after the closure rather than $out: when Nix builds under a
      # scratch path (--check without the sandbox, content-addressed
      # derivations), it cannot rewrite that path inside the compressed
      # squashfs.
      marker = "${name}/${lib.substring 0 32 (baseNameOf "${closure}")}";
    in
    runCommand "${name}.sqfs"
      {
        nativeBuildInputs = [ squashfsTools ];
        passthru = { inherit contents closure marker; };
      }
      ''
        mkdir -p root/.overlays/${name}
        xargs -a ${closure}/store-paths cp -a --parents -t root
        touch root/.overlays/${marker}

        # The same flags that `apptainer build` uses to pack an image, so the
        # overlay reads wherever the image does.
        mksquashfs root $out -noappend -all-root -quiet \
          ${lib.escapeShellArgs (compressionArgs compressionType compressionLevel)}
      '';

  # Returns a directory that holds <name>.sif and a link to each overlay.
  #
  # name:          the image file is <name>.sif
  # contents:      packages to put in the image, with their closure.  Their
  #                top-level directories (bin, lib, share, etc, ...) are merged
  #                into the image root, as symlinks into the store, like
  #                dockerTools does
  # overlays:      from buildOverlay; their store paths are left out of the
  #                image, which then runs only with them (and says so
  #                otherwise).  Their contents are linked in too.
  # ignoreCollisions: when two of these packages have the same file, the image
  #                gets the file of the first one and the build log shows a
  #                warning.  Set to false to stop the build instead, unless
  #                the two files are identical.
  # runScript:     shell code that `apptainer run` executes, as /bin/sh
  # environment:   variables set in every `apptainer run/exec/shell`.  Each
  #                value stays literal: quotes, $, ` and \ are not special.
  # compressionType: squashfs compressor: gzip, zstd, xz, lz4 or lzo.  Images
  #                packed with zstd need Apptainer 1.4 or later to run.
  # compressionLevel: for gzip (1-9), zstd (1-22) or lzo (1-9), not for xz or
  #                lz4; null keeps mksquashfs's default (9 for gzip, 15 for
  #                zstd)
  # fhsCompat:     add the conventional paths that programs not built by Nix
  #                look for.  For now only the dynamic loader
  #                (/lib64/ld-linux-x86-64.so.2 on x86_64), linked to the
  #                image's glibc: the host tools that `apptainer --nv` binds
  #                in, such as nvidia-smi, need it.
  # apptainer:     the Apptainer that builds the image
  buildImage =
    {
      name,
      contents ? [ ],
      overlays ? [ ],
      ignoreCollisions ? true,
      runScript ? ''exec /bin/sh "$@"'',
      environment ? { },
      compressionType ? "gzip",
      compressionLevel ? null,
      fhsCompat ? true,
      apptainer ? defaultApptainer,
    }:
    let
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
      # Apptainer looks at /bin/sh, which may itself be in an overlay.
      overlaysCheckFile = writeText "00-overlays.sh" (
        lib.concatMapStrings (overlay: ''
          if [ ! -e /.overlays/${overlay.marker} ]; then
            if [ -d /.overlays/${dirOf overlay.marker} ]; then
              echo "error: overlay ${overlay.name} is outdated: use the copy built with this image" >&2
            else
              echo "error: overlay ${overlay.name} is missing: run this image with --overlay ${overlay.name}:ro" >&2
            fi
            exit 1
          fi
        '') overlays
      );

      loader = stdenv.cc.bintools.dynamicLinker;
      fhsLoader = "${stdenv.hostPlatform.libDir}/${baseNameOf loader}";

      rootLinks = buildEnv {
        name = "${name}-root";
        # As strings: from a derivation buildEnv takes meta.outputsToInstall,
        # which can name outputs that are not in the closure.
        paths = map (path: "${path}") (contents ++ lib.concatMap (overlay: overlay.contents) overlays);
        inherit ignoreCollisions;

        # buildEnv links a directory that only one package has to that package
        # as a whole, but it makes a directory of links for each path that is
        # named here.  postBuild adds files to these, so they must be
        # directories.
        pathsToLink = [
          "/"
          "/bin"
          "/etc"
        ]
        ++ lib.optional fhsCompat "/${dirOf fhsLoader}";

        postBuild = ''
          # Add a shell if no package provides one.
          [ -e $out/bin/sh ] || ln -s ${lib.getExe bashInteractive} $out/bin/sh

          # Add the loader at its conventional path if no package provides it:
          # programs not built by Nix look for it there when they run in the
          # container.
          ${lib.optionalString fhsCompat ''
            [ -e $out/${fhsLoader} ] || ln -s ${loader} $out/${fhsLoader}
          ''}

          # Replace any passwd and group that a package provides with real
          # files: at run time Apptainer adds the calling user to them, and it
          # skips links.
          rm -f $out/etc/passwd $out/etc/group
          echo "root:x:0:0:root:/root:/bin/sh" > $out/etc/passwd
          echo "root:x:0:" > $out/etc/group
        '';
      };

      # The scripts are in it for the store paths their text refers to.
      closure = closureInfo {
        rootPaths =
          contents
          ++ [
            bashInteractive
            runScriptFile
          ]
          ++ lib.optional hasEnvironment environmentFile
          ++ lib.optional fhsCompat (lib.getLib stdenv.cc.libc);
      };

      sif = runCommand "${name}.sif" { nativeBuildInputs = [ apptainer ]; } ''
        mkdir root
        pushd root >/dev/null

        comm -23 <(sort ${closure}/store-paths) \
          <(sort -u /dev/null ${
            lib.concatMapStringsSep " " (overlay: "${overlay.closure}/store-paths") overlays
          }) \
          | xargs -r cp -a --parents -t .
        cp -a ${rootLinks}/. .

        # Copies of the store are read-only; the steps below write into the
        # root, and `apptainer build` copies the tree once more.
        chmod -R u+w .

        mkdir -p .singularity.d/env
        install -m 755 ${runScriptFile} .singularity.d/runscript
        ${lib.optionalString hasEnvironment ''
          install -m 644 ${environmentFile} .singularity.d/env/90-environment.sh
        ''}
        ${lib.optionalString (overlays != [ ]) ''
          install -m 644 ${overlaysCheckFile} .singularity.d/env/00-overlays.sh
        ''}

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
          --mksquashfs-args ${lib.escapeShellArg (lib.concatStringsSep " " (compressionArgs compressionType compressionLevel))} \
          $out root
      '';
    in
    linkFarmFromDrvs name ([ sif ] ++ overlays);
}
