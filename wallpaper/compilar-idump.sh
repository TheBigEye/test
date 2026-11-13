#!/usr/bin/env bash
# compilar-idump.sh - Recompila el visor idump desde el codigo fuente
# incluido (idump-0.2.0.tar.gz, licencia MIT, de uobikiemukot/idump).
#
# Solo hace falta si el binario "idump" incluido no sirve en tu equipo
# (por ejemplo, si tu arquitectura no es x86_64).
#
# Requisitos (temporales, puedes quitarlos despues):
#   sudo apt-get install -y --no-install-recommends gcc libc6-dev
#
# El resultado es un binario enlazado estaticamente: no depende de
# ninguna biblioteca en tiempo de ejecucion.
set -Eeuo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TAR="$DIR/idump-0.2.0.tar.gz"
[ -f "$TAR" ] || { echo "Falta $TAR" >&2; exit 1; }
command -v gcc >/dev/null 2>&1 || {
    echo "Falta gcc. Instala: sudo apt-get install -y --no-install-recommends gcc libc6-dev" >&2
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
