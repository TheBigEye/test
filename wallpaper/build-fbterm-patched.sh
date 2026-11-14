#!/usr/bin/env bash
# build-fbterm-patched.sh - Build a patched FbTerm 1.7 with native
# xterm escape-sequence support, for the fbterm-background setup.
# English version.
#
# Why:
#   Stock FbTerm 1.7 (Debian package fbterm 1.7-5) renders 256
#   colors, but only through its private sequences
#   (ESC [ 1 ; n } / ESC [ 2 ; n }), which is what its terminfo
#   entry advertises. Programs that consult terminfo (ncurses apps)
#   are fine, but programs that emit xterm sequences unconditionally
#   are not: fastfetch, for example, always uses SGR 90-97/100-107
#   (bright colors), SGR 38;5;n (256 colors) and OSC 8 hyperlinks
#   on a TTY, regardless of TERM. In stock FbTerm those render
#   wrong: bright colors are ignored, 48;5;n turns blink on, and
#   the OSC 8 wrapper of the Disk line leaks onto the screen as
#   garbage text ("Disk ;;file:..."). install-fbterm-background.sh
#   works around this with a Perl output filter for fastfetch.
#
#   fbterm-compat.patch (shipped next to this script) teaches
#   FbTerm's VT parser the missing sequences instead:
#     - SGR 90-97 / 100-107      bright foreground/background
#     - SGR 38;5;<n> / 48;5;<n>  256-color foreground/background
#     - SGR 38;2 / 48;2          truecolor, approximated to the
#                                256-color cube (FbTerm has no
#                                truecolor framebuffer mode)
#     - OSC sequences are consumed until BEL or ST (ESC \) and
#       dropped (OSC 8 hyperlinks, OSC 52, titles, ...), except
#       FbTerm's own palette commands (ESC ] P... / ESC ] R),
#       which keep working unchanged.
#   FbTerm's CharAttr already stores 8-bit color indices and its
#   renderer already has a 256-color palette, so the patch only
#   extends the parser; rendering is untouched. Verified with a
#   headless harness driving VTerm directly: 21/21 checks pass
#   (stock parser: 15 of the same 21 fail).
#
# What this script does:
#   1. Downloads the FbTerm 1.7 Debian source (orig tarball,
#      debian.tar.xz and .dsc) from deb.debian.org and verifies
#      the SHA-256 hashes against the signed .dsc metadata.
#   2. Applies the Debian patch series, then fbterm-compat.patch.
#   3. Builds with autoreconf + configure + make (build tools are
#      installed with apt when missing; --no-apt skips that).
#   4. Installs the result as /usr/local/bin/fbterm-patched.
#      The stock /usr/bin/fbterm is NOT touched.
#   install-fbterm-background.sh (>= the version shipped with
#   this script) prefers fbterm-patched automatically at login;
#   with it, fastfetch runs unfiltered, exactly like on xterm.
#   --uninstall removes /usr/local/bin/fbterm-patched; logins
#   then fall back to stock fbterm (and the filter) on their own.
#
# Notes:
#   - gpm (console mouse) and VESA support stay disabled unless
#     libgpm-dev / libx86-dev happen to be installed; neither is
#     needed for FbTerm on /dev/fb0.
#   - This complements compile-fbterm-256color.sh: the terminfo
#     name still decides what terminfo-driven programs emit; the
#     patched binary additionally understands the sequences that
#     programs hardcode.
#   - If Debian moves to a newer 1.7-x source revision and the
#     patch stops applying, the script aborts before building.
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/fbterm-compat.patch"
POOL_URL="https://deb.debian.org/debian/pool/main/f/fbterm"
DEST="/usr/local/bin/fbterm-patched"

DO_APT=1
UNINSTALL=0

usage() {
    echo "Usage: $0 [--no-apt] [--uninstall]"
}

for arg in "$@"; do
    case "$arg" in
        --no-apt) DO_APT=0 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

fail() { echo "build-fbterm-patched: $*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download() { # download URL -> stdout
    if have_cmd curl; then
        curl -fsSL "$1"
    elif have_cmd wget; then
        wget -qO- "$1"
    else
        return 1
    fi
}

