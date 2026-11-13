#!/usr/bin/env bash
# ============================================================================
# install-fbterm-background.sh  (slim version, no X11)
#
# Sets an image as the TTY background (no X11, no Wayland, no window
# manager) using only:
#   - fbterm    (Debian trixie 1.7-5)  framebuffer terminal emulator
#   - idump     (included patched static binary, no dependencies)
#               tiny viewer that paints the image on /dev/fb0 and exits;
#               this build adds true "cover" scaling and darkening
#   - fastfetch (Debian trixie 2.40.4) runs once when the session starts
#
# Why not fbi?
#   The FbTerm manual suggests painting the image first with a viewer
#   (fbv, which does not exist in trixie). Debian's alternative is fbi,
#   but fbi belongs to fbida and pulls in libcairo2 (which depends on
#   libx11-6, libxcb and libxrender), Mesa, Poppler, NSS... and, with
#   APT's recommended packages, Ghostscript as well. That is far too
#   much just to paint one image. idump does exactly that (paint and
#   exit) in a single static binary: MIT source included in
#   idump-0.2.0.tar.gz, rebuildable with ./compile-idump.sh. Without
#   fbi there is no need for ImageMagick either: idump scales/crops
#   the original image to the real framebuffer size at login and
#   darkens it (45% brightness by default) so text stays readable.
#
# Font:
#   FbTerm cannot load kernel PSF console fonts. This package ships
#   Default8x16.bdf, converted from Debian console-data's classic
#   default8x16.psf.gz (8x16 pixels, 256 glyphs), plus a fontconfig
#   rule that accepts only this bitmap font. The result is the
#   classic crisp console look instead of an antialiased vector font.
#
# How it works:
#   FbTerm does not read image files: if FBTERM_BACKGROUND_IMAGE is set
#   when it starts, it captures whatever is already on the framebuffer
#   and uses it as the text background (see "man fbterm", section
#   BACKGROUND IMAGE). So the launcher first paints with idump (which
#   does not clear the screen when it exits) and then runs fbterm.
#   Your original TTY (getty + login on /dev/ttyN) is untouched:
#   FbTerm only replaces text rendering while it is active, and
#   Typing "exit" inside FbTerm returns you to the kernel console.
#
# Usage:
#   ./install-fbterm-background.sh [--no-apt] [--allow-root]
#   ./install-fbterm-background.sh --uninstall
#
# What it installs/modifies:
#   ~/.local/bin/fbterm-background        launcher (idump + fbterm)
#   ~/.local/bin/idump                    included static viewer
#   ~/.bash_profile, ~/.bash_login or     startup block between >>>
#     ~/.profile (first existing file)    and <<< markers
#   ~/.fbtermrc                           only if it does not exist
#   ~/.local/share/fbterm-background/     original wallpaper
#   ~/.local/share/fonts/fbterm-background/ Default8x16 bitmap font
#   ~/.config/fontconfig/conf.d/          accept the bitmap font
#   ~/.config/fbterm-background/          config and disable switch
#
# APT packages (with --no-install-recommends): fbterm and fastfetch.
# No font package is installed: the 8x16 bitmap font is bundled.
# No X11: fbterm only needs fontconfig/freetype (font libraries, not
# X). Note: "libx86-1" is NOT X11, it is an x86 real-mode library
# used by fbterm's VESA mode.
#
# Emergency exits:
#   - Inside FbTerm: type "exit". (FbTerm's Ctrl+Alt+E shortcut
#     needs CAP_SYS_TTY_CONFIG; see "man fbterm", SECURITY NOTES.)
#   - Disable without uninstalling:
#         touch ~/.config/fbterm-background/disabled
#   - FbTerm without background, once:  fbterm-background --no-background
# ============================================================================

set -Eeuo pipefail

# --- Editable settings --------------------------------------------------------
FONT_NAME="Default8x16"   # bundled classic 8x16 bitmap font
FONT_SIZE=16              # FbTerm font size (~/.fbtermrc)
FONT_WIDTH=8              # forced classic console cell width
FONT_HEIGHT=16            # forced classic console cell height
BACKGROUND_MODE="cover"   # cover = fill the real display, cropping
                          # fit   = original image, complete and centered
