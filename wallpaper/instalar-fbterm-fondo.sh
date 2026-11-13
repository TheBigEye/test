#!/usr/bin/env bash
# ============================================================================
# instalar-fbterm-fondo.sh  (version slim, sin X11)
#
# Pone una imagen como fondo de la TTY (sin X11, sin Wayland, sin gestor de
# ventanas) usando solo:
#   - fbterm    (Debian trixie 1.7-5)  emulador de terminal framebuffer
#   - idump     (binario estatico incluido, 809 KB, sin dependencias)
#               visor minimo que pinta la imagen en /dev/fb0 y sale
#   - fastfetch (Debian trixie 2.40.4) se ejecuta una vez al entrar
#
# Por que NO se usa fbi?
#   El manual de FbTerm sugiere pintar antes la imagen con un visor
#   (fbv, que no existe en trixie). La alternativa en Debian es fbi, pero
#   fbi pertenece a fbida y arrastra libcairo2 (que depende de libx11-6,
#   libxcb y libxrender), Mesa, Poppler, NSS... y con los recomendados
#   tambien Ghostscript. Para pintar una sola imagen es desproporcionado.
#   idump hace exactamente eso (pintar y salir) en un binario estatico:
#   codigo fuente MIT incluido en idump-0.2.0.tar.gz, recompilable con
#   ./compilar-idump.sh. Sin fbi tampoco hace falta ImageMagick: junto al
#   script viene wallpaper-16x9.png, la imagen ya recortada a 1920x1080
#   y oscurecida un 18% para que el texto se lea bien.
#
# Como funciona:
#   FbTerm no lee imagenes: si FBTERM_BACKGROUND_IMAGE esta definida al
#   arrancar, captura lo que ya haya en el framebuffer y lo usa de fondo
#   (ver "man fbterm", seccion BACKGROUND IMAGE). Por eso el lanzador
#   primero pinta con idump (que no borra la pantalla al salir) y despues
#   ejecuta fbterm. Tu TTY original (getty + login en /dev/ttyN) no se
#   toca: FbTerm solo reemplaza el dibujo del texto mientras esta activo,
#   y con Ctrl+Alt+E vuelves a la consola del kernel.
#
# Uso:
#   ./instalar-fbterm-fondo.sh [--sin-apt]
#   ./instalar-fbterm-fondo.sh --desinstalar
#
# Que instala/modifica:
#   ~/.local/bin/fbterm-fondo     lanzador (idump + fbterm + fastfetch)
#   ~/.local/bin/idump            visor estatico incluido
#   ~/.bash_profile               bloque >>> / <<< de arranque en TTY
#   ~/.fbtermrc                   solo si no existe
#   ~/.local/share/fbterm-fondo/  imagen original y version 16:9
#   ~/.config/fbterm-fondo/       config (modo cover/fit) y desactivador
#
# Paquetes apt (con --no-install-recommends): fbterm, fastfetch y una
# fuente monoespaciada. Nada de X11: fbterm solo pide fontconfig/freetype
# (bibliotecas de fuentes, sin X). Ojo: "libx86-1" NO es X11, es una
# biblioteca de modo real x86 para el modo VESA de fbterm.
#
# Salida de emergencia:
#   - Dentro de FbTerm: Ctrl+Alt+E.
#   - Desactivar sin desinstalar: touch ~/.config/fbterm-fondo/desactivado
#   - FbTerm sin fondo, una vez:  fbterm-fondo --sin-fondo
# ============================================================================

set -Eeuo pipefail

# --- Ajustes editables -------------------------------------------------------
TAMANO_FUENTE=16          # tamano de letra de FbTerm (~/.fbtermrc)
MODO_FONDO="cover"        # cover = wallpaper-16x9.png (pantalla llena)
                          # fit   = imagen original completa, centrada
# -----------------------------------------------------------------------------

DEST_BIN="$HOME/.local/bin/fbterm-fondo"
DEST_IDUMP="$HOME/.local/bin/idump"
DEST_DATOS="$HOME/.local/share/fbterm-fondo"
DEST_CACHE="$HOME/.cache/fbterm-fondo"
DEST_CFG_DIR="$HOME/.config/fbterm-fondo"
PERFIL="$HOME/.bash_profile"
MARCA_INI='# >>> fbterm-fondo (TTY) >>>'
MARCA_FIN='# <<< fbterm-fondo (TTY) <<<'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APT=1
DESINSTALAR=0

