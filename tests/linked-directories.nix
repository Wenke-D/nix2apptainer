# Packages whose top-level directories are links to other store paths, as in
# the output of buildEnv.  Only one package has /bin; /etc is in three, one of
# them with a real directory.  The build checks the root of the image; the
# output is the image:
#
#   nix build .#checks.x86_64-linux.linked-directories -o linked-directories
#   cd linked-directories
#   apptainer exec linked-directories.sif ls /etc
#       # first.conf  group  last.conf  passwd  real.conf  (and what Apptainer binds)
{
  nix2apptainer,
  runCommand,
  apptainer,
  squashfsTools,
}:

let
  directory =
    name: file:
    runCommand name { } ''
      mkdir $out
      touch $out/${file}
    '';

  linkedEtc =
    name:
    runCommand name { } ''
      mkdir $out
      ln -s ${directory "${name}-etc" "${name}.conf"} $out/etc
    '';

  linkedBin = runCommand "linked-bin" { } ''
    mkdir $out
    ln -s ${directory "tool-bin" "tool"} $out/bin
  '';

  real = runCommand "real" { } ''
    mkdir -p $out/etc
    touch $out/etc/real.conf
  '';

  image = nix2apptainer.buildImage {
    name = "linked-directories";
    contents = [
      linkedBin
      (linkedEtc "first")
      real
      (linkedEtc "last")
    ];
  };
in
runCommand "linked-directories"
  {
    nativeBuildInputs = [
      apptainer
      squashfsTools
    ];
  }
  ''
    export HOME=$TMPDIR/home
    mkdir -p $HOME

    sif=${image}/linked-directories.sif
    id=$(apptainer sif list $sif | awk -F'|' '/Squashfs/ { print $1 + 0 }')
    apptainer sif dump $id $sif > root.sqfs
    unsquashfs -quiet -no-xattrs -d root root.sqfs bin etc

    set -x
    test -d root/bin -a ! -L root/bin
    test -d root/etc -a ! -L root/etc
    test -L root/bin/tool
    test -L root/bin/sh
    test -L root/etc/first.conf
    test -L root/etc/real.conf
    test -L root/etc/last.conf
    test -f root/etc/passwd -a ! -L root/etc/passwd
    test -f root/etc/group -a ! -L root/etc/group
    set +x

    ln -s ${image} $out
  ''