BACKGROUND_BRIGHTNESS=45   # percent: 100 = original, lower = darker
# ------------------------------------------------------------------------------

DEST_BIN="$HOME/.local/bin/fbterm-background"
DEST_IDUMP="$HOME/.local/bin/idump"
DEST_DATA="$HOME/.local/share/fbterm-background"
DEST_CONFIG_DIR="$HOME/.config/fbterm-background"
DEST_FONT_DIR="$HOME/.local/share/fonts/fbterm-background"
DEST_FONTCONFIG_DIR="$HOME/.config/fontconfig/conf.d"
DEST_FONTCONFIG_FILE="$DEST_FONTCONFIG_DIR/70-fbterm-background-bitmap.conf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MARK_BEGIN='# >>> fbterm-background (TTY) >>>'
MARK_END='# <<< fbterm-background (TTY) <<<'
SOURCE_BEGIN='# >>> fbterm-background profile-source >>>'
SOURCE_END='# <<< fbterm-background profile-source <<<'
LEGACY_BEGIN='# >>> fbterm-fondo (TTY) >>>'
LEGACY_END='# <<< fbterm-fondo (TTY) <<<'

PROFILE_CANDIDATES=("$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile")

USE_APT=1
ALLOW_ROOT=0
NO_APT_SEEN=0
UNINSTALL=0

usage() {
    cat <<'EOF'
Usage:
  install-fbterm-background.sh [--no-apt] [--allow-root]
  install-fbterm-background.sh --uninstall

Options:
  --no-apt     Do not install APT packages; only warn about missing ones.
  --allow-root Allow running as root (installs into root's home directory).
  --uninstall  Remove everything this installer created.
  -h, --help   Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-apt) USE_APT=0; NO_APT_SEEN=1 ;;
        --allow-root) ALLOW_ROOT=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *) echo "Unexpected argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$UNINSTALL" -eq 1 ] && { [ "$NO_APT_SEEN" -eq 1 ] || [ "$ALLOW_ROOT" -eq 1 ]; }; then
    echo "Error: --uninstall cannot be combined with --no-apt or --allow-root." >&2
    exit 2
fi

# Running as root would install everything into root's home directory,
# leaving the real user with nothing. Refuse unless explicitly allowed.
if [ "$(id -u)" -eq 0 ] && [ "$ALLOW_ROOT" -ne 1 ]; then
    echo "Error: do not run this installer as root; it would install into" >&2
    echo "root's home directory. Run it as your normal user (it uses sudo" >&2
    echo "internally for APT), or pass --allow-root if you really mean it." >&2
    exit 1
fi

# Remove a marker-delimited block from a profile file.
# Safety rule: the range is deleted ONLY if a begin marker exists and an
# end marker exists AFTER it. A missing or out-of-order end marker means
# the file is left completely untouched (return code 3) instead of
# deleting everything from the begin marker to the end of the file.
# Returns: 0 = removed or nothing to remove, 3 = malformed block.
remove_block() {
    local file="$1" begin="$2" end="$3"
    [ -f "$file" ] || return 0
    local begin_line end_line
    begin_line="$(grep -n -m 1 -F -- "$begin" "$file" | cut -d: -f1 || true)"
    [ -n "$begin_line" ] || return 0
    end_line="$(awk -v b="$begin" -v e="$end" '
        $0 == b { seen = 1; next }
        seen && $0 == e { print NR; exit }
    ' "$file")"
    if [ -z "$end_line" ]; then
        echo "Warning: malformed block in $file: begin marker at line" >&2
        echo "$begin_line has no end marker after it. The file was NOT" >&2
        echo "modified. Fix or remove that block manually, then retry." >&2
        return 3
    fi
    cp -a "$file" "$file.bak-fbterm-background"
    sed -i "${begin_line},${end_line}d" "$file"
    echo "Block removed from $file (backup: $file.bak-fbterm-background)"
}

# Remove every block owned by this installer (current and legacy) from a
# single file. Returns 3 if any block in the file is malformed.
clean_profile_file() {
    local file="$1" rc=0
    remove_block "$file" "$MARK_BEGIN" "$MARK_END" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    remove_block "$file" "$SOURCE_BEGIN" "$SOURCE_END" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    remove_block "$file" "$LEGACY_BEGIN" "$LEGACY_END" || rc=$?
    return "$rc"
}