uso() {
    cat <<'EOF'
Uso:
  instalar-fbterm-fondo.sh [--sin-apt]
  instalar-fbterm-fondo.sh --desinstalar
EOF
}

for arg in "$@"; do
    case "$arg" in
        --sin-apt) APT=0 ;;
        --desinstalar) DESINSTALAR=1 ;;
        -h|--help) uso; exit 0 ;;
        -*) echo "Opcion desconocida: $arg" >&2; uso >&2; exit 2 ;;
        *) echo "Argumento no esperado: $arg" >&2; uso >&2; exit 2 ;;
    esac
done

quitar_bloque_perfil() {
    [ -f "$PERFIL" ] || return 0
    grep -qF "$MARCA_INI" "$PERFIL" || return 0
    cp -a "$PERFIL" "$PERFIL.bak-fbterm-fondo"
    sed -i '/# >>> fbterm-fondo (TTY) >>>/,/# <<< fbterm-fondo (TTY) <<</d' "$PERFIL"
    echo "Bloque retirado de $PERFIL (copia en $PERFIL.bak-fbterm-fondo)"
}

if [ "$DESINSTALAR" -eq 1 ]; then
    quitar_bloque_perfil
    rm -f "$DEST_BIN" "$DEST_IDUMP"
    rm -rf "$DEST_CACHE"
    echo "Desinstalado. Se conserva la imagen en $DEST_DATOS"
    echo "y la configuracion $HOME/.fbtermrc por si quieres reutilizarlas."
    echo "Los paquetes fbterm/fastfetch no se tocan (puedes quitarlos con:"
    echo "  sudo apt-get purge fbterm fastfetch)"
    exit 0
fi

# --- Archivos incluidos junto al script ---------------------------------------
[ -f "$SCRIPT_DIR/wallpaper.png" ] || {
    echo "ERROR: falta wallpaper.png junto al script." >&2; exit 1; }
[ -f "$SCRIPT_DIR/idump" ] || {
    echo "ERROR: falta el binario idump junto al script." >&2
    echo "Si tu arquitectura no es x86_64, ejecuta antes ./compilar-idump.sh" >&2
    exit 1; }

# --- Paquetes necesarios (Debian trixie, sin recomendados) --------------------
PAQUETES=()
command -v fbterm    >/dev/null 2>&1 || PAQUETES+=(fbterm)
command -v fastfetch >/dev/null 2>&1 || PAQUETES+=(fastfetch)
if ! dpkg-query -W fonts-dejavu-core >/dev/null 2>&1 \
   && ! dpkg-query -W fonts-dejavu-mono >/dev/null 2>&1; then
    PAQUETES+=(fonts-dejavu-core)
fi