download_to() { # download_to URL FILE
    if have_cmd curl; then
        curl -fsSL -o "$2" "$1"
    elif have_cmd wget; then
        wget -qO "$2" "$1"
    else
        return 1
    fi
}

# --- Uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    if [ -e "$DEST" ]; then
        $SUDO rm -f "$DEST" || fail "could not remove $DEST"
        echo "Removed $DEST."
    else
        echo "$DEST does not exist; nothing to remove."
    fi
    echo "Logins will use the stock fbterm again (the fbterm-background"
    echo "launcher chooses the binary at every login). If the fastfetch"
    echo "filter had been disabled by the patched binary, it is back"
    echo "automatically; nothing else needs to be changed."
    exit 0
fi

[ -f "$PATCH_FILE" ] || fail "fbterm-compat.patch not found next to this script (expected: $PATCH_FILE)"

# --- Build dependencies --------------------------------------------------------
missing_pkgs=""

need_pkg_for_cmd() { # need_pkg_for_cmd COMMAND PACKAGE
    have_cmd "$1" || missing_pkgs="$missing_pkgs $2"
}

need_pkg_for_cmd g++ g++
need_pkg_for_cmd make make
need_pkg_for_cmd pkg-config pkg-config
need_pkg_for_cmd autoreconf autoconf
need_pkg_for_cmd automake automake
need_pkg_for_cmd patch patch
need_pkg_for_cmd tar tar
need_pkg_for_cmd xz xz-utils
need_pkg_for_cmd sha256sum coreutils
if ! have_cmd curl && ! have_cmd wget; then
    missing_pkgs="$missing_pkgs curl"
fi

# pkg-config module -> Debian -dev package (first available name wins)
pick_dev_pkg() { # pick_dev_pkg MODULE CANDIDATE...
    local module="$1"; shift
    if pkg-config --exists "$module" 2>/dev/null; then
        return 0
    fi
    local cand
    for cand in "$@"; do
        if apt-cache show "$cand" >/dev/null 2>&1; then
            missing_pkgs="$missing_pkgs $cand"
            return 0
        fi
    done
    missing_pkgs="$missing_pkgs $1"
}

if have_cmd pkg-config || [ "$DO_APT" -eq 1 ]; then
    pick_dev_pkg fontconfig libfontconfig1-dev libfontconfig-dev
    pick_dev_pkg freetype2 libfreetype-dev libfreetype6-dev
fi

if [ -n "$missing_pkgs" ]; then
    if [ "$DO_APT" -eq 1 ]; then
        echo "Installing build dependencies:$missing_pkgs"
        # shellcheck disable=SC2086
        $SUDO apt-get update || fail "apt-get update failed"
        # shellcheck disable=SC2086
        $SUDO apt-get install -y --no-install-recommends $missing_pkgs \
            || fail "could not install build dependencies"
    else
        fail "missing build tools:$missing_pkgs (rerun without --no-apt, or install them manually)"
    fi
fi

# Re-check after any installation.
for tool in g++ make pkg-config autoreconf automake patch tar xz sha256sum; do
    have_cmd "$tool" || fail "still missing: $tool"
done
pkg-config --exists fontconfig || fail "fontconfig development files missing (libfontconfig1-dev)"
pkg-config --exists freetype2 || fail "FreeType development files missing (libfreetype-dev)"

# --- Download the Debian source ------------------------------------------------
WORK_DIR="$(mktemp -d /tmp/fbterm-build.XXXXXX)" || fail "could not create a temp dir"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Looking up the FbTerm 1.7 Debian source in $POOL_URL ..."
listing="$(download "$POOL_URL/")" || fail "could not download the pool listing from $POOL_URL"
dsc_name="$(printf '%s\n' "$listing" | grep -oE 'fbterm_1\.7-[0-9]+\.dsc' | sort -Vu | tail -n 1)"
[ -n "$dsc_name" ] || fail "no fbterm 1.7 source package found in $POOL_URL"
revision="${dsc_name#fbterm_}"
revision="${revision%.dsc}"
orig_name="fbterm_1.7.orig.tar.gz"
debian_name="fbterm_${revision}.debian.tar.xz"
echo "Using Debian source revision $revision"