if [ "$UNINSTALL" -eq 1 ]; then
    for f in "${PROFILE_CANDIDATES[@]}"; do
        clean_profile_file "$f" >/dev/null || true
    done
    # Current files.
    rm -f "$DEST_BIN" "$DEST_IDUMP" "$DEST_FONTCONFIG_FILE"
    rm -rf "$HOME/.cache/fbterm-background" "$DEST_CONFIG_DIR" "$DEST_DATA" \
           "$DEST_FONT_DIR"
    # Legacy files from the previous (Spanish) version.
    rm -f "$HOME/.local/bin/fbterm-fondo"
    rm -rf "$HOME/.cache/fbterm-fondo" "$HOME/.config/fbterm-fondo" \
           "$HOME/.local/share/fbterm-fondo"
    # Only remove ~/.fbtermrc if this installer created it.
    if [ -f "$HOME/.fbtermrc" ] \
       && grep -qF '# Created by fbterm-background installer' "$HOME/.fbtermrc"; then
        rm -f "$HOME/.fbtermrc"
        echo "Removed ~/.fbtermrc (created by this installer)."
    fi
    echo "Uninstalled. Profile backups (*.bak-fbterm-background) were kept."
    echo "APT packages were not touched; remove them with:"
    echo "  sudo apt-get purge fbterm fastfetch"
    exit 0
fi

# --- Files shipped next to this script ----------------------------------------
[ -f "$SCRIPT_DIR/wallpaper.png" ] || {
    echo "Error: wallpaper.png is missing next to this script." >&2; exit 1; }
[ -f "$SCRIPT_DIR/idump" ] || {
    echo "Error: the idump binary is missing next to this script." >&2
    echo "If your architecture is not x86_64, build it first: ./compile-idump.sh" >&2
    exit 1; }
[ -f "$SCRIPT_DIR/Default8x16.bdf" ] || {
    echo "Error: Default8x16.bdf is missing next to this script." >&2; exit 1; }

# --- Required packages (Debian trixie, no recommends) --------------------------
PACKAGES=()
command -v fbterm    >/dev/null 2>&1 || PACKAGES+=(fbterm)
command -v fastfetch >/dev/null 2>&1 || PACKAGES+=(fastfetch)

