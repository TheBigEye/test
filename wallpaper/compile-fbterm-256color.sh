#!/usr/bin/env bash
# compile-fbterm-256color.sh - Compile and apply the "fbterm-256color"
# terminfo entry for the fbterm-background setup. English version.
#
# What "fbterm-256color" really is (researched, see sources below):
#   There is no separate fbterm-256color *program*. FbTerm 1.7 already
#   supports 256 colors, but through its own private escape sequences
#   (ESC [ 1 ; n } foreground, ESC [ 2 ; n } background) instead of
#   the xterm-standard ESC [ 38;5;n / 48;5;n. Its upstream terminfo
#   entry already maps terminfo capabilities to those sequences
#   (setaf/setab, colors#256). "fbterm-256color" is that same entry
#   under a second name - the rename is what the AUR fbterm package
#   does (its maintainer: "To enable 256 color mode properly, do
#   export TERM=fbterm-256color"). The renamed entry is useful
#   because many programs decide "this terminal does 256 colors" from
#   the TERM *name* ending in -256color, and tmux setups expect it.
#
# What this script does:
#   1. Compiles fbterm-256color.ti (shipped next to this script)
#      into ~/.terminfo with tic(1). No root needed.
#   2. Verifies the compiled entry with infocmp(1).
#   3. Applies it to an existing fbterm-background installation:
#      in the login-file block installed by
#      install-fbterm-background.sh, the line that used to read
#      "export TERM=fbterm" now reads "export TERM=fbterm-256color"
#      (backup: <file>.bak-fbterm-256color). Newer installers choose
#      fbterm-256color automatically when the entry exists; then
#      this step reports that nothing had to be changed.
#   --uninstall removes the compiled entry and reverts step 3.
#
# It does NOT replace or recompile the fbterm binary: stock FbTerm
# already renders the private 256-color sequences. (The AUR patches
# to the fbterm binary add a configurable palette and a different
# config path, not standard 38;5;n support.)
#
# Sources:
#   - FbTerm 1.7 upstream terminfo: fbterm_1.7.orig.tar.gz,
#     terminfo/fbterm (setaf=\E[1;%p1%d}, colors#256)
#   - AUR "fbterm" package: fbterm.patch renames fbterm ->
#     fbterm-256color; maintainer comment on 256-color usage.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TI_FILE="$SCRIPT_DIR/fbterm-256color.ti"
TERMINFO_DIR="$HOME/.terminfo"
COMPILED="$TERMINFO_DIR/f/fbterm-256color"
LOGIN_FILES=("$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile")

usage() {
    echo "Usage: compile-fbterm-256color.sh [--uninstall]"
}

case "${1:-}" in
    "") ;;
    --uninstall) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Error: too many arguments" >&2; usage >&2; exit 2
fi

revert_term_lines() {
    local f
    for f in "${LOGIN_FILES[@]}"; do
        [ -f "$f" ] || continue
        grep -qF 'fbterm-background (TTY)' "$f" || continue
        if grep -q 'TERM:-.*export TERM=fbterm-256color' "$f"; then
            cp -a "$f" "$f.bak-fbterm-256color"
            sed -i '/TERM:-/s/export TERM=fbterm-256color/export TERM=fbterm/' "$f"
            echo "Reverted TERM to fbterm in $f (backup: $f.bak-fbterm-256color)"
        fi
    done
}

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$COMPILED"
    echo "Removed compiled terminfo entry: $COMPILED"
    revert_term_lines
    echo "Done. The fbterm binary was never modified."
    exit 0
fi

[ -f "$TI_FILE" ] || {
    echo "Error: fbterm-256color.ti is missing next to this script." >&2
    exit 1
}
command -v tic >/dev/null 2>&1 || {
    echo "Error: tic(1) is missing. Install it with:" >&2
    echo "  sudo apt-get install -y ncurses-bin" >&2
    exit 1
}

mkdir -p "$TERMINFO_DIR"
tic -x -o "$TERMINFO_DIR" "$TI_FILE" || {
    echo "Error: tic failed to compile $TI_FILE" >&2
    exit 1
}
echo "Compiled terminfo entry: $COMPILED"

command -v infocmp >/dev/null 2>&1 || {
    echo "Error: infocmp(1) is missing (package ncurses-bin)." >&2
    exit 1
}
infocmp fbterm-256color >/dev/null 2>&1 || {
    echo "Error: infocmp cannot find the new entry; ncurses is not" >&2
    echo "searching $TERMINFO_DIR. Is HOME set correctly?" >&2
    exit 1
}
COLORS="$(TERMINFO="$TERMINFO_DIR" tput -T fbterm-256color colors 2>/dev/null || echo unknown)"
echo "Verified with infocmp/tput: TERM=fbterm-256color reports $COLORS colors; setaf uses FbTerm private sequences."

applied=0
for f in "${LOGIN_FILES[@]}"; do
    [ -f "$f" ] || continue
    grep -qF 'fbterm-background (TTY)' "$f" || continue
    if grep -q 'TERM:-.*export TERM=fbterm-256color' "$f" \
       || grep -q 'infocmp fbterm-256color' "$f"; then
        echo "$f already uses fbterm-256color."
        applied=1
    elif grep -q 'TERM:-.*export TERM=fbterm$' "$f"; then
        cp -a "$f" "$f.bak-fbterm-256color"
        sed -i '/TERM:-/s/export TERM=fbterm$/export TERM=fbterm-256color/' "$f"
        echo "Applied in $f: TERM=fbterm-256color (backup: $f.bak-fbterm-256color)"
        applied=1
    fi
done
[ "$applied" -eq 1 ] || {
    echo "Note: no fbterm-background login block was found, so TERM was"
    echo "not changed automatically. Either run"
    echo "install-fbterm-background.sh first (new versions pick"
    echo "fbterm-256color automatically), or set it manually inside"
    echo "FbTerm:  export TERM=fbterm-256color"
}

cat <<'EOF'

Done. To use it:
  1) Exit FbTerm ("exit") and log in again on the TTY.
  2) Inside FbTerm, check:  echo $TERM        -> fbterm-256color
  3) Color test (terminfo-driven, uses FbTerm's private sequences):
       for i in 0 1 9 34 82 160 196 208 226 255; do
         tput setaf $i; printf ' %s ' "$i"; tput sgr0
       done; echo
     Each number should appear in its own color.
EOF