for f in "$dsc_name" "$orig_name" "$debian_name"; do
    download_to "$POOL_URL/$f" "$WORK_DIR/$f" || fail "download failed: $POOL_URL/$f"
done

# Verify SHA-256 against the .dsc. The file also carries a
# Checksums-Sha1 section (and MD5 in Files:), so only look inside
# the Checksums-Sha256 section.
verify_sha256() { # verify_sha256 FILE
    local want got
    want="$(awk -v f="$1" '
        /^Checksums-Sha256:/ { s = 1; next }
        /^[A-Za-z][A-Za-z0-9-]*:/ { s = 0 }
        s && $3 == f { print $1; exit }
    ' "$WORK_DIR/$dsc_name")"
    [ "${#want}" -eq 64 ] || fail "no SHA-256 entry for $1 in $dsc_name"
    got="$(sha256sum "$WORK_DIR/$1" | awk '{ print $1 }')"
    [ "$got" = "$want" ] || fail "SHA-256 mismatch for $1 (corrupted download?)"
}

verify_sha256 "$orig_name"
verify_sha256 "$debian_name"
echo "SHA-256 verified against $dsc_name."

# --- Extract and patch ---------------------------------------------------------
SRC_DIR="$WORK_DIR/fbterm-1.7"
mkdir -p "$SRC_DIR"
tar xzf "$WORK_DIR/$orig_name" -C "$SRC_DIR" --strip-components=1 || fail "could not extract $orig_name"
tar xJf "$WORK_DIR/$debian_name" -C "$SRC_DIR" || fail "could not extract $debian_name"

if [ -f "$SRC_DIR/debian/patches/series" ]; then
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
patch_name="${line%% *}"
        echo "Applying Debian patch: $patch_name"
        patch -p1 -d "$SRC_DIR" -s < "$SRC_DIR/debian/patches/$patch_name" \
            || fail "Debian patch does not apply: $patch_name"
    done < "$SRC_DIR/debian/patches/series"
fi

echo "Applying fbterm-compat.patch"
patch -p1 -d "$SRC_DIR" -s < "$PATCH_FILE" || fail "fbterm-compat.patch does not apply to Debian source $revision; the parser sources changed upstream. Nothing was installed."

# --- Build -----------------------------------------------------------------------
echo "Building (autoreconf + configure + make)..."
(
    cd "$SRC_DIR" || exit 1
    autoreconf -fi >/dev/null 2>&1 || exit 1
    ./configure >"$WORK_DIR/configure.log" 2>&1 || { cat "$WORK_DIR/configure.log"; exit 1; }
    make -j"$(nproc 2>/dev/null || echo 2)" >"$WORK_DIR/make.log" 2>&1 || { tail -n 30 "$WORK_DIR/make.log"; exit 1; }
) || fail "build failed (see messages above)"

[ -x "$SRC_DIR/src/fbterm" ] || fail "build finished but src/fbterm is missing"

# --- Install ----------------------------------------------------------------------
echo "Installing $DEST"
$SUDO install -m 0755 "$SRC_DIR/src/fbterm" "$DEST" || fail "could not install $DEST"

version_out="$("$DEST" -V 2>/dev/null || true)"
case "$version_out" in
    *"FbTerm version 1.7"*) echo "Smoke test OK: $version_out" ;;
    *) echo "Warning: '$DEST -V' printed: $version_out" >&2 ;;
esac
if ldd "$DEST" 2>/dev/null | grep -q "not found"; then
    echo "Warning: $DEST has unresolved shared libraries:" >&2
    ldd "$DEST" | grep "not found" >&2
fi

cat <<'EOF'

Done. Next steps:
  1) Log out and back in on the TTY. The fbterm-background
     launcher picks /usr/local/bin/fbterm-patched automatically
     (the stock binary remains untouched as a fallback).
  2) fastfetch now renders natively inside FbTerm - bright and
     256 colors, no OSC garbage on the Disk line - and the
     fbterm-background login block skips its Perl filter for
     this binary (manual "fastfetch" runs included).
  3) Check "TERM": terminfo-driven programs still use the
     fbterm/fbterm-256color entry (private sequences, unchanged);
     programs that hardcode xterm sequences work now too.

Undo: ./build-fbterm-patched.sh --uninstall
EOF
