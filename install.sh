#!/usr/bin/env bash
# Instalador interactivo de Debian 13.7 "trixie" Stable en el unico disco de la VM.
#
# Escenario real para el que esta escrito:
#   - Subes ESTE archivo a GitHub.
#   - Arrancas debian-live-13.7.0-amd64-standard.iso en tu VM.
#   - Dentro del live descargas el script con curl/wget y lo ejecutas.
#   - La VM tiene UN UNICO disco: /dev/sda. No hay segundo disco, no hay
#     carpetas compartidas, no hay imagenes auxiliares, no hay anfitrion
#     involucrado en la instalacion.
#
# Todo el trabajo temporal (log, estado, respaldos, tarballs, Zig, cachés,
# claves GPG) vive en /tmp, que en trixie es tmpfs en RAM. Por eso:
#   * NO queda nada del instalador dentro del sistema instalado.
#   * TODO se pierde al apagar/reiniciar la VM.
#   * --resume solo funciona MIENTRAS la sesion del live siga viva.
#
# No promete "fallo cero": hardware, firmware, red y memoria pueden fallar.
# Ofrece --explain, --validate, --dry-run, --simulate, --config, --resume,
# --refresh-limine, preflight, respaldos en RAM, traps y confirmaciones.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="$(basename "$0")"

DRY_RUN=0
SIMULATE=0
ACCEPT_DEFAULTS=0
RESUME=0
REFRESH_LIMINE=0
VALIDATE_ONLY=0
EXPLAIN_ONLY=0
LOG_GIVEN=0
INPUT_CONFIG=""

# Directorios en RAM. STATE_DIR y ARTIFACT_DIR se conservan hasta apagar;
# SCRATCH_DIR se borra en cleanup para no dejar toolchain ni claves.
BASE_DIR="/tmp/debian-live-install"
STATE_DIR="$BASE_DIR/state"
ARTIFACT_DIR="$BASE_DIR/artifacts"
SCRATCH_DIR="$BASE_DIR/scratch"
LOG_FILE="$ARTIFACT_DIR/install.log"
STATE_FILE="$STATE_DIR/stage"
CONFIG_FILE="$STATE_DIR/config"
SCRATCH_DIR_REAL=""
LAST_STAGE=0
MOUNTS=()
HELP_FN=""
HELP_SHOWN=""

# ---------------------------- utilidades base ----------------------------

log() {
    local msg="$*" dir
    printf '%s\n' "$msg"
    dir="$(dirname "$LOG_FILE")"
    if [[ -d "$dir" && -w "$dir" ]]; then
        printf '%s %s\n' "$(date -Is)" "$msg" >> "$LOG_FILE"
    fi
}

cmd_to_text() {
    local out="" a
    for a in "$@"; do
        printf -v out '%s %q' "$out" "$a"
    done
    printf '%s' "${out# }"
}

run() {
    log "+ $(cmd_to_text "$@")"
    if (( DRY_RUN )); then
        return 0
    fi
    "$@"
}

run_in_dir() {
    local dir="$1"
    shift
    log "+ (cd $(cmd_to_text "$dir") && $(cmd_to_text "$@"))"
    if (( DRY_RUN )); then
        return 0
    fi
    ( cd "$dir" && "$@" )
}

die() {
    log "ERROR: $*"
    exit 1
}

fail() {
    local line="$1" orden="$2"
    log "FALLO en línea $line: $orden"
    cleanup
    exit 1
}