if [ "${#PACKAGES[@]}" -gt 0 ] && [ "$USE_APT" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "Error: missing packages (${PACKAGES[*]}) and sudo is unavailable." >&2
        echo "Install as root: apt-get install -y --no-install-recommends ${PACKAGES[*]}" >&2
        echo "then run this script again with --no-apt." >&2
        exit 1
    fi
    SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""
    echo "Installing packages: ${PACKAGES[*]}"
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends "${PACKAGES[@]}"
elif [ "${#PACKAGES[@]}" -gt 0 ]; then
    echo "Warning (--no-apt): missing packages; install: ${PACKAGES[*]}" >&2
fi

# fbterm/idump need read/write access to /dev/fb0 (video group).
if [ -e /dev/fb0 ] && ! id -nG | grep -qw video; then
    if [ "$USE_APT" -eq 1 ] && { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1; }; then
        SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""
        echo "Adding your user to the video group (/dev/fb0 access)..."
        $SUDO usermod -aG video "$USER"
        echo "Note: the new group only takes effect at your NEXT login."
    else
        echo "Warning: add your user to the video group:  sudo usermod -aG video $USER" >&2
    fi
fi

# --- Copy wallpaper, viewer and source ----------------------------------------
mkdir -p "$DEST_DATA" "$DEST_CONFIG_DIR" "$HOME/.local/bin" \
         "$DEST_FONT_DIR" "$DEST_FONTCONFIG_DIR"
install -m 0644 "$SCRIPT_DIR/wallpaper.png" "$DEST_DATA/wallpaper.png"
# The old pre-cropped 16:9 file is no longer used: idump now fits the
# original image to the actual framebuffer at login.
rm -f "$DEST_DATA/wallpaper-16x9.png"
install -m 0644 "$SCRIPT_DIR/Default8x16.bdf" "$DEST_FONT_DIR/Default8x16.bdf"
cat > "$DEST_FONTCONFIG_FILE" <<'EOF_FONTCONFIG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- fbterm-background: Debian fontconfig rejects bitmap fonts by
     default. Accept only the bundled classic 8x16 console font. -->
<fontconfig>
  <selectfont>
    <acceptfont>
      <pattern>
        <patelt name="family"><string>Default8x16</string></patelt>
      </pattern>
    </acceptfont>
  </selectfont>
</fontconfig>
EOF_FONTCONFIG
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$DEST_FONT_DIR" >/dev/null 2>&1 || true
fi
install -m 0755 "$SCRIPT_DIR/idump" "$DEST_IDUMP"
# Transparency: the viewer's source code is installed too.
if [ -f "$SCRIPT_DIR/idump-0.2.0.tar.gz" ]; then
    install -m 0644 "$SCRIPT_DIR/idump-0.2.0.tar.gz" "$DEST_DATA/"
fi
# Drop stale caches from previous versions.
rm -rf "$HOME/.cache/fbterm-background" "$HOME/.cache/fbterm-fondo"
echo "Wallpaper and viewer installed in $DEST_DATA and $DEST_IDUMP"

# Make sure the shipped binary actually runs on this architecture.
if ! "$DEST_IDUMP" -h >/dev/null 2>&1; then
    echo "Warning: the included idump binary does not run on this machine" >&2
    echo "(architecture other than x86_64?). Rebuild it with:" >&2
    echo "  sudo apt-get install -y --no-install-recommends gcc libc6-dev" >&2
    echo "  ./compile-idump.sh && ./install-fbterm-background.sh --no-apt" >&2
fi

# Persistent settings: created once, NEVER overwritten on reinstall,
# so a mode you chose (e.g. FBTERM_MODE=fit) survives updates.
if [ ! -f "$DEST_CONFIG_DIR/config" ]; then
    cat > "$DEST_CONFIG_DIR/config" <<EOF_CFG
# Persistent background settings.
# cover = fill the display, cropping; fit = whole image, centered.
# FBTERM_BRIGHTNESS is a percentage: 100 is the original image.
FBTERM_MODE=$BACKGROUND_MODE
FBTERM_BRIGHTNESS=$BACKGROUND_BRIGHTNESS
EOF_CFG
    echo "Created $DEST_CONFIG_DIR/config (FBTERM_MODE=$BACKGROUND_MODE)"
else
    echo "Keeping existing $DEST_CONFIG_DIR/config (not overwritten)."
fi

# --- Create the launcher ~/.local/bin/fbterm-background ------------------------
cat > "$DEST_BIN" <<'EOF_LAUNCHER'
#!/usr/bin/env bash
# fbterm-background: paint the wallpaper with idump, open FbTerm over it.
# Usage: fbterm-background [--no-background]
set -u

DATA="$HOME/.local/share/fbterm-background"
IDUMP_BIN="$HOME/.local/bin/idump"
FBDEV="${FRAMEBUFFER:-/dev/fb0}"
NO_BACKGROUND=0

case "${1:-}" in
    "") ;;
    --no-background) NO_BACKGROUND=1 ;;
    -h|--help) echo "Usage: fbterm-background [--no-background]"; exit 0 ;;
    *) echo "fbterm-background: unknown argument: $1" >&2
       echo "Usage: fbterm-background [--no-background]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "fbterm-background: too many arguments" >&2
    echo "Usage: fbterm-background [--no-background]" >&2
    exit 2
fi

# Persistent settings are parsed, NOT sourced: the file is plain
# KEY=VALUE data, never shell code. Only FBTERM_MODE is honoured, and
# only the values "cover" and "fit" are accepted.
MODE="cover"
BRIGHTNESS=45
CONFIG_FILE="$HOME/.config/fbterm-background/config"
if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        # Trim surrounding whitespace.
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        case "$line" in
            FBTERM_MODE=cover|FBTERM_MODE=fit)
                MODE="${line#FBTERM_MODE=}" ;;
            FBTERM_MODE=*)
                echo "fbterm-background: ignoring invalid FBTERM_MODE in $CONFIG_FILE" >&2 ;;
            FBTERM_BRIGHTNESS=[0-9]|FBTERM_BRIGHTNESS=[0-9][0-9]|FBTERM_BRIGHTNESS=100)
                BRIGHTNESS="${line#FBTERM_BRIGHTNESS=}" ;;
            FBTERM_BRIGHTNESS=*)
                echo "fbterm-background: ignoring invalid FBTERM_BRIGHTNESS in $CONFIG_FILE" >&2 ;;
        esac
    done < "$CONFIG_FILE"