if [ "${#PAQUETES[@]}" -gt 0 ] && [ "$APT" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "ERROR: faltan paquetes (${PAQUETES[*]}) y no hay sudo." >&2
        echo "Instala como root: apt-get install -y --no-install-recommends ${PAQUETES[*]}" >&2
        echo "y vuelve a ejecutar este script con --sin-apt." >&2
        exit 1
    fi
    SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""
    echo "Instalando paquetes: ${PAQUETES[*]}"
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends "${PAQUETES[@]}"
elif [ "${#PAQUETES[@]}" -gt 0 ]; then
    echo "AVISO (--sin-apt): faltan paquetes; instala: ${PAQUETES[*]}" >&2
fi

# FbTerm/idump necesitan lectura/escritura en /dev/fb0 (grupo video).
if [ -e /dev/fb0 ] && ! id -nG | grep -qw video; then
    if [ "$APT" -eq 1 ] && { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1; }; then
        SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""
        echo "Agregando tu usuario al grupo video (acceso a /dev/fb0)..."
        $SUDO usermod -aG video "$USER"
        echo "AVISO: el grupo nuevo recien se aplica en el PROXIMO inicio de sesion."
    else
        echo "AVISO: agrega tu usuario al grupo video:  sudo usermod -aG video $USER" >&2
    fi
fi

# --- Copiar imagen, visor y fuentes del proyecto -------------------------------
mkdir -p "$DEST_DATOS" "$DEST_CFG_DIR" "$HOME/.local/bin"
install -m 0644 "$SCRIPT_DIR/wallpaper.png" "$DEST_DATOS/wallpaper.png"
if [ -f "$SCRIPT_DIR/wallpaper-16x9.png" ]; then
    install -m 0644 "$SCRIPT_DIR/wallpaper-16x9.png" "$DEST_DATOS/wallpaper-16x9.png"
fi
install -m 0755 "$SCRIPT_DIR/idump" "$DEST_IDUMP"
# Transparencia: se guarda tambien el codigo fuente del visor.
[ -f "$SCRIPT_DIR/idump-0.2.0.tar.gz" ] && \
    install -m 0644 "$SCRIPT_DIR/idump-0.2.0.tar.gz" "$DEST_DATOS/" || true
# Cache de la version anterior (con fbi): ya no se usa.
rm -rf "$DEST_CACHE"
echo "Imagen y visor instalados en $DEST_DATOS y $DEST_IDUMP"

# Comprobar que el binario incluido corre en esta arquitectura.
if ! "$DEST_IDUMP" -h >/dev/null 2>&1; then
    echo "AVISO: el binario idump incluido no se ejecuta en este equipo" >&2
    echo "(arquitectura distinta de x86_64?). Recompilalo con:" >&2
    echo "  sudo apt-get install -y --no-install-recommends gcc libc6-dev" >&2
    echo "  ./compilar-idump.sh && ./instalar-fbterm-fondo.sh --sin-apt" >&2
fi

cat > "$DEST_CFG_DIR/config" <<EOF_CFG
# Ajustes persistentes del fondo.
# cover = version 16:9 a pantalla completa; fit = original centrada.
FBTERM_MODO=$MODO_FONDO
EOF_CFG

# --- Crear el lanzador ~/.local/bin/fbterm-fondo -------------------------------
cat > "$DEST_BIN" <<'EOF_LANZADOR'
#!/usr/bin/env bash
# fbterm-fondo: pinta el wallpaper con idump y abre FbTerm usandolo de fondo.
# Uso: fbterm-fondo [--sin-fondo]
set -u

DATOS="$HOME/.local/share/fbterm-fondo"
IDUMP="$HOME/.local/bin/idump"
FBDEV="${FRAMEBUFFER:-/dev/fb0}"
SIN_FONDO=0
[ "${1:-}" = "--sin-fondo" ] && SIN_FONDO=1

_CFG="$HOME/.config/fbterm-fondo/config"
[ -f "$_CFG" ] && . "$_CFG"
MODO="${FBTERM_MODO:-cover}"
if [ "$MODO" = "fit" ]; then
    IMG="$DATOS/wallpaper.png"
else
    IMG="$DATOS/wallpaper-16x9.png"
    [ -f "$IMG" ] || IMG="$DATOS/wallpaper.png"
fi

falla() { echo "fbterm-fondo: $*" >&2; exit 1; }

# Guardas anti-bucle y de entorno: solo TTY fisica, sin X11/Wayland, una vez.
[ -z "${FBTERM_FONDO_ACTIVO:-}" ] || falla "ya estas dentro de FbTerm."
[ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] || falla "hay sesion grafica; esto es solo para TTY."
TTY_ACTUAL="$(tty 2>/dev/null || true)"
case "$TTY_ACTUAL" in
    /dev/tty[0-9]*) : ;;
    *) falla "no es una TTY fisica ($TTY_ACTUAL). Entra en tty1-tty6 y reintenta." ;;
esac

command -v fbterm >/dev/null 2>&1 || falla "falta fbterm: sudo apt-get install --no-install-recommends fbterm"

abrir_fbterm() {
    export FBTERM_FONDO_ACTIVO=1
    if [ "$1" -eq 1 ]; then
        unset FBTERM_BACKGROUND_IMAGE
    else
        export FBTERM_BACKGROUND_IMAGE=1
    fi
    exec fbterm -- /bin/bash -l
}

if [ "$SIN_FONDO" -eq 1 ]; then
    abrir_fbterm 1
fi

# Desde aqui hace falta pintar la imagen en el framebuffer.
if [ ! -f "$IMG" ] || [ ! -x "$IDUMP" ] \
   || [ ! -e "$FBDEV" ] || [ ! -r "$FBDEV" ] || [ ! -w "$FBDEV" ]; then
    echo "fbterm-fondo: no se puede pintar el fondo (imagen, visor o" >&2
    echo "permiso sobre $FBDEV). Abro FbTerm sin fondo." >&2
    echo "Pista: el acceso a /dev/fb0 requiere el grupo video." >&2
    sleep 2
    abrir_fbterm 1