cleanup() {
    trap - EXIT ERR
    if (( ! DRY_RUN && ! SIMULATE )); then
        if [[ -n "${M:-}" && "$M" != "/" ]] && findmnt "$M" >/dev/null 2>&1; then
            umount -R "$M" 2>/dev/null || true
        fi
        if [[ -e /dev/mapper/cryptroot ]]; then
            cryptsetup close cryptroot 2>/dev/null || true
        fi
    fi
    # Solo se borra el scratch. El estado y los respaldos sobreviven en RAM
    # para permitir --resume dentro de la misma sesion del live.
    if [[ -n "$SCRATCH_DIR_REAL" && -d "$SCRATCH_DIR_REAL" ]]; then
        rm -rf -- "$SCRATCH_DIR_REAL" 2>/dev/null || true
    fi
    sync 2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "$LINENO" "$BASH_COMMAND"' ERR

mount_track() {
    local mp="$1"
    shift
    run mount "$@" "$mp"
    MOUNTS+=("$mp")
}

require_cmd() {
    if (( SIMULATE || DRY_RUN )); then
        return 0
    fi
    command -v "$1" >/dev/null 2>&1 || die "Falta el comando: $1"
}

require_root() {
    if (( SIMULATE || DRY_RUN )); then
        return 0
    fi
    [[ $EUID -eq 0 ]] || die "Ejecuta como root: sudo -i"
}

capture() {
    local var="$1" out
    shift
    if (( DRY_RUN || SIMULATE )); then
        printf -v "$var" '%s' "SIMULADO-$var"
    else
        out="$("$@")"
        printf -v "$var" '%s' "$out"
    fi
}

truncate_file() {
    local file="$1"
    run sh -c ': > "$1"' sh "$file"
}

write_line() {
    local file="$1" line="$2"
    log "escribir $file: $line"
    run sh -c 'printf "%s\n" "$1" >> "$2"' sh "$line" "$file"
}

write_lines() {
    local file="$1" line
    shift
    truncate_file "$file"
    for line in "$@"; do
        write_line "$file" "$line"
    done
}

verify_sha() {
    local expected="$1" file="$2"
    log "+ sha256sum -c - para $file (esperado $expected)"
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

derive_paths() {
    local d
    d="$(dirname "$LOG_FILE")"
    STATE_DIR="$d/../state"
    ARTIFACT_DIR="$d"
    SCRATCH_DIR="$d/../scratch"
    STATE_FILE="$STATE_DIR/stage"
    CONFIG_FILE="$STATE_DIR/config"
}

init_dirs() {
    if (( DRY_RUN || SIMULATE )); then
        SCRATCH_DIR_REAL="/tmp/debian-live-install-simulado"
        return 0
    fi
    mkdir -p "$STATE_DIR" "$ARTIFACT_DIR"
    chmod 700 "$STATE_DIR" "$ARTIFACT_DIR"
    SCRATCH_DIR_REAL="$(mktemp -d "$SCRATCH_DIR.XXXXXX")"
    chmod 700 "$SCRATCH_DIR_REAL"
}

save_config() {
    local k v tmp
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    mkdir -p "$STATE_DIR"
    tmp="$CONFIG_FILE.tmp"
    : > "$tmp"
    for k in "${CONFIG_KEYS[@]}"; do
        v="$(printf '%s' "${!k}" | base64 -w0)"
        printf '%s=%s\n' "$k" "$v" >> "$tmp"
    done
    mv -f "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

load_config_from() {
    local file="$1" line k v decoded allowed kk
    [[ -r "$file" ]] || die "No se puede leer la configuración: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        k="${line%%=*}"
        v="${line#*=}"
        allowed=0
        for kk in "${CONFIG_KEYS[@]}"; do
            if [[ "$kk" == "$k" ]]; then
                allowed=1
                break
            fi
        done
        (( allowed )) || die "Clave de configuración no permitida: $k"
        decoded="$(printf '%s' "$v" | base64 -d)"
        printf -v "$k" '%s' "$decoded"
    done < "$file"
    parse_extra_packages
    log "Configuración cargada: $file (sin contraseñas)"
}

mark_stage() {
    LAST_STAGE="$1"
    if (( DRY_RUN || SIMULATE )); then
        return 0
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$LAST_STAGE" > "$STATE_FILE" || die "No se puede guardar el estado en $STATE_FILE"
    save_config
    log "Etapa $LAST_STAGE completada"
}

stage_done() {
    local n="$1"
    (( RESUME && n <= LAST_STAGE ))
}

read_state() {
    if [[ -r "$STATE_FILE" ]]; then
        local v
        v="$(tail -n 1 "$STATE_FILE" | tr -cd '0-9')"
        if [[ -n "$v" ]]; then
            LAST_STAGE="$v"
        fi
    fi
}

parse_extra_packages() {
    EXTRA_PACKAGES=()
    local p oldifs
    oldifs="$IFS"
    IFS=' '
    for p in $EXTRA_PACKAGES_STR; do
        [[ "$p" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "Paquete adicional inválido: $p"
        EXTRA_PACKAGES+=("$p")
    done
    IFS="$oldifs"
}

# ---------------------------- explicaciones ----------------------------
# Cada bloque se muestra ANTES de la pregunta correspondiente.
# Tambien puedes verlos todos sin ejecutar nada con: bash install.sh --explain
# Pulsa ? en cualquier prompt para volver a leer el bloque.

show_help() {
    [[ -n "$HELP_FN" ]] || return 0
    if [[ "$HELP_SHOWN" != "$HELP_FN" ]]; then
        printf '\n'
        "$HELP_FN"
        printf '\n'
        HELP_SHOWN="$HELP_FN"
    fi
}

help_all() {
    local f
    for f in \
        help_intro help_target help_workdir help_identity help_locale \
        help_mirror help_components help_firmware help_microcode \
        help_partitions help_luks help_rootfs help_hardening \
        help_plymouth help_limine help_greeter help_gui help_zram \
        help_pipewire help_network help_security help_bootmodes \
        help_dns help_extras help_cleanup help_confirm; do
        printf '\n'
        "$f"
    done
}

# shellcheck disable=SC2016
help_intro() {
    cat <<'EOF'
=== ANTES DE EMPEZAR: que va a pasar y que NO va a pasar ===

Vas a instalar Debian 13.7 "trixie" Stable SIN el instalador tradicional,
usando debootstrap desde este live. El unico disco de la VM es /dev/sda y
sera COMPLETAMENTE BORRADO: se destruye su tabla de particiones, se crea
GPT de cero, se formatea una ESP FAT32 y se crea un contenedor LUKS cifrado.

Que NO existe en este diseno:
  - No hay segundo disco, imagen auxiliar ni carpeta compartida.
  - No se lee ni se escribe nada en el anfitrion.
  - No se genera ningun archivo para el anfitrion.
  - El script no se copia a si mismo dentro del sistema instalado.

Donde vive todo durante la instalacion:
  /tmp de Debian 13 es tmpfs (RAM). Ahi estan el log, el estado, los
  respaldos, los tarballs, Zig, las cachés y las claves GPG temporales.
  Consecuencias honestas:
    + Cero rastros del instalador en el sistema final.
    - Si apagas o reinicias la VM, se pierde TODO, incluido el estado.
    - --resume solo sirve mientras esta misma sesion del live siga viva.
    - Compilar Ly con Zig necesita ~1 GB libres en RAM; si tu VM tiene
      poca memoria, elige greetd en vez de ly.

Fuente: https://www.debian.org/releases/stable/release-notes/issues.en.html#the-temporary-files-directory-tmp-is-now-stored-in-a-tmpfs
Fuente: https://www.debian.org/releases/
EOF
}

# shellcheck disable=SC2016
help_target() {
    cat <<'EOF'
=== Disco destino y punto de montaje ===

El destino esta FIJADO a /dev/sda. No se acepta otro valor, porque la VM
tiene un solo disco y cualquier sustitucion generica podria apuntar al
lugar equivocado. Antes de tocar nada se verifican modelo, serie, tamano
aproximado de 59 GB, HOTPLUG=1, TRAN=usb y que no haya particiones montadas.

Punto de montaje temporal: /mnt/target. Es solo un directorio del live
donde se monta la raiz cifrada mientras se construye el sistema. No
forma parte del sistema final; se desmonta al terminar.

Si el preflight falla aqui, NO continues: significa que /dev/sda no es
el USB que esperabas o que esta en uso.

Recomendado: deja /dev/sda y /mnt/target tal cual.
EOF
}

# shellcheck disable=SC2016
help_workdir() {
    cat <<'EOF'
=== Estado, respaldos y duracion de los datos ===

El script usa tres directorios dentro de /tmp (RAM):

  state/      etapa actual y preferencias NO secretas para --resume.
  artifacts/  log, primeros 16 MiB del disco, tabla GPT anterior,
              cabecera LUKS, UUIDs, limine.conf, crypttab, fstab y GPT final.
  scratch/    tarballs, Zig, cachés de compilacion, claves GPG y archivos
              de contrasena temporales. Se BORRA al salir del script.

Pregunta: que hacer con state/ y artifacts/ al terminar.

  conservar (recomendado): siguen en RAM hasta que apagues la VM. Asi
      puedes usar --resume si algo falla, y puedes leer el log con less.
      Se pierden igual al apagar; no queda nada en el disco instalado.
  borrar: se eliminan al salir. Mas limpio, pero --resume dejara de
      funcionar y perderas la cabecera LUKS de respaldo.
  sin respaldos: no se guardan ni GPT ni cabecera LUKS. Mas rapido,
      pero si el disco se corrompe no hay recuperacion.

AVISO: la cabecera LUKS es la unica copia de seguridad del cifrado. Si
quieres conservarla de verdad, copiala ANTES de apagar la VM a otro
servidor con curl/scp. El script no te impone donde.

Recomendado: "conservar". Es gratis y no deja rastros.
Fuente: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksHeaderBackup.8.en.html
EOF
}

# shellcheck disable=SC2016
help_identity() {
    cat <<'EOF'
=== Hostname, usuario y contrasenas ===

Hostname: nombre corto, minusculas, sin espacios. Es el nombre de la
maquina en la red; no afecta al cifrado ni al arranque.

Usuario: se crea con home en /home y se mete en los grupos sudo, audio
y video. No se crea ningun otro usuario interactivo.

Shell: bash es el mas compatible; zsh anade un paquete; dash es minimo
y poco comodo como shell interactiva.

Contrasenas (usuario, root y frase LUKS):
  - Se piden DOS veces y no se muestran.
  - Se exigen 12+ caracteres ASCII imprimibles, sin acentos, sin espacios,
    sin ':' y sin saltos de linea.
  - Motivo: la frase LUKS la escribe el initramfs ANTES de cargar el
    teclado completo. Si usas acentos, eñes o simbolos que cambian entre
    el mapa latam y us, podras escribirla en el live pero NO al arrancar,
    y el sistema parecera "no aceptar la contrasena". Es la causa mas
    comun de bloqueo en instalaciones cifradas.
  - La frase LUKS NO se guarda en el state ni en el log. Si reinicias,
    tendras que volver a escribirla para --resume o --refresh-limine.

Recomendado: frase LUKS larga pero ASCII (p. ej. 4 palabras sin tildes
separadas por guiones), distinta de la contrasena del usuario.
Fuente: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksFormat.8.en.html
EOF
}

# shellcheck disable=SC2016
help_locale() {
    cat <<'EOF'
=== Locale, zona horaria y teclado ===

Locale: en_US.UTF-8 mantiene los mensajes del sistema en ingles y UTF-8,
que es lo mas predecible para diagnosticar errores de arranque. C.UTF-8
es aun mas minimo (sin mensajes traducidos ni formato regional).
es_AR.UTF-8 traduce mensajes, pero los logs de error aparecen en español
y a veces es mas dificil buscarlos en documentacion oficial.

Zona horaria: solo afecta a la hora mostrada y a los logs. La hora del
hardware se trata como local; en una USB que se mueve entre PCs, UTC es
la opcion mas neutra. America/Argentina/Buenos_Aires es la correcta si
siempre usaras la USB en Argentina.

Teclado: latam es el mapa con eñe y acentos en consola y X11. Tambien se
copia al initramfs con KEYMAP=y para que la frase LUKS se escriba igual.
Ojo: sigue siendo recomendable que la frase sea ASCII, porque el cambio
de mapa dentro del initramfs no es identico al de una sesion completa.

Recomendado: en_US.UTF-8 + tu zona + latam, con frase LUKS ASCII.
Fuente: https://manpages.debian.org/trixie/locales/locale.gen.5.en.html
Fuente: https://manpages.debian.org/trixie/keyboard-configuration/keyboard.5.en.html
EOF
}

# shellcheck disable=SC2016
help_mirror() {
    cat <<'EOF'
=== Mirror de Debian y mirror de seguridad ===

Se verifica que el mirror sirva dists/trixie/Release con Codename: trixie
y que el mirror de seguridad sirva trixie-security. No se mezcla con
testing, sid, backports ni otras ramas.

Opciones comprobadas en la investigacion previa:
  mirror.sitsa.com.ar       Argentina. Sirve trixie 13.7.
  debian.c3sl.ufpr.br       Brasil. Sirve trixie y tambien trixie-security.
  deb.debian.org            Redirige al mirror mas cercano. Generico.

Si eliges el de Brasil, el script usa automaticamente su ruta
debian-security; si eliges Argentina o deb.debian.org, usa
security.debian.org. Puedes corregir la URL de seguridad a mano.

Por que importa: debootstrap y apt verifican firmas OpenPGP de Release.
Un mirror desactualizado o que no sirva seguridad rompe la instalacion
o deja el sistema sin parches.

Recomendado: el de Argentina; el de Brasil como respaldo.
Fuente: https://www.debian.org/mirror/list-full
Fuente: https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html
EOF
}

# shellcheck disable=SC2016
help_components() {
    cat <<'EOF'
=== Componentes APT ===

main                Solo software libre, sin firmware propietario.
contrib             Software libre que depende de algo no libre.
non-free-firmware   Firmware propietario necesario para muchas Wi-Fi,
                    GPUs y tarjetas de red. En trixie es un componente
                    separado, NO parte de non-free.
non-free            Software propietario en general. NO se usa aqui.

El perfil de firmware que elijas mas abajo reescribe este valor:
  completo / minimo -> main,contrib,non-free-firmware
  ninguno           -> main

NO se anade non-free: no hace falta para arrancar y evita bloat. Si mas
adelante necesitas un driver propietario, puedes editar
/etc/apt/sources.list.d/debian.sources en el sistema ya instalado.

Recomendado: deja que el perfil de firmware decida; no escribas a mano.
Fuente: https://www.debian.org/releases/stable/release-notes/index.en.html
Fuente: https://manpages.debian.org/trixie/apt/sources.list.5.en.html
EOF
}

# shellcheck disable=SC2016
help_firmware() {
    cat <<'EOF'
=== Perfil de firmware (compatibilidad multi-PC) ===

 completo : instala firmware-linux-free, firmware-amd-graphics,
            firmware-intel-graphics, firmware-nvidia-graphics,
            firmware-misc-nonfree, firmware-realtek, firmware-iwlwifi,
            firmware-atheros, firmware-brcm80211, firmware-mediatek.
            Maximiza la probabilidad de que la USB arranque con red y
            graficos en PCs distintas. Coste: ~200-300 MB mas.
 minimo   : firmware-linux-free, firmware-realtek, firmware-iwlwifi,
            firmware-misc-nonfree. Cubre lo mas comun (Ethernet/Wi-Fi).
 ninguno  : solo main. Sistema mas pequeno, pero una Wi-Fi Intel/Realtek
            o una GPU que requiera firmware puede no funcionar hasta que
            instales el paquete a mano con cable.

Ten en cuenta que esto NO garantiza compatibilidad universal: algunos
dispositivos necesitan microcodigo, modulos del kernel o controladores
que no estan en Debian. Es una cobertura razonable, no una promesa.

Recomendado: "completo" en una USB portable que se movera entre PCs.
Fuente: https://packages.debian.org/trixie/firmware-misc-nonfree
Fuente: https://wiki.debian.org/Firmware
EOF
}

# shellcheck disable=SC2016
help_microcode() {
    cat <<'EOF'
=== Microcodigo de CPU ===

 intel-microcode : actualiza microcodigo de procesadores Intel.
 amd64-microcode : actualiza microcodigo de procesadores AMD.
 ambos           : instala los dos. Son pocos KB y cada uno solo actua
                   si detecta su CPU. Es la opcion mas portable.
 ninguno         : no se instala. El kernel usara el microcodigo que ya
                   traiga la BIOS/UEFI de cada PC.

El microcodigo se carga muy al principio del arranque y corrige erratas
de CPU y algunas mitigaciones. No sustituye a actualizar el firmware de
la placa, pero es barato y mejora estabilidad.

Recomendado: "ambos" para una USB que se usa en varias maquinas.
Fuente: https://packages.debian.org/trixie/intel-microcode
Fuente: https://packages.debian.org/trixie/amd64-microcode
EOF
}

# shellcheck disable=SC2016
help_partitions() {
    cat <<'EOF'
=== Tamano de ESP, BIOS Boot y etiquetas ===

GPT resultante:
  p1  ef02  BIOS Boot     1-8 MiB   -> para Limine en BIOS/legacy.
  p2  ef00  ESP FAT32     512M/1G/2G -> montada en /boot SIN cifrar.
  p3  8309  LUKS          resto     -> raiz cifrada ext4/btrfs dentro.

Por que /boot va SIN cifrar: Limine no lee LUKS, LVM ni ext4 para
encontrar vmlinuz e initrd.img. El kernel, el initramfs y limine.conf
deben estar en una particion que el firmware y Limine puedan leer antes
de pedir la frase. El initramfs es quien abre cryptroot despues.

Tamano de ESP: las notas de trixie piden AL MENOS 768 MB en /boot con
unos 300 MB libres, porque kernel+firmware crecieron mucho. 512M puede
quedar justo si eliges firmware completo y varios kernels. 1G es el
equilibrio; 2G es holgado y cuesta ~1 GB menos de raiz.

BIOS Boot: 2M basta para el stage de Limine en GPT. 8M es margen extra.

Etiquetas: FAT32 admite maximo 11 caracteres; se validan. La etiqueta
LUKS es informativa (udev), no afecta a crypttab, que usa UUID.

Recomendado: ESP 1G, BIOS Boot 2M, etiquetas por defecto.
Fuente: https://www.debian.org/releases/stable/release-notes/issues.en.html#ensure-boot-has-enough-free-space
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/FAQ.md
Fuente: https://manpages.debian.org/trixie/dosfstools/mkfs.fat.8.en.html
EOF
}

# shellcheck disable=SC2016
help_luks() {
    cat <<'EOF'
=== LUKS2: KDF y memoria Argon2id ===

argon2id (recomendado): KDF moderno, resistente a GPUs/ASIC. Consume
memoria y CPU al abrir el disco. Opciones de memoria:
  65536 KiB  = 64 MiB   -> abre rapido en cualquier PC, incluidas VMs
                           con 2 GB de RAM. RECOMENDADO para USB portable.
  131072 KiB = 128 MiB  -> mas resistencia, apertura algo mas lenta.
  262144 KiB = 256 MiB  -> puede tardar y fallar en equipos con poca RAM.
  524288 KiB = 512 MiB  -> NO recomendado en una USB que se movera entre
                           PCs: cryptsetup puede reducirlo, pero el
                           benchmark y el consumo al desbloquear son altos.

pbkdf2: KDF antiguo, solo tiempo/iteraciones, sin coste de memoria. Es
mas compatible con equipos muy viejos y con initramfs minimos, pero es
mucho mas debil frente a fuerza bruta con GPU. Eligelo solo si tuviste
problemas reales con argon2id.

El script usa --type luks2, --label, --key-file - (la frase se pasa por
stdin desde un archivo temporal en scratch/ con umask 077) y hace un
luksHeaderBackup en RAM. crypttab luego usa UUID, no /dev/sda3, para que
el orden de discos no rompa el arranque.

Recomendado: argon2id con 65536 KiB.
Fuente: https://manpages.debian.org/trixie/cryptsetup-bin/cryptsetup-luksFormat.8.en.html
Fuente: https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html
EOF
}

# shellcheck disable=SC2016
help_rootfs() {
    cat <<'EOF'
=== Sistema de archivos de la raiz cifrada ===

ext4 : maduro, predecible, arranque y recuperacion muy documentados.
       Menos memoria, menos sorpresas con initramfs. RECOMENDADO.
btrfs: compresion zstd:1, snapshots y checksums. Anade btrfs-progs al
       initramfs y al sistema. En una USB puede ser util, pero si el
       initramfs no incluye bien el modulo o hay cortes de energia, la
       recuperacion es mas delicada. No uses snapshots sin saber como
       se comportan con LUKS.

Ambos van DENTRO de /dev/mapper/cryptroot, nunca en la ESP. fstab usa
UUID del filesystem interior, y crypttab usa UUID de la particion LUKS.

No hay swap fija en disco: se usa ZRAM (mas abajo). Eso evita escribir
paginas de memoria sin cifrar y alarga la vida del pendrive.

Recomendado: ext4.
Fuente: https://manpages.debian.org/trixie/e2fsprogs/mkfs.ext4.8.en.html
Fuente: https://manpages.debian.org/trixie/cryptsetup/crypttab.5.en.html
EOF
}

# shellcheck disable=SC2016
help_hardening() {
    cat <<'EOF'
=== Parametros de endurecimiento del kernel ===

conservador (RECOMENDADO):
  slab_nomerge, init_on_alloc=1, init_on_free=1,
  page_alloc.shuffle=1, randomize_kstack_offset=1, pti=on, debugfs=off.
  Mitigaciones conocidas, bajo riesgo de romper programas.

agresivo:
  lo anterior + vsyscall=none + mitigations=auto,nosmt.
  vsyscall=none puede ROMPER binarios antiguos o glibc viejo.
  auto,nosmt puede DESACTIVAR SMT/HyperThreading y perder rendimiento.
  Solo si sabes que ningun programa necesita vsyscalls.

ninguno:
  sin parametros extra. Maxima compatibilidad, minima proteccion.

Estos valores se escriben en cmdline de limine.conf, no en sysctl, para
que apliquen desde el primer arranque. No son un "kernel endurecido":
Debian NO tiene linux-hardened; se usa linux-image-amd64 oficial mas
estas opciones. Es la alternativa mas cercana y honesta.

Recomendado: conservador. Si algo no arranca, usa la entrada de texto
del menu de Limine y edita cmdline.
Fuente: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
Fuente: https://packages.debian.org/trixie/linux-image-amd64
EOF
}

# shellcheck disable=SC2016
help_plymouth() {
    cat <<'EOF'
=== Plymouth: animacion de arranque ===

Plymouth muestra un tema grafico mientras el initramfs pide la frase
LUKS. Requiere `splash` en cmdline; sin el, muestra texto detallado.
Temas verificados en trixie: spinfinity, spinner, text, details.
"ninguno" instala Plymouth pero NO pone splash en la entrada principal.

spinfinity : animacion clasica de Debian. RECOMENDADO.
spinner    : mas simple.
text       : barra de texto, util si KMS falla.
details    : mensajes detallados con el tema cargado.

Riesgo real: en algunas GPUs o bajo QEMU, Plymouth puede dejar la
pantalla negra justo cuando hay que escribir la frase LUKS. Por eso el
script crea SIEMPRE una segunda entrada "texto" sin splash y una tercera
de rescate. Si la pantalla se queda negra, reinicia y elige "texto".

La entrada alternativa usa plymouth.enable=0, verificado en el script
init-premount/plymouth del paquete plymouth_24.004.60-5 de trixie.

Recomendado: spinfinity + entrada de texto SI.
Fuente: https://manpages.debian.org/trixie/plymouth/plymouth.8.en.html
Fuente: https://packages.debian.org/trixie/plymouth
EOF
}

# shellcheck disable=SC2016
help_limine() {
    cat <<'EOF'
=== Limine: bootloader upstream ===

Limine NO es paquete Debian; se baja v12.9.6 desde GitHub, se verifica
SHA-256 y (por defecto) la firma GPG con clave
05D29860D0A0668AAEFB9D691F3C021BECA23821 en un homedir temporal. Luego se
compila la herramienta `limine` y se instalan:
  UEFI x64 -> /boot/EFI/BOOT/BOOTX64.EFI
  BIOS     -> /boot/limine-bios.sys + limine bios-install /dev/sda 1
  IA32     -> BOOTIA32.EFI (opcional, solo equipos UEFI de 32 bits)

limine.conf usa opciones documentadas: timeout, default_entry,
editor_enabled, interface_branding, term_palette/term_background/
term_foreground, protocol: linux, path: boot():/vmlinuz-ABI, cmdline y
module_path: boot():/initrd.img-ABI. Las rutas son VERSIONADAS: por eso
existe --refresh-limine para cuando el kernel se actualice.

editor_enabled=yes te permite editar cmdline en el menu (util para
recuperarte). Si lo desactivas, ganas un poco de "endurecimiento" pero
pierdes esa salida rapida. Secure Boot debe estar APAGADO: esta
configuracion no esta inscrita ni firmada para Secure Boot.

Recomendado: verificar GPG SI, editor SI, UEFI x64 SI, BIOS SI, IA32 NO.
Fuente: https://github.com/Limine-Bootloader/Limine/releases/tag/v12.9.6
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/CONFIG.md
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md
EOF
}

# shellcheck disable=SC2016
help_greeter() {
    cat <<'EOF'
=== Gestor de inicio de sesion (greeter) ===

ly (original):
  TUI ncurses del proyecto fairyglade, v1.5.0 desde Codeberg. NO esta en
  Debian. Se compila con Zig 0.17.0 FUERA del target y se instala con
  `zig build installexe -Ddest_directory=...`. Validado de verdad:
  compile + ly --validate-config. Coste: descarga ~55 MB de Zig, ~165 KB
  de Ly, dependencias Git de Zig y ~1 GB libres en /tmp (RAM). Tarda unos
  minutos. Si la VM tiene 2 GB de RAM o menos, puede fallar con
  NoSpaceLeft. Requiere red durante la compilacion.

greetd + tuigreet (ALTERNATIVA EMPAQUETADA, mas robusta):
  greetd 0.10.3-4 y tuigreet 0.9.1-5 son paquetes de trixie. Cero
  toolchain, cero descargas extra, cero riesgo de RAM. Hace lo mismo
  conceptualmente: TUI en una VT que inicia la sesion X11. Config.toml
  con vt=7 y usuario _greetd (que crea el paquete).

consola:
  Sin gestor grafico: login en TTY y `startx` manual. Minimo absoluto.
  Solo valido si tambien elegiste GUI=no.

Discrepancia documental detectada: el README del tag v1.5.0 dice Zig
0.16.x, pero build.zig.zon exige 0.17.0. La combinacion que REALMENTE
compila es v1.5.0 + Zig 0.17.0, y es la que usa este script.

Recomendado: greetd para el PRIMER arranque (arranca si o si). Elige ly
si quieres el original y aceptas el build upstream. Si tu VM tiene poca
RAM, el script te avisara y te preguntara antes de seguir.
Fuente: https://codeberg.org/fairyglade/ly/raw/tag/v1.5.0/readme.md
Fuente: https://codeberg.org/fairyglade/ly/raw/tag/v1.5.0/build.zig.zon
Fuente: https://ziglang.org/download/index.json
Fuente: https://packages.debian.org/trixie/greetd
Fuente: https://manpages.debian.org/trixie/greetd/greetd.5.en.html
EOF
}

# shellcheck disable=SC2016
help_gui() {
    cat <<'EOF'
=== Entorno grafico X11 ligero ===

Si GUI=si se instala Xorg minimo (xserver-xorg-core, drivers de entrada
y video, libgl1-mesa-dri, xauth, xinit) mas, segun elijas:
  WM         openbox (tema Nightmare incluido en el paquete) o ninguno.
  Compositor picom (transparencias/sombras) o ninguno.
  Barra      tint2 o ninguno.
  Lanzador   rofi (drun con Win+r) o ninguno.
  Terminal   xterm, alacritty o ambas.
  Fuente     JetBrains Mono, DejaVu Sans Mono o Terminus.
  Colores    fondo/texto/acento en RRGGBB para .Xresources, Openbox y
             la propia interfaz de Limine.

Es estetica "hacker" VISUAL y funcional: colores, monoespaciada, atajos.
NO se instalan herramientas de intrusion, escaneo ni exploiting. No hay
escritorio pesado (GNOME/KDE/XFCE), ni servicios de telemetria.

Si GUI=no, no tiene sentido un greeter grafico: el script te obligara a
elegir "consola" mas arriba. Aun asi tendras Plymouth, ZRAM, red y TTY.

Coste aproximado: 150-250 MB y ~40 paquetes mas. En una USB de 59 GB
es irrelevante; en RAM de la VM si importa durante la instalacion.

Recomendado: GUI=si con Openbox + picom + tint2 + rofi + xterm.
Para depurar un arranque fallido, GUI=no es mas facil.
Fuente: https://packages.debian.org/trixie/openbox
Fuente: https://packages.debian.org/trixie/tuigreet
EOF
}

# shellcheck disable=SC2016
help_zram() {
    cat <<'EOF'
=== ZRAM en vez de swap fija ===

systemd-zram-generator crea /dev/zram0 como swap COMPRIMIDA en RAM.
Configuracion: zram-size = min(ram / 2, LIMITE) y swap-priority = 100,
para que el kernel la prefiera antes que cualquier otro swap.

Ventajas en una USB cifrada:
  - No se escribe swap sin cifrar en el pendrive.
  - Menos desgaste del flash.
  - No hace falta particion de swap ni resume/hibernacion (RESUME=none).

Limites: 1024/2048/4096 MiB son TOPES de dispositivo zram, no RAM
reservada de golpe. El limite no debe superar la RAM de la PC mas pequena
donde vayas a usar la USB. Si eliges 4096 y arrancas en un equipo con
2 GB, el generador ajusta con ram/2, pero mejor no tentar.

Si ZRAM=no, el sistema queda SIN swap. Es valido si tienes mucha RAM,
pero bajo presion de memoria el OOM killer actuara antes.

Recomendado: ZRAM=si con 2048 MiB.
Fuente: https://manpages.debian.org/trixie/systemd-zram-generator/zram-generator.conf.5.en.html
EOF
}

# shellcheck disable=SC2016
help_pipewire() {
    cat <<'EOF'
=== Audio: PipeWire ===

minimal: pipewire, pipewire-pulse, pipewire-alsa, wireplumber.
         Cubre salida/entrada y compatibilidad con apps que hablan
         PulseAudio o ALSA. RECOMENDADO.
bluetooth: lo anterior + libspa-0.2-bluetooth, bluez y pulseaudio-utils.
         Anade soporte Bluetooth y ~30 MB. Solo si usaras auriculares BT.
ninguno: sin servidor de audio. Ahorra ~15 MB y un servicio. Los
         programas que esperen PulseAudio simplemente no tendran sonido.

WirePlumber es el administrador de sesiones; sin el, PipeWire arranca
pero no gestiona dispositivos correctamente.

Recomendado: minimal. Anade bluetooth despues con apt si lo necesitas.
Fuente: https://wiki.debian.org/PipeWire
Fuente: https://packages.debian.org/trixie/pipewire
EOF
}

# shellcheck disable=SC2016
help_network() {
    cat <<'EOF'
=== Red ===

NetworkManager: gestiona Ethernet y Wi-Fi, trae nmtui para configurar
    desde TTY, y es lo mas comodo en una USB que cambia de PC. Anade
    network-manager, wpasupplicant e iw. RECOMENDADO para portable.
dhcpcd-base:   solo DHCP por cable/inalambrico basico, sin applet ni
    nmtui. Menos servicios y menos paquetes. Ya viene en el live, pero
    se instala explicitamente en el target.
ninguno:       sin gestor; tendras que configurar /etc/network/interfaces
    o ip a mano. Maximo minimalismo, mayor riesgo de quedarte sin red
    despues del primer arranque.

Importante: durante la INSTALACION la red la usa el live, no el target.
Este choice afecta al sistema ya instalado. El preflight comprueba la red
del live antes de empezar.

Recomendado: NetworkManager. Si quieres pocos servicios, dhcpcd-base.
Fuente: https://packages.debian.org/trixie/network-manager
Fuente: https://packages.debian.org/trixie/dhcpcd-base
EOF
}

# shellcheck disable=SC2016
help_security() {
    cat <<'EOF'
=== Firewall, AppArmor y servicios opcionales ===

nftables (SI por defecto): reglas inet filter con policy drop en input
    y forward, lo aceptado, established/related, ICMP/ICMPv6 y DHCP/DHCPv6.
    La sintaxis se valida con `nft -c -f` DENTRO del chroot antes de
    habilitar el servicio. Ojo: NO abre ningun puerto entrante; si luego
    instalas SSH y quieres acceder desde otra PC, tendras que anadir una
    regla. Es intencional: primero arranca, despues expones.
AppArmor (SI): perfiles Mandatory Access Control. En Debian viene activo
    desde Buster; se habilita el servicio. Coste minimo.
doas (NO): alternativa minima a sudo. Se instala ademas de sudo, con
    `permit persist :sudo`. No sustituye nada; es comodidad.
auditd (NO): daemon de auditoria. Util en servidores, genera muchos logs
    y escribe constantemente: mala idea en un pendrive.
openssh-server (NO): servidor SSH. Si lo activas, recuerda que nftables
    NO abre el puerto 22 por defecto. Activalo solo si sabes que quieres
    administrar la USB remotamente.

Recomendado: nftables SI, AppArmor SI, doas/auditd/ssh NO.
Fuente: https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_headers
Fuente: https://wiki.debian.org/AppArmor/HowToUse
Fuente: https://manpages.debian.org/trixie/opendoas/doas.conf.5.en.html
EOF
}

# shellcheck disable=SC2016
help_bootmodes() {
    cat <<'EOF'
=== Modos de arranque y Secure Boot ===

UEFI x64 (SI): instala BOOTX64.EFI en /boot/EFI/BOOT/. Es el modo de
    casi todas las PCs modernas y de OVMF en QEMU.
BIOS/legacy (SI): crea particion BIOS Boot ef02 y ejecuta
    `limine bios-install /dev/sda 1`. Permite arrancar en equipos viejos
    o en QEMU con -machine pc. Cuesta 2 MiB.
UEFI IA32 (NO): BOOTIA32.EFI para las pocas tablets/Atom con UEFI de 32
    bits y CPU de 64. Activalo solo si sabes que tu equipo lo necesita.
Secure Boot (debe estar NO): esta instalacion NO esta firmada para
    Secure Boot. Si el firmware lo tiene activo, Limine no arrancara.
    El script se NIEGA a continuar si respondes que esta activo: apagalo
    en la configuracion de la VM/BIOS antes de seguir.

Tener UEFI + BIOS a la vez NO es incompatible: son dos rutas distintas
sobre el mismo GPT. Es justo lo que hace portable la USB.

Recomendado: UEFI SI, BIOS SI, IA32 NO, Secure Boot NO.
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md
Fuente: https://github.com/Limine-Bootloader/Limine/blob/trunk/FAQ.md
EOF
}

# shellcheck disable=SC2016
help_dns() {
    cat <<'EOF'
=== DNS del sistema instalado ===

Se escribe /etc/resolv.conf con dos nameserver. Durante la instalacion
se usa el resolv.conf del live; al final se reemplaza por estos valores
en el target.

1.1.1.1 / 8.8.8.8 son publicos y funcionan en casi cualquier red.
Si tu red usa un resolutor local (router, Pi-hole, VPN), pon aqui su IP.
Si elegiste NetworkManager, el tambien puede reescribir resolv.conf al
conectarse; no es un error.

Usa solo IP literales, no nombres de host: en el primer arranque aun no
hay garantia de resolver nombres antes de que la red este arriba.

Recomendado: deja los valores por defecto salvo que tengas un DNS propio.
EOF
}

# shellcheck disable=SC2016
help_extras() {
    cat <<'EOF'
=== Paquetes adicionales y limpieza ===

Paquetes adicionales: nombres APT separados por espacios, p. ej.
  vim neofetch tmux git
Se validan con una expresion regular: letras minusculas, numeros y los
signos mas, punto y guion. Se anaden a la SIMULACION y a la instalacion.
Si escribes un
nombre inexistente, `apt-get -s install` fallara ANTES de instalar nada,
asi que no romperas el disco. Deja vacio para no anadir nada.

Limpieza de rastros (SI): al final se borran del target
  /debootstrap, bootstrap.log, debootstrap.log, /root/.bash_history,
  *.deb en apt/archives, listas APT y contenido de /tmp.
Quedan SOLO configuraciones normales de Debian. El script, el log, el
estado, los tarballs, Zig, las cachés y las claves GPG nunca se copian
al target: estan en /tmp (RAM) y scratch/ se borra al salir.

Si pones limpieza=NO, conservaras el directorio /debootstrap dentro del
sistema instalado. Solo tiene sentido para depurar el bootstrap.

Recomendado: limpieza SI, paquetes extra vacio en el primer intento.
EOF
}

# shellcheck disable=SC2016
help_cleanup() {
    cat <<'EOF'
=== Confirmacion final antes de destruir /dev/sda ===

El siguiente paso ejecuta `sgdisk --zap-all /dev/sda`, crea particiones,
mkfs.fat, cryptsetup luksFormat y mkfs dentro de LUKS. Es IRREVERSIBLE.

Antes de escribir la confirmacion el script ya habra:
  - verificado root, trixie, red, mirrors y herramientas;
  - mostrado modelo, serie, tamano, TRAN y HOTPLUG de /dev/sda;
  - comprobado que no haya particiones montadas;
  - guardado (si elegiste conservar) los primeros 16 MiB, el volcado de
    particiones y la tabla GPT anterior en RAM.

Debes escribir EXACTAMENTE:  BORRAR /dev/sda

Si dudas, cancela con Ctrl+C. No hay marcha atras y, como todo esta en
RAM, al apagar la VM tampoco quedara copia de los respaldos.

Recomendado: relee `lsblk` que imprime el preflight antes de confirmar.
EOF
}

# shellcheck disable=SC2016
help_confirm() {
    help_cleanup
}

# ---------------------------- preguntas ----------------------------

ask() {
    local var="$1" prompt="$2" default="$3" ans="" allow_empty=0
    [[ -n "$default" ]] || allow_empty=1
    if (( ACCEPT_DEFAULTS )); then
        printf -v "$var" '%s' "$default"
        log "$prompt = $default (por defecto)"
        return 0
    fi
    while true; do
        show_help
        IFS= read -r -p "$prompt [$default] (? repite ayuda): " ans || die "Entrada cancelada"
        if [[ "$ans" == "?" ]]; then
            HELP_SHOWN=""
            continue
        fi
        ans="${ans:-$default}"
        if (( ! allow_empty )) && [[ -z "$ans" ]]; then
            printf 'No vacío.\n'
            continue
        fi
        printf -v "$var" '%s' "$ans"
        HELP_FN=""
        HELP_SHOWN=""
        return 0
    done
}

ask_yes() {
    local var="$1" prompt="$2" default="$3" ans=""
    if (( ACCEPT_DEFAULTS )); then
        printf -v "$var" '%s' "$default"
        log "$prompt = $default (por defecto)"
        return 0
    fi
    while true; do
        show_help
        IFS= read -r -p "$prompt [s/n, por defecto $default, ? ayuda]: " ans || die "Entrada cancelada"
        if [[ "$ans" == "?" ]]; then
            HELP_SHOWN=""
            continue
        fi
        ans="${ans:-$default}"
        case "$ans" in
            s|S|si|SI|y|Y|yes) printf -v "$var" '%s' "si" ;;
            n|N|no|NO) printf -v "$var" '%s' "no" ;;
            *) printf 'Responde s o n.\n'; continue ;;
        esac
        HELP_FN=""
        HELP_SHOWN=""
        return 0
    done
}

menu() {
    local var="$1" prompt="$2" default_num="$3" ans="" i
    shift 3
    local opts=("$@")
    if (( ACCEPT_DEFAULTS )); then
        printf -v "$var" '%s' "${opts[default_num-1]}"
        log "$prompt = ${opts[default_num-1]} (por defecto)"
        return 0
    fi
    while true; do
        show_help
        printf '%s\n' "$prompt"
        for i in "${!opts[@]}"; do
            printf '  %d) %s\n' "$((i+1))" "${opts[i]}"
        done
        IFS= read -r -p "Elige 1-${#opts[@]} [${default_num}], ? repite ayuda: " ans || die "Entrada cancelada"
        if [[ "$ans" == "?" ]]; then
            HELP_SHOWN=""
            continue
        fi
        ans="${ans:-$default_num}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            printf -v "$var" '%s' "${opts[ans-1]}"
            HELP_FN=""
            HELP_SHOWN=""
            return 0
        fi
        printf 'Opción inválida.\n'
    done
}

check_secret() {
    local s="$1"
    [[ "$s" != *:* ]] || die "La contraseña no puede contener ':' por chpasswd"
    if ! printf '%s' "$s" | LC_ALL=C grep -qE '^[[:print:]]{12,}$'; then
        die "Usa al menos 12 caracteres ASCII imprimibles, sin espacios ni acentos"
    fi
}

ask_secret() {
    local var="$1" prompt="$2" a="" b=""
    if (( ACCEPT_DEFAULTS && DRY_RUN )); then
        printf -v "$var" '%s' 'Cambiar-Esta-Frase-2026!'
        log "$prompt = (valor por defecto de simulación, oculto)"
        return 0
    fi
    while true; do
        show_help
        IFS= read -r -s -p "$prompt (? muestra ayuda primero): " a || die "Entrada cancelada"
        printf '\n'
        if [[ "$a" == "?" ]]; then
            HELP_SHOWN=""
            continue
        fi
        IFS= read -r -s -p "Repite $prompt: " b || die "Entrada cancelada"
        printf '\n'
        check_secret "$a"
        [[ "$a" == "$b" ]] || { printf 'No coincide.\n'; continue; }
        printf -v "$var" '%s' "$a"
        HELP_FN=""
        HELP_SHOWN=""
        return 0
    done
}

ask_hex() {
    local var="$1" prompt="$2" default="$3" v=""
    ask v "$prompt (RRGGBB o #RRGGBB)" "$default"
    v="${v#\#}"
    [[ "$v" =~ ^[0-9A-Fa-f]{6}$ ]] || die "Color hexadecimal inválido: $v"
    printf -v "$var" '%s' "$v"
}

ask_label() {
    local var="$1" prompt="$2" default="$3" max="$4" v=""
    ask v "$prompt" "$default"
    [[ ${#v} -le "$max" ]] || die "Etiqueta demasiado larga (máx $max)"
    [[ "$v" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Etiqueta con caracteres no permitidos"
    printf -v "$var" '%s' "$v"
}

ask_num() {
    local var="$1" prompt="$2" default="$3" min="$4" max="$5" v=""
    ask v "$prompt" "$default"
    [[ "$v" =~ ^[0-9]+$ ]] || die "Debe ser número"
    (( v >= min && v <= max )) || die "Fuera de rango $min-$max"
    printf -v "$var" '%s' "$v"
}

validate_regex() {
    local var="$1" label="$2" re="$3"
    [[ "${!var}" =~ $re ]] || die "$label inválido: ${!var}"
}

confirm_wipe() {
    local ans=""
    if (( DRY_RUN || SIMULATE )); then
        log "Confirmación de borrado omitida en simulación"
        return 0
    fi
    HELP_FN=help_confirm
    HELP_SHOWN=""
    show_help
    printf '\n=== PELIGRO ===\nSe borrará por completo %s.\n' "$U"
    lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN,HOTPLUG "$U"
    IFS= read -r -p "Escribe exactamente BORRAR $U para continuar: " ans || die "Cancelado"
    [[ "$ans" == "BORRAR $U" ]] || die "No se confirmó el borrado"
    HELP_FN=""
    HELP_SHOWN=""
}

# ---------------------------- defaults ----------------------------

set_defaults() {
    U=/dev/sda
    B=/dev/sda2
    R=/dev/sda3
    M=/mnt/target
    SUITE=trixie
    ARCH=amd64
    HOSTNAME_DEB=mini
    USERNAME=user
    USER_SHELL=/bin/bash
    USER_PASS=""
    ROOT_PASS=""
    LUKS_PASS=""
    LOCALE=en_US.UTF-8
    TZ_AREA=America/Argentina/Buenos_Aires
    KEYMAP=latam
    MIRROR=https://mirror.sitsa.com.ar/debian
    SECURITY=https://security.debian.org/debian-security
    COMPONENTS=main,contrib,non-free-firmware
    ESP_SIZE=1G
    BIOS_SIZE=2M
    BOOT_LABEL=BOOTESP
    ROOT_LABEL=ROOTFS
    LUKS_LABEL=CRYPTROOT
    PBKDF=argon2id
    PBKDF_MEM=65536
    ROOT_FS=ext4
    KERNEL_HARDENING=conservador
    PLYMOUTH_THEME=spinfinity
    PLYMOUTH_FALLBACK=si
    LIMINE_EDITOR=si
    VERIFY_GPG=si
    GREETER=greetd
    GUI=si
    WM=openbox
    COMPOSITOR=picom
    BAR=tint2
    LAUNCHER=rofi
    TERMINAL=xterm
    FONT="JetBrains Mono"
    FONT_PKG=fonts-jetbrains-mono
    BG=0b0f14
    FG=00ff9c
    ACCENT=55ffc8
    ZRAM=si
    ZRAM_SIZE=2048
    PIPEWIRE=minimal
    NETWORK=NetworkManager
    FIREWALL=si
    APPARMOR=si
    DOAS=no
    AUDITD=no
    SSH=no
    FIRMWARE=completo
    MICROCODE=ambos
    UEFI=si
    BIOS_BOOT=si
    UEFI_IA32=no
    SECURE_BOOT=no
    DNS1=1.1.1.1
    DNS2=8.8.8.8
    DATA_POLICY=conservar
    MAKE_HOST_BACKUP=si
    CLEAN_TRACES=si
    EXTRA_PACKAGES_STR=""
    EXTRA_PACKAGES=()
    PKGS=()
    K=""
    LUKS_UUID=""
    ROOT_UUID=""
    BOOT_UUID=""
    LIMINE_VER=12.9.6
    LIMINE_KEY=05D29860D0A0668AAEFB9D691F3C021BECA23821
    LIMINE_SHA=939f670e0831cc940453fd3a0ddfb2b324c0b4e3c5d0e741c190aa0d13df0103
    LY_VER=1.5.0
    ZIG_VER=0.17.0
    ZIG_SHA=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
    LY_SHA=115a7f7fb281803ca7f9e0ddbdf76834a53f7fa6bc702d766d03772ce1976dc3
}

CONFIG_KEYS=(
    U B R M SUITE ARCH HOSTNAME_DEB USERNAME USER_SHELL LOCALE TZ_AREA KEYMAP
    MIRROR SECURITY COMPONENTS ESP_SIZE BIOS_SIZE BOOT_LABEL ROOT_LABEL LUKS_LABEL
    PBKDF PBKDF_MEM ROOT_FS KERNEL_HARDENING PLYMOUTH_THEME PLYMOUTH_FALLBACK
    LIMINE_EDITOR VERIFY_GPG GREETER GUI WM COMPOSITOR BAR LAUNCHER TERMINAL
    FONT FONT_PKG BG FG ACCENT ZRAM ZRAM_SIZE PIPEWIRE NETWORK FIREWALL APPARMOR
    DOAS AUDITD SSH FIRMWARE MICROCODE UEFI BIOS_BOOT UEFI_IA32 SECURE_BOOT
    DNS1 DNS2 DATA_POLICY MAKE_HOST_BACKUP CLEAN_TRACES
    EXTRA_PACKAGES_STR K LUKS_UUID ROOT_UUID BOOT_UUID
    LIMINE_VER LIMINE_KEY LIMINE_SHA LY_VER ZIG_VER ZIG_SHA LY_SHA
)

collect_preferences() {
    log "=== Recogiendo preferencias (escribe ? para releer la explicación) ==="
    HELP_FN=help_intro;      HELP_SHOWN=""; ask_yes DUMMY_INTRO "¿Entiendes que /dev/sda se borrará y que todo temporal vive en RAM?" "si"
    HELP_FN=help_target;     HELP_SHOWN=""
    ask U "Dispositivo destino (debe ser /dev/sda)" "$U"
    [[ "$U" == /dev/sda ]] || die "Este instalador está fijado a /dev/sda; salida por seguridad"
    B="${U}2"
    R="${U}3"
    ask M "Punto de montaje temporal del sistema" "$M"
    [[ "$M" = /* && "$M" != "/" ]] || die "Punto de montaje inválido: $M"

    HELP_FN=help_workdir;    HELP_SHOWN=""
    menu DATA_POLICY "¿Qué hago con estado y respaldos en RAM?" 1 "conservar" "borrar" "sin respaldos"
    case "$DATA_POLICY" in
        conservar) MAKE_HOST_BACKUP=si ;;
        borrar)    MAKE_HOST_BACKUP=si ;;
        "sin respaldos") MAKE_HOST_BACKUP=no ;;
    esac
    if (( ! LOG_GIVEN )); then
        ask LOG_FILE "Ruta del log" "$ARTIFACT_DIR/install.log"
    fi
    derive_paths

    HELP_FN=help_identity;   HELP_SHOWN=""
    ask HOSTNAME_DEB "Nombre de host" "$HOSTNAME_DEB"
    validate_regex HOSTNAME_DEB "hostname" '^[a-z][a-z0-9-]{0,62}$'
    ask USERNAME "Usuario" "$USERNAME"
    validate_regex USERNAME "usuario" '^[a-z_][a-z0-9_-]{0,31}$'
    menu USER_SHELL "Shell del usuario" 1 "/bin/bash" "/bin/zsh" "/bin/dash"
    ask_secret USER_PASS "Contraseña del usuario"
    ask_secret ROOT_PASS "Contraseña de root"
    ask_secret LUKS_PASS "Frase LUKS (ASCII, sin acentos)"

    HELP_FN=help_locale;     HELP_SHOWN=""
    menu LOCALE "Locale" 1 "en_US.UTF-8" "C.UTF-8" "es_AR.UTF-8"
    menu TZ_AREA "Zona horaria" 1 "America/Argentina/Buenos_Aires" "UTC" "Etc/UTC"
    menu KEYMAP "Teclado" 1 "latam" "es" "us"

    HELP_FN=help_mirror;     HELP_SHOWN=""
    menu MIRROR "Mirror Debian" 1 \
        "https://mirror.sitsa.com.ar/debian" \
        "https://debian.c3sl.ufpr.br/debian" \
        "https://deb.debian.org/debian"
    case "$MIRROR" in
        *c3sl*) SECURITY="https://debian.c3sl.ufpr.br/debian-security" ;;
        *) SECURITY="https://security.debian.org/debian-security" ;;
    esac
    ask SECURITY "Mirror de seguridad" "$SECURITY"
    [[ "$SECURITY" == https://* ]] || die "El mirror de seguridad debe usar HTTPS"

    HELP_FN=help_components; HELP_SHOWN=""
    ask COMPONENTS "Componentes APT (separados por comas)" "$COMPONENTS"
    validate_regex COMPONENTS "componentes" '^[a-z0-9,+-]+$'

    HELP_FN=help_firmware;   HELP_SHOWN=""
    menu FIRMWARE "Perfil de firmware" 1 "completo" "minimo" "ninguno"
    case "$FIRMWARE" in
        completo|minimo) COMPONENTS="main,contrib,non-free-firmware" ;;
        ninguno) COMPONENTS="main" ;;
    esac
    HELP_FN=help_microcode;  HELP_SHOWN=""
    menu MICROCODE "Microcódigo" 1 "ambos" "intel" "amd" "ninguno"

    HELP_FN=help_partitions; HELP_SHOWN=""
    menu ESP_SIZE "Tamaño de ESP" 2 "512M" "1G" "2G"
    menu BIOS_SIZE "Tamaño BIOS Boot" 2 "1M" "2M" "8M"
    ask_label BOOT_LABEL "Etiqueta FAT32" "$BOOT_LABEL" 11
    ask_label ROOT_LABEL "Etiqueta raíz" "$ROOT_LABEL" 16
    ask_label LUKS_LABEL "Etiqueta LUKS" "$LUKS_LABEL" 32

    HELP_FN=help_luks;       HELP_SHOWN=""
    menu PBKDF "KDF de LUKS" 1 "argon2id" "pbkdf2"
    if [[ "$PBKDF" == argon2id ]]; then
        menu PBKDF_MEM "Memoria Argon2id (KiB)" 1 "65536" "131072" "262144" "524288"
    fi
    HELP_FN=help_rootfs;     HELP_SHOWN=""
    menu ROOT_FS "Sistema de archivos raíz" 1 "ext4" "btrfs"

    HELP_FN=help_hardening;  HELP_SHOWN=""
    menu KERNEL_HARDENING "Endurecimiento del kernel" 1 "conservador" "agresivo" "ninguno"
    HELP_FN=help_plymouth;   HELP_SHOWN=""
    menu PLYMOUTH_THEME "Tema Plymouth" 1 "spinfinity" "spinner" "text" "details" "ninguno"
    ask_yes PLYMOUTH_FALLBACK "Incluir entrada de arranque sin Plymouth" "si"

    HELP_FN=help_limine;     HELP_SHOWN=""
    ask_yes LIMINE_EDITOR "Permitir editor de Limine" "si"
    ask_yes VERIFY_GPG "Verificar firma GPG de Limine" "si"

    HELP_FN=help_greeter;    HELP_SHOWN=""
    menu GREETER "Gestor de inicio de sesión" 1 "greetd" "ly" "consola"
    HELP_FN=help_gui;        HELP_SHOWN=""
    ask_yes GUI "Instalar entorno gráfico X11" "si"
    if [[ "$GUI" == "no" && "$GREETER" != "consola" ]]; then
        die "Un greeter gráfico requiere X11; elige consola o activa GUI"
    fi
    if [[ "$GUI" == si ]]; then
        menu WM "WM" 1 "openbox" "ninguno"
        menu COMPOSITOR "Compositor" 1 "picom" "ninguno"
        menu BAR "Barra" 1 "tint2" "ninguno"
        menu LAUNCHER "Lanzador" 1 "rofi" "ninguno"
        menu TERMINAL "Terminal" 1 "xterm" "alacritty" "ambas"
        menu FONT_PKG "Fuente monoespaciada" 1 "fonts-jetbrains-mono" "fonts-dejavu-core" "xfonts-terminus"
        case "$FONT_PKG" in
            fonts-jetbrains-mono) FONT="JetBrains Mono" ;;
            fonts-dejavu-core) FONT="DejaVu Sans Mono" ;;
            xfonts-terminus) FONT="Terminus" ;;
        esac
        ask_hex BG "Color de fondo" "$BG"
        ask_hex FG "Color de texto" "$FG"
        ask_hex ACCENT "Color de acento" "$ACCENT"
    fi

    HELP_FN=help_zram;       HELP_SHOWN=""
    ask_yes ZRAM "Usar ZRAM" "si"
    if [[ "$ZRAM" == si ]]; then
        menu ZRAM_SIZE "Tamaño máximo ZRAM (MiB)" 1 "2048" "4096" "1024"
    fi
    HELP_FN=help_pipewire;   HELP_SHOWN=""
    menu PIPEWIRE "PipeWire" 1 "minimal" "bluetooth" "ninguno"
    HELP_FN=help_network;    HELP_SHOWN=""
    menu NETWORK "Red" 1 "NetworkManager" "dhcpcd" "ninguno"

    HELP_FN=help_security;   HELP_SHOWN=""
    ask_yes FIREWALL "Activar nftables" "si"
    ask_yes APPARMOR "Instalar AppArmor" "si"
    ask_yes DOAS "Instalar doas además de sudo" "no"
    ask_yes AUDITD "Instalar auditd" "no"
    ask_yes SSH "Instalar openssh-server" "no"

    HELP_FN=help_bootmodes;  HELP_SHOWN=""
    menu UEFI "Arranque UEFI x64" 1 "si" "no"
    menu BIOS_BOOT "Arranque BIOS/Legacy" 1 "si" "no"
    menu UEFI_IA32 "Copiar BOOTIA32.EFI" 1 "no" "si"
    menu SECURE_BOOT "Secure Boot activo en el firmware" 1 "no" "si"
    [[ "$SECURE_BOOT" == "no" ]] || die "Secure Boot debe estar desactivado para esta USB portable"

    HELP_FN=help_dns;        HELP_SHOWN=""
    ask DNS1 "DNS primario" "$DNS1"
    ask DNS2 "DNS secundario" "$DNS2"

    HELP_FN=help_extras;     HELP_SHOWN=""
    ask EXTRA_PACKAGES_STR "Paquetes adicionales separados por espacios (vacío = ninguno)" "$EXTRA_PACKAGES_STR"
    parse_extra_packages
    ask_yes CLEAN_TRACES "Limpiar rastros del instalador en el sistema instalado" "si"

    confirm_wipe
    HELP_FN=""
    HELP_SHOWN=""
}

# ---------------------------- validacion y entorno ----------------------------

self_check() {
    log "=== Autocomprobación estática ==="
    # shellcheck disable=SC2016
    # Los literales con $MIRROR/$SUITE se buscan tal cual dentro de este archivo.
    local checks=(
        '^set -Eeuo pipefail$'
        'trap cleanup EXIT'
        "trap 'fail"
        'confirm_wipe'
        'curl -fsI "$MIRROR/dists/$SUITE/Release"'
        'cryptsetup luksHeaderBackup'
        'sha256sum -c -'
        'gpg --verify'
        'update-initramfs -u -k all'
        'sfdisk --dump'
        'install_host_deps'
        'check_tmp_space'
        'save_config'
        'load_config_from'
        'ly --validate-config'
        'help_all'
        '--explain'
        'run_in_dir'
        'ARTIFACT_DIR'
        'SCRATCH_DIR'
        'STATE_DIR'
    )
    # shellcheck disable=SC2016
    # Las cadenas con $MIRROR/$SUITE son literales buscados dentro del propio script.
    local c
    for c in "${checks[@]}"; do
        grep -qF "$c" "$0" || die "Falta comprobación de diseño: $c"
    done
    local banned1="REEM""PLAZAR" banned2="/mnt/""backup" banned3="linux""-hardened"
    local banned4="usb""-host" banned5="ev""al" banned6="deb""usb"
    local banned7="media/""respaldo" banned8="WIN""DOWS" banned9="back""up.img"
    local banned10="Get""-Disk" banned11="fat:""ro:" banned12="%""U%"
    grep -q "$banned1" "$0" && die "Quedan marcadores prohibidos"
    grep -q "$banned2" "$0" && die "Queda ruta de respaldo anterior"
    grep -q "$banned3" "$0" && die "Kernel inexistente en Debian detectado"
    grep -q "$banned4" "$0" && die "Dispositivo anfitrión prohibido"
    grep -qE "(^|[[:space:]])$banned5([[:space:]]|$)" "$0" && die "Construcción dinámica prohibida"
    grep -qi "$banned6" "$0" && die "Queda el nombre de proyecto anterior"
    grep -q "$banned7" "$0" && die "Queda punto de montaje de respaldo anterior"
    grep -q "$banned8" "$0" && die "Queda referencia al anfitrión"
    grep -q "$banned9" "$0" && die "Queda imagen auxiliar anterior"
    grep -q "$banned10" "$0" && die "Queda identificacion de disco del anfitrion"
    grep -q "$banned11" "$0" && die "Queda carpeta compartida anterior"
    grep -q "$banned12" "$0" && die "Queda variable del anfitrion"
    grep -q 'run sgdisk --zap-all' "$0" || die "Falta trazabilidad de sgdisk"
    grep -q 'run cryptsetup luksFormat' "$0" || die "Falta trazabilidad de luksFormat"
    grep -q 'run mkfs.fat' "$0" || die "Falta trazabilidad de mkfs.fat"
    grep -q 'CLEAN_TRACES' "$0" || die "Falta limpieza de rastros"
    log "Autocomprobación estática OK"
    return 0
}

install_host_deps() {
    log "=== Instalando herramientas en el live (no en el sistema destino) ==="
    local deps=(
        debootstrap debian-archive-keyring gdisk dosfstools cryptsetup-bin parted
        gnupg curl wget ca-certificates git build-essential pkg-config
        xz-utils zstd coreutils util-linux mount base64
    )
    [[ "$ROOT_FS" == btrfs ]] && deps+=(btrfs-progs)
    if [[ "$GREETER" == ly ]]; then
        deps+=(libpam0g-dev libxcb-xkb-dev libxcb1-dev libaudit-dev)
    fi
    if (( DRY_RUN || SIMULATE )); then
        run env DEBIAN_FRONTEND=noninteractive apt-get update
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deps[@]}"
        return 0
    fi
    require_root
    run env DEBIAN_FRONTEND=noninteractive apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deps[@]}"
}

check_tmp_space() {
    log "=== Espacio disponible en /tmp (tmpfs en RAM) ==="
    if (( DRY_RUN || SIMULATE )); then
        log "Comprobación de RAM omitida en simulación"
        return 0
    fi
    local avail
    avail="$(df -B1 --output=avail /tmp | tail -n 1 | tr -d ' ')"
    log "Disponible en /tmp: $avail bytes"
    if [[ "$GREETER" == ly ]] && (( avail < 1200000000 )); then
        printf '\nADVERTENCIA: elegiste ly, que compila con Zig y necesita ~1 GB libres.\n'
        printf 'Solo hay ~%s MB. Puede fallar con NoSpaceLeft.\n' "$((avail/1000000))"
        printf 'Recomendacion: cambia a greetd (paquete Debian, sin toolchain).\n\n'
        local ans
        IFS= read -r -p "¿Cambiar a greetd ahora? [s/n, por defecto s]: " ans || true
        ans="${ans:-s}"
        case "$ans" in
            s|S|si|SI) GREETER=greetd; log "Cambiado a greetd por falta de RAM" ;;
            *) log "Se mantiene ly bajo responsabilidad del usuario" ;;
        esac
    fi
}

preflight() {
    log "=== Preflight ==="
    if (( SIMULATE || DRY_RUN )); then
        log "Preflight de dispositivo omitido en simulación"
        install_host_deps
        check_tmp_space
        return 0
    fi
    require_root
    grep -q '^VERSION_CODENAME=trixie$' /etc/os-release || die "El live no es Debian 13 trixie"
    curl -fsI "$MIRROR/dists/$SUITE/Release" >/dev/null || die "Mirror no accesible"
    curl -fsSL "$MIRROR/dists/$SUITE/Release" | grep -q '^Codename: trixie' || die "El mirror no es trixie"
    curl -fsI "$SECURITY/dists/trixie-security/Release" >/dev/null || die "Security no accesible"
    curl -fsI "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VER}/limine-binary.tar.xz" >/dev/null || die "Release de Limine no accesible"
    if [[ "$GREETER" == ly ]]; then
        curl -fsI "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz" >/dev/null || die "Zig no accesible"
        curl -fsI "https://codeberg.org/fairyglade/ly/archive/v${LY_VER}.tar.gz" >/dev/null || die "Ly no accesible"
    fi
    install_host_deps
    check_tmp_space

    local c
    for c in bash lsblk blkid udevadm sgdisk partprobe mkfs.fat cryptsetup mkfs.ext4 debootstrap chroot curl wget sha256sum base64 tar make gpg git pkg-config apt-get mount umount findmnt systemctl df; do
        require_cmd "$c"
    done
    [[ "$ROOT_FS" == btrfs ]] && require_cmd mkfs.btrfs
    [[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] || die "Falta debian-archive-keyring"

    test -b "$U" || die "$U no es dispositivo de bloque"
    lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN,HOTPLUG "$U"
    udevadm info --query=property --name="$U" | grep -E '^(ID_BUS|ID_MODEL|ID_SERIAL|ID_PATH)='
    [[ "$(lsblk -dn -o HOTPLUG "$U")" == "1" ]] || die "$U no parece extraíble"
    [[ "$(lsblk -dn -o TRAN "$U")" == "usb" ]] || die "$U no parece USB"
    local size
    size="$(lsblk -dn -o SIZE -b "$U")"
    (( size >= 58000000000 && size <= 61000000000 )) || die "Tamaño inesperado: $size bytes"
    if lsblk -rno MOUNTPOINTS "$U" | grep -qv '^$'; then
        die "Hay particiones montadas en $U; desmóntalas antes"
    fi
    log "Preflight OK"
}

ensure_target_dirs() {
    run mkdir -p \
        "$M/etc/apt/sources.list.d" \
        "$M/etc/initramfs-tools/conf.d" \
        "$M/etc/X11/xorg.conf.d" \
        "$M/etc/systemd" \
        "$M/etc/greetd" \
        "$M/boot/EFI/BOOT" \
        "$M/dev" "$M/proc" "$M/sys" "$M/run"
}

ensure_chroot_mounts() {
    if (( DRY_RUN || SIMULATE )); then
        run mount --bind /dev "$M/dev"
        run mount -t devpts devpts "$M/dev/pts"
        run mount -t proc proc "$M/proc"
        run mount -t sysfs sys "$M/sys"
        run mount -t tmpfs tmpfs "$M/run"
        run chmod 1777 "$M/run"
        run cp --dereference /etc/resolv.conf "$M/etc/resolv.conf"
        return 0
    fi
    ensure_target_dirs
    if ! findmnt "$M/dev" >/dev/null; then mount_track "$M/dev" --bind /dev; fi
    run mkdir -p "$M/dev/pts"
    if ! findmnt "$M/dev/pts" >/dev/null; then mount_track "$M/dev/pts" -t devpts devpts; fi
    if ! findmnt "$M/proc" >/dev/null; then mount_track "$M/proc" -t proc proc; fi
    if ! findmnt "$M/sys" >/dev/null; then mount_track "$M/sys" -t sysfs sys; fi
    if ! findmnt "$M/run" >/dev/null; then mount_track "$M/run" -t tmpfs tmpfs; fi
    run chmod 1777 "$M/run"
    if [[ ! -s "$M/etc/resolv.conf" ]]; then
        run cp --dereference /etc/resolv.conf "$M/etc/resolv.conf"
    fi
}

ensure_target_mount() {
    if (( DRY_RUN || SIMULATE )); then
        run cryptsetup open --key-file - "$R" cryptroot
        run mount /dev/mapper/cryptroot "$M"
        run mount "$B" "$M/boot"
        return 0
    fi
    if ! findmnt "$M" >/dev/null; then
        HELP_FN=help_identity; HELP_SHOWN=""
        ask_secret LUKS_PASS "Frase LUKS para abrir $R"
        local pf="$SCRATCH_DIR_REAL/luks.pass"
        luks_pass_file "$pf"
        cryptsetup open --key-file - "$R" cryptroot < "$pf"
        mount_track "$M" /dev/mapper/cryptroot
    fi
    run mkdir -p "$M/boot"
    if ! findmnt "$M/boot" >/dev/null; then mount_track "$M/boot" "$B"; fi
}

ensure_resume_mounts() {
    if (( LAST_STAGE >= 15 )); then
        log "Reanudación: etapa final ya completada; no se remonta"
        return 0
    fi
    if (( LAST_STAGE >= 3 )); then ensure_target_mount; fi
    if (( LAST_STAGE >= 4 )); then ensure_chroot_mounts; fi
}

# ---------------------------- etapas ----------------------------

stage_1_prepare() {
    log "=== Etapa 1: preparación y respaldo en RAM ==="
    run mkdir -p "$M" "$ARTIFACT_DIR" "$STATE_DIR"
    if [[ "$MAKE_HOST_BACKUP" == si ]]; then
        run dd if="$U" of="$ARTIFACT_DIR/disk-first-16MiB.img" bs=1M count=16 status=progress
        if (( ! DRY_RUN && ! SIMULATE )); then
            sfdisk --dump "$U" > "$ARTIFACT_DIR/partitions-before.txt" 2>/dev/null || true
            sgdisk --backup="$ARTIFACT_DIR/gpt-before.bin" "$U" 2>/dev/null || true
            chmod 600 "$ARTIFACT_DIR"/disk-first-16MiB.img "$ARTIFACT_DIR"/partitions-before.txt "$ARTIFACT_DIR"/gpt-before.bin 2>/dev/null || true
        else
            run sfdisk --dump "$U"
            run sgdisk --backup="$ARTIFACT_DIR/gpt-before.bin" "$U"
        fi
    fi
    mark_stage 1
}

stage_2_partition() {
    log "=== Etapa 2: particionado DESTRUCTIVO ==="
    run sgdisk --zap-all "$U"
    run sgdisk -n "1:1M:+${BIOS_SIZE}" -t 1:ef02 -c 1:BIOSBOOT "$U"
    run sgdisk -n "2:0:+${ESP_SIZE}" -t 2:ef00 -c 2:ESPBOOT "$U"
    run sgdisk -n 3:0:0 -t 3:8309 -c 3:LUKSROOT "$U"
    run partprobe "$U"
    run udevadm settle
    if (( ! DRY_RUN && ! SIMULATE )); then
        test -b "$B" || die "No existe $B"
        test -b "$R" || die "No existe $R"
        sgdisk -v "$U"
    fi
    mark_stage 2
}

luks_pass_file() {
    local f="$1" old
    old="$(umask)"
    umask 077
    printf '%s' "$LUKS_PASS" > "$f"
    umask "$old"
}

stage_3_luks_mount() {
    log "=== Etapa 3: LUKS y montaje ==="
    run mkfs.fat -F32 -n "$BOOT_LABEL" "$B"
    local pf="$SCRATCH_DIR_REAL/luks.pass"
    if (( ! DRY_RUN && ! SIMULATE )); then luks_pass_file "$pf"; fi
    if [[ "$PBKDF" == argon2id ]]; then
        if (( DRY_RUN || SIMULATE )); then
            run cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf argon2id --pbkdf-memory "$PBKDF_MEM" --pbkdf-parallel 1 --iter-time 2000 --key-file - "$R"
        else
            cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf argon2id --pbkdf-memory "$PBKDF_MEM" --pbkdf-parallel 1 --iter-time 2000 --key-file - "$R" < "$pf"
        fi
    else
        if (( DRY_RUN || SIMULATE )); then
            run cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf pbkdf2 --iter-time 4000 --key-file - "$R"
        else
            cryptsetup luksFormat --type luks2 --label "$LUKS_LABEL" --pbkdf pbkdf2 --iter-time 4000 --key-file - "$R" < "$pf"
        fi
    fi
    if (( DRY_RUN || SIMULATE )); then
        run cryptsetup open --key-file - "$R" cryptroot
    else
        cryptsetup open --key-file - "$R" cryptroot < "$pf"
    fi
    if [[ "$ROOT_FS" == ext4 ]]; then
        run mkfs.ext4 -L "$ROOT_LABEL" /dev/mapper/cryptroot
    else
        run mkfs.btrfs -L "$ROOT_LABEL" /dev/mapper/cryptroot
    fi
    mount_track "$M" /dev/mapper/cryptroot
    run mkdir -p "$M/boot"
    mount_track "$M/boot" "$B"
    capture LUKS_UUID blkid -s UUID -o value "$R"
    capture ROOT_UUID blkid -s UUID -o value /dev/mapper/cryptroot
    capture BOOT_UUID blkid -s UUID -o value "$B"
    if (( ! DRY_RUN && ! SIMULATE )) && [[ "$MAKE_HOST_BACKUP" == si ]]; then
        cryptsetup luksHeaderBackup "$R" --header-backup-file "$ARTIFACT_DIR/luks-header.img"
        chmod 600 "$ARTIFACT_DIR/luks-header.img"
        printf '%s\n' "LUKS_UUID=$LUKS_UUID" "ROOT_UUID=$ROOT_UUID" "BOOT_UUID=$BOOT_UUID" > "$ARTIFACT_DIR/uuids.txt"
        chmod 600 "$ARTIFACT_DIR/uuids.txt"
    fi
    mark_stage 3
}

stage_4_debootstrap() {
    log "=== Etapa 4: debootstrap ==="
    run debootstrap --arch="$ARCH" --variant=minbase --components="$COMPONENTS" --keyring=/usr/share/keyrings/debian-archive-keyring.gpg --force-check-sig "$SUITE" "$M" "$MIRROR"
    ensure_target_dirs
    ensure_chroot_mounts
    mark_stage 4
}

stage_5_sources() {
    log "=== Etapa 5: sources deb822 ==="
    ensure_chroot_mounts
    write_lines "$M/etc/apt/sources.list.d/debian.sources" \
        "Types: deb" \
        "URIs: $MIRROR" \
        "Suites: trixie trixie-updates" \
        "Components: $COMPONENTS" \
        "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg" \
        "" \
        "Types: deb" \
        "URIs: $SECURITY" \
        "Suites: trixie-security" \
        "Components: $COMPONENTS" \
        "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
    run chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
    mark_stage 5
}

build_packages() {
    PKGS=(
        apt debian-archive-keyring ca-certificates systemd-sysv locales tzdata
        keyboard-configuration console-setup sudo coreutils util-linux
        linux-image-amd64 initramfs-tools cryptsetup cryptsetup-initramfs
        systemd-zram-generator plymouth plymouth-themes plymouth-label
        curl wget gnupg xz-utils zstd less nano htop pciutils usbutils
        x11-xkb-utils x11-xserver-utils
    )
    [[ "$USER_SHELL" == /bin/zsh ]] && PKGS+=(zsh)
    [[ "$ROOT_FS" == btrfs ]] && PKGS+=(btrfs-progs)
    case "$FIRMWARE" in
        completo) PKGS+=(firmware-linux-free firmware-amd-graphics firmware-intel-graphics firmware-nvidia-graphics firmware-misc-nonfree firmware-realtek firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-mediatek) ;;
        minimo) PKGS+=(firmware-linux-free firmware-realtek firmware-iwlwifi firmware-misc-nonfree) ;;
    esac
    case "$MICROCODE" in
        ambos) PKGS+=(intel-microcode amd64-microcode) ;;
        intel) PKGS+=(intel-microcode) ;;
        amd) PKGS+=(amd64-microcode) ;;
    esac
    case "$PIPEWIRE" in
        minimal) PKGS+=(pipewire pipewire-pulse pipewire-alsa wireplumber) ;;
        bluetooth) PKGS+=(pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth bluez pulseaudio-utils) ;;
    esac
    case "$NETWORK" in
        NetworkManager) PKGS+=(network-manager wpasupplicant iw) ;;
        dhcpcd) PKGS+=(dhcpcd-base wpasupplicant iw) ;;
    esac
    [[ "$FIREWALL" == si ]] && PKGS+=(nftables)
    [[ "$APPARMOR" == si ]] && PKGS+=(apparmor)
    [[ "$DOAS" == si ]] && PKGS+=(doas)
    [[ "$AUDITD" == si ]] && PKGS+=(auditd)
    [[ "$SSH" == si ]] && PKGS+=(openssh-server)
    [[ "$GREETER" == greetd ]] && PKGS+=(greetd tuigreet)
    [[ "$GREETER" == ly ]] && PKGS+=(libpam0g libxcb1 libxcb-xkb1 libaudit1 brightnessctl)
    if [[ "$GUI" == si ]]; then
        PKGS+=(xserver-xorg-core xserver-xorg-input-all xserver-xorg-video-all xauth xinit libgl1-mesa-dri mesa-utils "$FONT_PKG")
        [[ "$WM" == openbox ]] && PKGS+=(openbox)
        [[ "$COMPOSITOR" == picom ]] && PKGS+=(picom)
        [[ "$BAR" == tint2 ]] && PKGS+=(tint2)
        [[ "$LAUNCHER" == rofi ]] && PKGS+=(rofi)
        case "$TERMINAL" in xterm|ambas) PKGS+=(xterm) ;; esac
        case "$TERMINAL" in alacritty|ambas) PKGS+=(alacritty) ;; esac
        PKGS+=(feh xsetroot)
    fi
    PKGS+=("${EXTRA_PACKAGES[@]}")
}

stage_6_packages() {
    log "=== Etapa 6: paquetes ==="
    ensure_chroot_mounts
    ensure_target_dirs
    write_lines "$M/etc/kernel-img.conf" 'do_symlinks = No'
    write_lines "$M/etc/initramfs-tools/conf.d/zz-minimal.conf" \
        'MODULES=most' 'BUSYBOX=y' 'KEYMAP=y' 'RESUME=none' 'UMASK=0077'
    build_packages
    log "Paquetes seleccionados: ${PKGS[*]}"
    run chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -s install --no-install-recommends "${PKGS[@]}"
    run chroot "$M" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"
    run chroot "$M" apt-get clean
    # shellcheck disable=SC2016
    capture K bash -c 'basename "$(find "$1/boot" -maxdepth 1 -name "vmlinuz-*" | sort | tail -n 1)" | sed "s/^vmlinuz-//"' sh "$M"
    [[ -n "$K" ]] || die "No se pudo determinar versión del kernel"
    log "Kernel ABI: $K"
    mark_stage 6
}

set_chpasswd() {
    local user="$1" pass="$2" f="$SCRATCH_DIR_REAL/chpasswd.$$" old
    if (( DRY_RUN || SIMULATE )); then
        log "+ chpasswd para $user (oculto)"
        return 0
    fi
    old="$(umask)"
    umask 077
    printf '%s:%s\n' "$user" "$pass" > "$f"
    umask "$old"
    chroot "$M" /usr/sbin/chpasswd < "$f"
    rm -f -- "$f"
}

stage_7_system_config() {
    log "=== Etapa 7: sistema base ==="
    ensure_chroot_mounts
    write_lines "$M/etc/locale.gen" "$LOCALE UTF-8"
    run chroot "$M" /usr/sbin/locale-gen
    run chroot "$M" /usr/sbin/update-locale LANG="$LOCALE" LC_MESSAGES="$LOCALE"
    run ln -sf "/usr/share/zoneinfo/$TZ_AREA" "$M/etc/localtime"
    write_lines "$M/etc/timezone" "$TZ_AREA"
    write_lines "$M/etc/default/keyboard" \
        'XKBMODEL="pc105"' "XKBLAYOUT=\"$KEYMAP\"" 'XKBVARIANT=""' \
        'XKBOPTIONS="terminate:ctrl_alt_bksp"' 'BACKSPACE="guess"'
    write_lines "$M/etc/default/console-setup" \
        'ACTIVE_CONSOLES="/dev/tty[1-6]"' 'CHARMAP="UTF-8"' 'CODESET="guess"' \
        'FONTFACE="Terminus"' 'FONTSIZE="8x16"' 'VIDEOMODE=""'
    run chroot "$M" /usr/bin/setupcon --save-only
    ensure_target_dirs
    write_lines "$M/etc/X11/xorg.conf.d/00-keyboard.conf" \
        'Section "InputClass"' '    Identifier "system-keyboard"' \
        '    MatchIsKeyboard "on"' '    Option "XkbModel" "pc105"' \
        "    Option \"XkbLayout\" \"$KEYMAP\"" 'EndSection'
    write_lines "$M/etc/hostname" "$HOSTNAME_DEB"
    write_lines "$M/etc/hosts" \
        '127.0.0.1 localhost' "127.0.1.1 $HOSTNAME_DEB" \
        '::1 localhost ip6-localhost ip6-loopback'
    run chroot "$M" /usr/sbin/useradd -m -s "$USER_SHELL" -G sudo,audio,video "$USERNAME"
    set_chpasswd "$USERNAME" "$USER_PASS"
    set_chpasswd root "$ROOT_PASS"
    write_lines "$M/etc/resolv.conf" "nameserver $DNS1" "nameserver $DNS2"
    mark_stage 7
}

stage_8_crypt_fstab() {
    log "=== Etapa 8: crypttab/fstab/initramfs ==="
    ensure_chroot_mounts
    local root_opts="rw,noatime,errors=remount-ro"
    [[ "$ROOT_FS" == btrfs ]] && root_opts="rw,noatime,compress=zstd:1"
    write_lines "$M/etc/crypttab" "cryptroot UUID=$LUKS_UUID none luks,initramfs,tries=3"
    write_lines "$M/etc/fstab" \
        "UUID=$ROOT_UUID / $ROOT_FS $root_opts 0 1" \
        "UUID=$BOOT_UUID /boot vfat rw,noatime,nodev,nosuid,umask=0077 0 2"
    run chroot "$M" /usr/sbin/update-initramfs -u -k all
    mark_stage 8
}

kernel_cmdline() {
    local base="root=/dev/mapper/cryptroot rootfstype=$ROOT_FS ro" hard=""
    case "$KERNEL_HARDENING" in
        conservador) hard="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=1 pti=on debugfs=off" ;;
        agresivo) hard="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=1 pti=on debugfs=off vsyscall=none mitigations=auto,nosmt" ;;
        ninguno) hard="" ;;
    esac
    if [[ "$PLYMOUTH_THEME" == ninguno ]]; then
        printf '%s %s\n' "$base" "$hard"
    else
        printf '%s quiet splash %s\n' "$base" "$hard"
    fi
}

stage_9_limine() {
    log "=== Etapa 9: Limine upstream ==="
    ensure_chroot_mounts
    ensure_target_dirs
    local work="$SCRATCH_DIR_REAL/limine-upstream"
    run mkdir -p "$work"
    run curl -fLo "$work/limine-binary.tar.xz" "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VER}/limine-binary.tar.xz"
    run curl -fLo "$work/limine-binary.tar.xz.sig" "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VER}/limine-binary.tar.xz.sig"
    verify_sha "$LIMINE_SHA" "$work/limine-binary.tar.xz"
    if [[ "$VERIFY_GPG" == si ]]; then
        run mkdir -m 0700 -p "$work/gnupg"
        run gpg --homedir "$work/gnupg" --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LIMINE_KEY"
        run gpg --homedir "$work/gnupg" --batch --verify "$work/limine-binary.tar.xz.sig" "$work/limine-binary.tar.xz"
    else
        log "ADVERTENCIA: firma GPG de Limine omitida; solo se verifica SHA-256"
    fi
    run tar -xJf "$work/limine-binary.tar.xz" -C "$work"
    run make -C "$work/limine-binary" limine
    [[ "$UEFI" == si ]] && run install -m 0644 "$work/limine-binary/BOOTX64.EFI" "$M/boot/EFI/BOOT/BOOTX64.EFI"
    [[ "$UEFI_IA32" == si ]] && run install -m 0644 "$work/limine-binary/BOOTIA32.EFI" "$M/boot/EFI/BOOT/BOOTIA32.EFI"
    [[ "$BIOS_BOOT" == si ]] && run install -m 0644 "$work/limine-binary/limine-bios.sys" "$M/boot/limine-bios.sys"

    local cmdline fallback_cmd editor="no"
    cmdline="$(kernel_cmdline)"
    fallback_cmd="root=/dev/mapper/cryptroot rootfstype=$ROOT_FS ro plymouth.enable=0"
    [[ "$LIMINE_EDITOR" == si ]] && editor="yes"
    write_lines "$M/boot/limine.conf" \
        'timeout: 5' 'default_entry: 1' "editor_enabled: $editor" \
        'interface_branding: DEBIAN MINIMAL' \
        'term_palette: 000000;aa0000;00aa00;aa5500;0000aa;aa00aa;00aaaa;aaaaaa' \
        "term_background: ff$BG" "term_foreground: $FG" \
        "term_foreground_bright: $ACCENT" '' \
        '/Debian 13 trixie (Plymouth)' '    protocol: linux' \
        "    path: boot():/vmlinuz-$K" "    cmdline: $cmdline" \
        "    module_path: boot():/initrd.img-$K"
    if [[ "$PLYMOUTH_FALLBACK" == si ]]; then
        write_line "$M/boot/limine.conf" ''
        write_line "$M/boot/limine.conf" '/Debian 13 trixie (texto)'
        write_line "$M/boot/limine.conf" '    protocol: linux'
        write_line "$M/boot/limine.conf" "    path: boot():/vmlinuz-$K"
        write_line "$M/boot/limine.conf" "    cmdline: $fallback_cmd"
        write_line "$M/boot/limine.conf" "    module_path: boot():/initrd.img-$K"
    fi
    write_line "$M/boot/limine.conf" ''
    write_line "$M/boot/limine.conf" '/Rescate initramfs'
    write_line "$M/boot/limine.conf" '    protocol: linux'
    write_line "$M/boot/limine.conf" "    path: boot():/vmlinuz-$K"
    write_line "$M/boot/limine.conf" "    cmdline: root=/dev/mapper/cryptroot rootfstype=$ROOT_FS ro plymouth.enable=0 break=premount"
    write_line "$M/boot/limine.conf" "    module_path: boot():/initrd.img-$K"
    run sync
    [[ "$BIOS_BOOT" == si ]] && run "$work/limine-binary/limine" bios-install "$U" 1
    mark_stage 9
}

stage_10_plymouth() {
    log "=== Etapa 10: Plymouth ==="
    ensure_chroot_mounts
    if [[ "$PLYMOUTH_THEME" != ninguno ]]; then
        run chroot "$M" /usr/sbin/plymouth-set-default-theme -R "$PLYMOUTH_THEME"
        run chroot "$M" /usr/sbin/update-initramfs -u -k all
    else
        log "Plymouth instalado pero sin splash en la entrada principal"
    fi
    mark_stage 10
}

stage_11_zram_audio() {
    log "=== Etapa 11: ZRAM y PipeWire ==="
    ensure_chroot_mounts
    ensure_target_dirs
    if [[ "$ZRAM" == si ]]; then
        write_lines "$M/etc/systemd/zram-generator.conf" \
            '[zram0]' "zram-size = min(ram / 2, $ZRAM_SIZE)" 'swap-priority = 100'
    else
        run rm -f "$M/etc/systemd/zram-generator.conf"
    fi
    mark_stage 11
}

ensure_zig_resolv_conf() {
    if (( DRY_RUN || SIMULATE )); then
        log "+ comprobar salto de línea final de /etc/resolv.conf del live para Zig ${ZIG_VER}"
        return 0
    fi
    if [[ -f /etc/resolv.conf ]] && [[ -n "$(tail -c 1 /etc/resolv.conf)" ]]; then
        log "Añadiendo salto de línea final a /etc/resolv.conf del live (Zig ${ZIG_VER} lo exige)"
        printf '\n' >> /etc/resolv.conf
    fi
}

stage_12_greeter() {
    log "=== Etapa 12: greeter ==="
    ensure_chroot_mounts
    ensure_target_dirs
    case "$GREETER" in
        ly)
            local src="$SCRATCH_DIR_REAL/ly-build" zig lysrc cache gcache
            run mkdir -p "$src"
            run curl -fLo "$src/zig.tar.xz" "https://ziglang.org/download/${ZIG_VER}/zig-x86_64-linux-${ZIG_VER}.tar.xz"
            run curl -fLo "$src/ly.tar.gz" "https://codeberg.org/fairyglade/ly/archive/v${LY_VER}.tar.gz"
            verify_sha "$ZIG_SHA" "$src/zig.tar.xz"
            verify_sha "$LY_SHA" "$src/ly.tar.gz"
            run tar -xJf "$src/zig.tar.xz" -C "$src"
            run tar -xzf "$src/ly.tar.gz" -C "$src"
            ensure_zig_resolv_conf
            zig="$src/zig-x86_64-linux-${ZIG_VER}/zig"
            lysrc="$src/ly"
            cache="$src/zig-local-cache"
            gcache="$src/zig-global-cache"
            log "Compilando Ly ${LY_VER} FUERA del target con Zig ${ZIG_VER}"
            run_in_dir "$lysrc" env ZIG_GLOBAL_CACHE_DIR="$gcache" ZIG_LOCAL_CACHE_DIR="$cache" "$zig" build --cache-dir "$cache" -Doptimize=ReleaseSafe
            run_in_dir "$lysrc" env ZIG_GLOBAL_CACHE_DIR="$gcache" ZIG_LOCAL_CACHE_DIR="$cache" "$zig" build installexe -Dinit_system=systemd -Ddest_directory="$M" -Doptimize=ReleaseSafe --cache-dir "$cache"
            run chroot "$M" /usr/bin/ly --validate-config /etc/ly/config.ini
            run systemctl --root="$M" disable getty@tty2.service
            run systemctl --root="$M" enable ly@tty2.service
            log "Ly instalado; Zig, tarballs y cachés quedan solo en scratch y se borran al salir"
            ;;
        greetd)
            write_lines "$M/etc/greetd/config.toml" \
                '[terminal]' 'vt = 7' '' '[default_session]' \
                'command = "tuigreet --time --asterisks --remember --remember-session --user-menu"' \
                'user = "_greetd"'
            run systemctl --root="$M" enable greetd.service
            run systemctl --root="$M" disable getty@tty7.service
            ;;
        consola)
            log "Sin greeter gráfico; inicio de sesión por TTY"
            ;;
    esac
    mark_stage 12
}

stage_13_desktop() {
    log "=== Etapa 13: escritorio ==="
    if [[ "$GUI" != si ]]; then mark_stage 13; return 0; fi
    ensure_chroot_mounts
    local home="$M/home/$USERNAME"
    run install -d "$home/.config/openbox" "$home/.config/tint2"
    if [[ "$WM" == openbox ]]; then
        run cp "$M/etc/xdg/openbox/rc.xml" "$home/.config/openbox/rc.xml"
        run sed -i 's|<name>Clearlooks</name>|<name>Nightmare</name>|' "$home/.config/openbox/rc.xml"
        run sed -i "s|<name>sans</name>|<name>${FONT}</name>|g" "$home/.config/openbox/rc.xml"
        run sed -i 's|</keyboard>|  <keybind key="W-r"><action name="Execute"><command>rofi -show drun</command></action></keybind>\n  <keybind key="W-Return"><action name="Execute"><command>xterm</command></action></keybind>\n</keyboard>|' "$home/.config/openbox/rc.xml"
    fi
    write_lines "$home/.Xresources" \
        "XTerm*background: #$BG" "XTerm*foreground: #$FG" \
        "XTerm*cursorColor: #$ACCENT" "XTerm*faceName: $FONT" 'XTerm*faceSize: 10'
    run chroot "$M" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
    mark_stage 13
}

stage_14_security_network() {
    log "=== Etapa 14: red y seguridad ==="
    ensure_chroot_mounts
    if [[ "$FIREWALL" == si ]]; then
        write_lines "$M/etc/nftables.conf" \
            'flush ruleset' '' 'table inet filter {' '    chain input {' \
            '        type filter hook input priority 0; policy drop;' \
            '        iif lo accept' '        ct state established,related accept' \
            '        ct state invalid drop' '        ip protocol icmp accept' \
            '        ip6 nexthdr ipv6-icmp accept' \
            '        udp sport 67 udp dport 68 accept' \
            '        udp sport 547 udp dport 546 accept' '    }' \
            '    chain forward {' '        type filter hook forward priority 0; policy drop;' '    }' \
            '    chain output {' '        type filter hook output priority 0; policy accept;' '    }' '}'
        run chroot "$M" /usr/sbin/nft -c -f /etc/nftables.conf
        run systemctl --root="$M" enable nftables.service
    fi
    [[ "$NETWORK" == NetworkManager ]] && run systemctl --root="$M" enable NetworkManager.service
    [[ "$APPARMOR" == si ]] && run systemctl --root="$M" enable apparmor.service
    [[ "$DOAS" == si ]] && write_lines "$M/etc/doas.conf" 'permit persist :sudo'
    [[ "$SSH" == si ]] && run systemctl --root="$M" enable ssh.service
    mark_stage 14
}

stage_15_cleanup_finish() {
    log "=== Etapa 15: limpieza y cierre ==="
    ensure_chroot_mounts
    if [[ "$CLEAN_TRACES" == si ]]; then
        run rm -rf "$M/debootstrap"
        run rm -f "$M/var/log/bootstrap.log" "$M/var/log/debootstrap.log" "$M/root/.bash_history"
        run find "$M/var/cache/apt/archives" -maxdepth 1 -type f -name '*.deb' -delete
        run find "$M/var/lib/apt/lists" -maxdepth 1 -type f -delete
        run find "$M/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
    run chroot "$M" /usr/bin/dpkg --get-selections '*'
    if (( ! DRY_RUN && ! SIMULATE )) && [[ "$MAKE_HOST_BACKUP" == si ]]; then
        sgdisk --backup="$ARTIFACT_DIR/gpt-final.bin" "$U"
        cp "$M/boot/limine.conf" "$ARTIFACT_DIR/limine.conf"
        cp "$M/etc/crypttab" "$ARTIFACT_DIR/crypttab"
        cp "$M/etc/fstab" "$ARTIFACT_DIR/fstab"
        chmod 600 "$ARTIFACT_DIR/gpt-final.bin" "$ARTIFACT_DIR/limine.conf" "$ARTIFACT_DIR/crypttab" "$ARTIFACT_DIR/fstab"
    fi
    run sync
    run umount -R "$M"
    MOUNTS=()
    run cryptsetup close cryptroot
    mark_stage 15
    if [[ "$DATA_POLICY" == borrar ]] && (( ! DRY_RUN && ! SIMULATE )); then
        run rm -rf "$STATE_DIR" "$ARTIFACT_DIR"
        log "Estado y respaldos borrados; --resume ya no funcionará"
    fi
    log "=== Instalación terminada ==="
    log "No se ha copiado este script, logs, tarballs, Zig ni cachés al sistema instalado."
}

final_summary() {
    log "=== Resumen final ==="
    log "Directorio de estado y respaldos (RAM): $BASE_DIR"
    log "Log: $LOG_FILE"
    if [[ "$DATA_POLICY" != borrar ]]; then
        log "AVISO: todo lo anterior se PIERDE al apagar o reiniciar la VM."
        log "Si quieres conservar la cabecera LUKS, copiala AHORA con curl/scp a otro servidor."
        log "Archivo: $ARTIFACT_DIR/luks-header.img"
    fi
    log "Para probar el arranque, reinicia la VM desde /dev/sda sin el ISO."
    log "Prueba primero UEFI y despues BIOS/Legacy; ambas rutas estan instaladas."
    log "Si la pantalla se queda negra con Plymouth, elige la entrada 'texto' de Limine."
    log "Si el kernel se actualiza: sudo bash $SCRIPT_NAME --refresh-limine"
    log "Tu configuracion de QEMU sigue siendo ajena a este script y no ha sido revisada."
}

# ---------------------------- refresh-limine ----------------------------

refresh_limine() {
    log "=== Modo --refresh-limine ==="
    require_root
    if [[ -r "$CONFIG_FILE" ]]; then
        load_config_from "$CONFIG_FILE"
    else
        log "No hay configuración previa en RAM; se usarán valores por defecto y solo se corregirán las rutas"
    fi
    install_host_deps
    if (( DRY_RUN || SIMULATE )); then
        K="SIMULADO-K"
        run cryptsetup open --key-file - "$R" cryptroot
        run mount /dev/mapper/cryptroot "$M"
        run mount "$B" "$M/boot"
        run sed -i "s#vmlinuz-SIMULADO-K#vmlinuz-$K#g" "$M/boot/limine.conf"
        run sed -i "s#initrd.img-SIMULADO-K#initrd.img-$K#g" "$M/boot/limine.conf"
        run umount -R "$M"
        run cryptsetup close cryptroot
        log "limine.conf actualizado en simulación; este script no quedó en el sistema instalado"
        return 0
    fi
    test -b "$R" || die "No existe $R"
    HELP_FN=help_identity; HELP_SHOWN=""
    ask_secret LUKS_PASS "Frase LUKS para abrir la USB"
    local pf="$SCRATCH_DIR_REAL/luks.pass"
    luks_pass_file "$pf"
    cryptsetup open --key-file - "$R" cryptroot < "$pf"
    mount_track "$M" /dev/mapper/cryptroot
    run mkdir -p "$M/boot"
    mount_track "$M/boot" "$B"
    # shellcheck disable=SC2016
    capture K bash -c 'basename "$(find "$1/boot" -maxdepth 1 -name "vmlinuz-*" | sort | tail -n 1)" | sed "s/^vmlinuz-//"' sh "$M"
    sed -i -E "s#(path: boot\(\):/)vmlinuz-[^ ]+#\1vmlinuz-$K#; s#(module_path: boot\(\):/)initrd.img-[^ ]+#\1initrd.img-$K#" "$M/boot/limine.conf"
    cp "$M/boot/limine.conf" "$ARTIFACT_DIR/limine.conf" 2>/dev/null || true
    sync
    umount -R "$M"
    MOUNTS=()
    cryptsetup close cryptroot
    log "limine.conf actualizado; este script no quedó en el sistema instalado"
}

# ---------------------------- CLI ----------------------------

usage() {
    cat <<'USO'
Uso: install.sh [OPCIONES]

  --explain               Imprime TODAS las explicaciones y sale. No toca nada.
                          Ideal: bash install.sh --explain | less
  --validate              Autocomprobación estática; no pregunta, no cambia nada.
  --dry-run               Muestra todas las órdenes; no ejecuta cambios.
  --simulate              Con --dry-run: omite disco real, root y red.
  --yes, --accept-defaults
                          Acepta valores por defecto; en modo real SIGUE pidiendo
                          contraseñas y la confirmación literal de borrado.
  --config ARCHIVO        Carga preferencias no secretas guardadas en RAM.
  --resume                Continúa desde la última etapa guardada EN ESTA SESIÓN.
  --refresh-limine        Abre la USB y actualiza rutas versionadas de kernel.
  --log ARCHIVO           Ruta del log (por defecto en artifacts/ de /tmp).
  --version               Muestra versión.
  -h, --help              Esta ayuda.

En cualquier pregunta escribe ? para volver a leer su explicación.

Orden recomendado dentro del live:
  1) curl -fLo /tmp/install.sh https://raw.githubusercontent.com/TU_USUARIO/TU_REPO/main/install.sh
  2) bash /tmp/install.sh --explain | less
  3) bash /tmp/install.sh --validate
  4) bash /tmp/install.sh --dry-run --simulate --yes
  5) sudo bash /tmp/install.sh
  6) si falla SIN reiniciar: sudo bash /tmp/install.sh --resume

Advertencia: no se puede garantizar "fallo cero". Todo el estado y los
respaldos viven en /tmp (tmpfs/RAM) y se pierden al apagar la VM. No he
ejecutado una instalación real completa con este script.
USO
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --explain) EXPLAIN_ONLY=1 ;;
            --validate) VALIDATE_ONLY=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --simulate) SIMULATE=1; DRY_RUN=1 ;;
            --yes|--accept-defaults) ACCEPT_DEFAULTS=1 ;;
            --resume) RESUME=1 ;;
            --refresh-limine) REFRESH_LIMINE=1 ;;
            --config) shift; INPUT_CONFIG="$1" ;;
            --log) shift; LOG_FILE="$1"; LOG_GIVEN=1 ;;
            --version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Opción desconocida: $1" ;;
        esac
        shift
    done
    if (( SIMULATE && ! DRY_RUN )); then die "--simulate requiere --dry-run"; fi
    if (( RESUME && REFRESH_LIMINE )); then die "No combines --resume y --refresh-limine"; fi
}

main() {
    parse_args "$@"
    set_defaults
    derive_paths
    init_dirs

    if (( EXPLAIN_ONLY )); then
        help_all
        exit 0
    fi
    if (( VALIDATE_ONLY )); then
        self_check
        bash -n "$0"
        log "Validación OK; versión $SCRIPT_VERSION"
        exit 0
    fi
    if (( REFRESH_LIMINE )); then
        refresh_limine
        exit 0
    fi

    log "=== $SCRIPT_NAME $SCRIPT_VERSION ==="
    log "Fecha: $(date -Is)"
    if (( DRY_RUN )); then log "MODO SIMULACIÓN: no se ejecutará ninguna orden con efectos"; fi
    self_check

    if (( RESUME )); then
        [[ -r "$STATE_FILE" ]] || die "No existe estado para --resume: $STATE_FILE (se pierde al reiniciar la VM)"
        [[ -r "$CONFIG_FILE" ]] || die "No existe configuración para --resume: $CONFIG_FILE"
        read_state
        load_config_from "$CONFIG_FILE"
        [[ -n "$INPUT_CONFIG" ]] && load_config_from "$INPUT_CONFIG"
        log "Reanudando desde etapa $((LAST_STAGE+1))"
        preflight
        ensure_resume_mounts
    else
        [[ -n "$INPUT_CONFIG" ]] && load_config_from "$INPUT_CONFIG"
        collect_preferences
        derive_paths
        preflight
        mark_stage 0
    fi

    stage_done 1 || stage_1_prepare
    stage_done 2 || stage_2_partition
    stage_done 3 || stage_3_luks_mount
    stage_done 4 || stage_4_debootstrap
    stage_done 5 || stage_5_sources
    stage_done 6 || stage_6_packages
    stage_done 7 || stage_7_system_config
    stage_done 8 || stage_8_crypt_fstab
    stage_done 9 || stage_9_limine
    stage_done 10 || stage_10_plymouth
    stage_done 11 || stage_11_zram_audio
    stage_done 12 || stage_12_greeter
    stage_done 13 || stage_13_desktop
    stage_done 14 || stage_14_security_network
    stage_done 15 || stage_15_cleanup_finish
    final_summary

    unset LUKS_PASS USER_PASS ROOT_PASS
    log "=== FIN ==="
}

main "$@"