fi
# A valid environment variable overrides the config file.
case "${FBTERM_MODE:-}" in
    cover|fit) MODE="$FBTERM_MODE" ;;
    "") ;;
    *) echo "fbterm-background: ignoring invalid FBTERM_MODE in environment" >&2 ;;
esac
case "${FBTERM_BRIGHTNESS:-}" in
    [0-9]|[0-9][0-9]|100) BRIGHTNESS="$FBTERM_BRIGHTNESS" ;;
    "") ;;
    *) echo "fbterm-background: ignoring invalid FBTERM_BRIGHTNESS in environment" >&2 ;;
esac

IMG="$DATA/wallpaper.png"
if [ "$MODE" = "fit" ]; then
    IDUMP_ARGS=(-f -d "$BRIGHTNESS")
else
    IDUMP_ARGS=(-c -d "$BRIGHTNESS")
fi

fail() { echo "fbterm-background: $*" >&2; exit 1; }

# Anti-loop and environment guards: physical TTY only, no X11/Wayland,
# never twice.
[ -z "${FBTERM_BACKGROUND_ACTIVE:-}" ] || fail "you are already inside FbTerm."
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    fail "a graphical session is running; this is for TTYs only."
fi
TTY_ACTUAL="$(tty 2>/dev/null || true)"
case "$TTY_ACTUAL" in
    /dev/tty[0-9]*)
        case "${TTY_ACTUAL#/dev/tty}" in
            *[!0-9]*|'') fail "not a physical TTY ($TTY_ACTUAL). Log in on tty1-tty6 and retry." ;;
        esac
        ;;
    *) fail "not a physical TTY ($TTY_ACTUAL). Log in on tty1-tty6 and retry." ;;
esac

command -v fbterm >/dev/null 2>&1 || fail "fbterm is missing: sudo apt-get install --no-install-recommends fbterm"

open_fbterm() {
    export FBTERM_BACKGROUND_ACTIVE=1
    if [ "$1" -eq 1 ]; then
        unset FBTERM_BACKGROUND_IMAGE
    else
        export FBTERM_BACKGROUND_IMAGE=1
    fi
    # FbTerm diagnostics go to a log file, never to the physical
    # console. Anything the kernel console draws on the framebuffer
    # before FbTerm captures it (e.g. the "[input] can't change
    # kernel keymap table" warning, printed because FbTerm lacks
    # CAP_SYS_TTY_CONFIG; see "man fbterm", SECURITY NOTES) would be
    # baked into the background image and stay visible forever.
    LOG_DIR="$HOME/.cache/fbterm-background"
    mkdir -p "$LOG_DIR"
    fbterm -- /bin/bash -l 2>"$LOG_DIR/fbterm.log"
    FBTERM_STATUS=$?
    # Re-show the kernel-console cursor (hidden while painting; see
    # below). FbTerm draws its own cursor while it runs.
    printf '\033[?25h'
    if [ "$FBTERM_STATUS" -ne 0 ]; then
        echo "fbterm-background: fbterm exited with status $FBTERM_STATUS; last log lines:" >&2
        tail -n 20 "$LOG_DIR/fbterm.log" >&2 2>/dev/null || true
    fi
    exit "$FBTERM_STATUS"
}

if [ "$NO_BACKGROUND" -eq 1 ]; then
    open_fbterm 1
fi