fi

# idump pinta y sale sin limpiar la pantalla; FbTerm captura ese
# framebuffer como fondo porque FBTERM_BACKGROUND_IMAGE esta definida.
export FRAMEBUFFER="$FBDEV"
printf '\033[?25l'
"$IDUMP" -f "$IMG" >/dev/null 2>&1 || {
    printf '\033[?25h'
    echo "fbterm-fondo: idump no pudo pintar; abro sin fondo." >&2
    sleep 2
    abrir_fbterm 1
}
printf '\033[?25h'
abrir_fbterm 0
EOF_LANZADOR
chmod 0755 "$DEST_BIN"
echo "Lanzador creado: $DEST_BIN"

# --- Configuracion de FbTerm (solo si no existe) -------------------------------
if [ ! -f "$HOME/.fbtermrc" ]; then
    cat > "$HOME/.fbtermrc" <<EOF_FBRC
# Configuracion de FbTerm (ver "man fbterm", seccion de opciones).
font-names=mono
font-size=$TAMANO_FUENTE
color-foreground=7
color-background=0
history-lines=5000
text-encodings=
EOF_FBRC
    echo "Creado $HOME/.fbtermrc (fuente mono de $TAMANO_FUENTE px)"
else
    echo "$HOME/.fbtermrc ya existe: no se modifico."
fi

# --- Bloque de arranque en el perfil de login ----------------------------------
# Al iniciar sesion en una TTY fisica, el perfil llama al lanzador. Dentro
# de FbTerm la variable FBTERM_FONDO_ACTIVO ya existe: el mismo perfil no
# vuelve a lanzar nada (sin bucles) y solo corre fastfetch una unica vez.
# Al salir de FbTerm (Ctrl+Alt+E) se cierra tambien la sesion.
if [ ! -f "$PERFIL" ]; then
    printf '# ~/.bash_profile\n[ -f ~/.profile ] && . ~/.profile\n' > "$PERFIL"
fi
quitar_bloque_perfil >/dev/null
cat >> "$PERFIL" <<'EOF_PERFIL'
# >>> fbterm-fondo (TTY) >>>
# Fondo con FbTerm + fastfetch solo en TTY fisicas, sin X11/Wayland.
# Desactivar sin desinstalar: touch ~/.config/fbterm-fondo/desactivado
if [ -z "${FBTERM_FONDO_ACTIVO:-}" ]; then
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] \
       && [ ! -f "$HOME/.config/fbterm-fondo/desactivado" ]; then
        case "$(tty 2>/dev/null)" in
            /dev/tty[0-9]*)
                if "$HOME/.local/bin/fbterm-fondo"; then
                    exit
                fi
                echo "fbterm-fondo no pudo arrancar; sigues en la TTY normal." >&2
                ;;
        esac
    fi
elif [ -z "${FBTERM_FASTFETCH_OK:-}" ]; then
    export FBTERM_FASTFETCH_OK=1
    [ "${TERM:-}" = "linux" ] && export TERM=fbterm
    command -v fastfetch >/dev/null 2>&1 && fastfetch
fi
# <<< fbterm-fondo (TTY) <<<
EOF_PERFIL
echo "Arranque automatico agregado a $PERFIL"

cat <<'EOF'

Listo. Como probarlo:
  1) Cierra sesion y vuelve a entrar en una TTY (tty1-tty6), o ejecuta
     directamente en la TTY:  ~/.local/bin/fbterm-fondo
  2) Veras tu imagen de fondo y fastfetch una sola vez dentro de FbTerm.
  3) Para salir de FbTerm: Ctrl+Alt+E (eso cierra tambien la sesion).

Notas:
  - Modo de imagen en ~/.config/fbterm-fondo/config: FBTERM_MODO=cover
    (16:9 a pantalla completa) o =fit (original completa y centrada).
  - Sin fbi ni ImageMagick: el unico visor es ~/.local/bin/idump
    (estatico, sin dependencias). Su fuente viaja en la carpeta.
  - Desinstalar:  ./instalar-fbterm-fondo.sh --desinstalar
EOF
