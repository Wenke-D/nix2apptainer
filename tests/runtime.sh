#!/usr/bin/env bash
set -euo pipefail

system=$(nix eval --impure --raw --expr builtins.currentSystem)
tmp=$(mktemp -d)
cleanup() {
  rm -f "$tmp/image" "$tmp/linked" "$tmp/overlaid" "$tmp/outdated" "$tmp/error"
  rmdir "$tmp"
}
trap cleanup EXIT

nix build --no-write-lock-file ".#checks.$system.image" -o "$tmp/image"
nix build --no-write-lock-file ".#checks.$system.linked-directories" -o "$tmp/linked"
nix build --no-write-lock-file ".#checks.$system.overlaid-image" -o "$tmp/overlaid"
nix build --no-write-lock-file ".#checks.$system.outdated-overlay" -o "$tmp/outdated"

image="$tmp/image/hello.sif"
overlaid="$tmp/overlaid/hello-overlaid.sif"
overlay="$tmp/overlaid/coreutils.sqfs"

test "$(apptainer run --cleanenv "$image")" = "Hello, world!"
test "$(apptainer run --cleanenv "$image" -g Bonjour)" = "Bonjour"
test "$(apptainer exec --cleanenv "$image" sh -c 'printf %s "$QUOTED"')" = \
  'it'\''s "quoted": $HOME `date` \'
apptainer exec --cleanenv "$tmp/linked/linked-directories.sif" sh -c \
  'test -e /bin/tool && test -e /etc/first.conf && test -e /etc/real.conf && test -e /etc/last.conf'

test "$(apptainer run --cleanenv --overlay "$overlay:ro" "$overlaid")" = "Hello, world!"
apptainer exec --cleanenv --overlay "$overlay:ro" "$overlaid" ls / >/dev/null

if apptainer run --cleanenv "$overlaid" >"$tmp/error" 2>&1; then
  echo "Image unexpectedly ran without its overlay" >&2
  exit 1
fi
grep -F 'error: overlay coreutils.sqfs is missing' "$tmp/error"

if apptainer run --cleanenv --overlay "$tmp/outdated:ro" "$overlaid" >"$tmp/error" 2>&1; then
  echo "Image unexpectedly ran with an outdated overlay" >&2
  exit 1
fi
grep -F 'error: overlay coreutils.sqfs is outdated' "$tmp/error"
