#!/usr/bin/env bash
# compile-idump.sh - Rebuild the idump viewer from the included source
# code (idump-0.2.0.tar.gz, MIT license, by uobikiemukot/idump, plus a
# small local patch adding centered fit, true cover scaling and a
# brightness option: idump -c/-f -d PERCENT).
#
# Only needed if the included "idump" binary does not run on your
# machine (for example, if your architecture is not x86_64).
#
# Requirements (temporary; you can remove them afterwards):
#   sudo apt-get install -y --no-install-recommends gcc libc6-dev
#
# The result is a statically linked binary: it needs no runtime
# libraries at all.
set -Eeuo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TAR="$DIR/idump-0.2.0.tar.gz"
[ -f "$TAR" ] || { echo "Missing $TAR" >&2; exit 1; }
command -v gcc >/dev/null 2>&1 || {
    echo "gcc is missing. Install: sudo apt-get install -y --no-install-recommends gcc libc6-dev" >&2
    exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$TAR" -C "$TMP"
cd "$TMP/idump-0.2.0/static"
gcc -static -Os -s -std=gnu99 -fgnu89-inline \
    ../libnsgif.c ../libnsbmp.c ../lodepng.c idump.c -o "$DIR/idump"
chmod 0755 "$DIR/idump"
echo "OK: $DIR/idump"
file "$DIR/idump" || true