# From here on the image has to be painted onto the framebuffer.
# A relative FRAMEBUFFER value would depend on the current directory,
# so only absolute paths are accepted.
paint_ok=1
case "$FBDEV" in
    /*) ;;
    *) echo "fbterm-background: FRAMEBUFFER must be an absolute path (got: $FBDEV)" >&2; paint_ok=0 ;;
esac
if [ "$paint_ok" -eq 1 ] \
   && { [ ! -f "$IMG" ] || [ ! -x "$IDUMP_BIN" ] \
        || [ ! -e "$FBDEV" ] || [ ! -r "$FBDEV" ] || [ ! -w "$FBDEV" ]; }; then
    paint_ok=0
fi
if [ "$paint_ok" -ne 1 ]; then
    echo "fbterm-background: cannot paint the background (image, viewer or" >&2
    echo "permissions on $FBDEV). Opening FbTerm without a background." >&2
    echo "Hint: /dev/fb0 access requires the video group." >&2
    sleep 2
    open_fbterm 1
fi

# idump paints and exits without clearing the screen; FbTerm captures
# that framebuffer as its background because FBTERM_BACKGROUND_IMAGE
# is set. timeout protects the login: a hung viewer can never block
# the session for more than 10 seconds.
export FRAMEBUFFER="$FBDEV"
printf '\033[?25l'
if command -v timeout >/dev/null 2>&1; then
    timeout 10 "$IDUMP_BIN" "${IDUMP_ARGS[@]}" "$IMG" >/dev/null 2>&1
else
    "$IDUMP_BIN" "${IDUMP_ARGS[@]}" "$IMG" >/dev/null 2>&1
fi
IDUMP_STATUS=$?
# The cursor stays hidden: if the kernel console drew its block
# cursor now, FbTerm would capture it into the background image
# (a permanent black square). open_fbterm restores it on exit.
if [ "$IDUMP_STATUS" -ne 0 ]; then
    echo "fbterm-background: idump failed (status $IDUMP_STATUS); opening without a background." >&2
    sleep 2
    open_fbterm 1
fi
open_fbterm 0
EOF_LAUNCHER
chmod 0755 "$DEST_BIN"
echo "Launcher created: $DEST_BIN"

# --- FbTerm configuration -------------------------------------------------------
# A file created by this installer is refreshed on reinstall (this is
# how the classic 8x16 font replaces the old vector "mono" setting).
# A file you created yourself is never overwritten.
if [ ! -f "$HOME/.fbtermrc" ] \
   || grep -qF '# Created by fbterm-background installer' "$HOME/.fbtermrc"; then
    cat > "$HOME/.fbtermrc" <<EOF_FBRC
# Created by fbterm-background installer
# FbTerm configuration (see "man fbterm", options section).
font-names=$FONT_NAME
font-size=$FONT_SIZE
font-width=$FONT_WIDTH
font-height=$FONT_HEIGHT
color-foreground=7
color-background=0
history-lines=5000
text-encodings=
EOF_FBRC
    echo "Configured $HOME/.fbtermrc (classic 8x16 bitmap font)"
else
    echo "$HOME/.fbtermrc already exists and was not created by this installer: not modified."
    echo "For the classic console font, set: font-names=$FONT_NAME, font-size=$FONT_SIZE, font-width=$FONT_WIDTH, font-height=$FONT_HEIGHT"
fi

# --- Startup block in the login profile -----------------------------------------
# Bash reads only the FIRST existing file among ~/.bash_profile,
# ~/.bash_login and ~/.profile. To avoid silently disabling an existing
# ~/.profile (the usual Debian setup), the block goes into whichever of
# those files Bash would actually read, and any block from a previous
# installation is removed from all of them first.
TARGET_PROFILE=""
for f in "${PROFILE_CANDIDATES[@]}"; do
    if [ -f "$f" ]; then TARGET_PROFILE="$f"; break; fi
done
if [ -z "$TARGET_PROFILE" ]; then
    TARGET_PROFILE="$HOME/.bash_profile"
    cat > "$TARGET_PROFILE" <<'EOF_NEWPROFILE'
# ~/.bash_profile
# Bash reads only the first existing login file, so keep the other
# login files effective if they are created later.
if [ -f "$HOME/.bash_login" ]; then
    . "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
EOF_NEWPROFILE
    echo "Created $TARGET_PROFILE"
fi

for f in "${PROFILE_CANDIDATES[@]}"; do
    rc=0
    clean_profile_file "$f" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "Error: $f contains a malformed fbterm-background block and" >&2
        echo "was left untouched. Fix it manually, then run this again." >&2
        exit 1
    fi
done
# Also strip the legacy launcher, in case an old install is present.
rm -f "$HOME/.local/bin/fbterm-fondo"
rm -rf "$HOME/.config/fbterm-fondo" "$HOME/.local/share/fbterm-fondo"

# If the target is ~/.bash_profile or ~/.bash_login, Bash skips the
# remaining login files. Unless the target already sources one of them,
# add a small compatibility block so the skipped file still runs.
case "$TARGET_PROFILE" in
    "$HOME/.profile") ;;
    *)
        if ! grep -Eq '(\.|source)[[:space:]]+.*\.(profile|bash_login)' "$TARGET_PROFILE" \
           && { [ -f "$HOME/.bash_login" ] || [ -f "$HOME/.profile" ]; }; then
            cat >> "$TARGET_PROFILE" <<'EOF_SOURCE'
# >>> fbterm-background profile-source >>>
# Bash reads only the first existing login file; source the one it
# would otherwise skip, so existing settings keep working.
if [ -f "$HOME/.bash_login" ]; then
    . "$HOME/.bash_login"
elif [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
# <<< fbterm-background profile-source <<<
EOF_SOURCE
        fi
        ;;
esac

cat >> "$TARGET_PROFILE" <<'EOF_PROFILE'
# >>> fbterm-background (TTY) >>>
# Background with FbTerm + fastfetch on physical TTYs only, no X11/Wayland.
# Disable without uninstalling: touch ~/.config/fbterm-background/disabled
if [ -z "${FBTERM_BACKGROUND_ACTIVE:-}" ]; then
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] \
       && [ ! -f "$HOME/.config/fbterm-background/disabled" ]; then
        _fbterm_tty="$(tty 2>/dev/null)"
        _fbterm_num="${_fbterm_tty#/dev/tty}"
        case "$_fbterm_tty" in
            /dev/tty[0-9]*)
                case "$_fbterm_num" in
                    *[!0-9]*|'') ;;
                    *)
                        if "$HOME/.local/bin/fbterm-background"; then
                            exit
                        fi
                        echo "fbterm-background could not start; you are still on the normal TTY." >&2
                        ;;
                esac
                ;;
        esac
        unset _fbterm_tty _fbterm_num
    fi
elif [ -z "${FBTERM_FASTFETCH_DONE:-}" ]; then
    export FBTERM_FASTFETCH_DONE=1
    [ "${TERM:-}" = "linux" ] && export TERM=fbterm
    if command -v fastfetch >/dev/null 2>&1; then
        # On a TTY, fastfetch wraps the Disk mountpoint in an OSC 8
        # hyperlink (ESC ] 8 ;; file://...). FbTerm's escape parser
        # predates OSC 8 and prints it as garbage ("Disk
        # (://///;:;)"), so strip OSC sequences from its output.
        # "--pipe false" keeps colors even though stdout is a pipe,
        # and only OSC (ESC ]) is removed; colors (ESC [) survive.
        if command -v perl >/dev/null 2>&1; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 15 fastfetch --pipe false | perl -pe 's/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g' || true
            else
                fastfetch --pipe false | perl -pe 's/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g' || true
            fi
        elif command -v timeout >/dev/null 2>&1; then
            timeout 15 fastfetch || true
        else
            fastfetch || true
        fi
    fi
fi
# <<< fbterm-background (TTY) <<<
EOF_PROFILE
echo "Automatic startup added to $TARGET_PROFILE"

cat <<'EOF'

Done. How to try it:
  1) Log out and back in on a TTY (tty1-tty6), or run directly on the
     TTY:  ~/.local/bin/fbterm-background
  2) You will see your background image and fastfetch once inside
     FbTerm.
  3) To exit FbTerm: type "exit" (this also ends the login session).

Notes:
  - Image settings live in ~/.config/fbterm-background/config:
    FBTERM_MODE=cover (fill display) or =fit (whole image, centered),
    and FBTERM_BRIGHTNESS=45 (percent; lower is darker). The file is
    preserved on reinstall.
  - Font: classic Default8x16 bitmap (8x16, 256 glyphs), forced to
    an 8x16 cell in ~/.fbtermrc.
  - No fbi or ImageMagick at runtime: the only viewer is
    ~/.local/bin/idump (static, no dependencies). Its source ships
    in this folder.
  - Uninstall:  ./install-fbterm-background.sh --uninstall
EOF
