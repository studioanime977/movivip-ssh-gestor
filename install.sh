#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — instalador
#
#  Instala el menú, el medidor de consumo y el comando `movi`.
#
#  Uso normal (como root o con sudo):
#      sudo ./install.sh
#
#  Instalación de prueba en rutas propias (no requiere root):
#      ./install.sh --prefix /tmp/movi --bindir /tmp/bin \
#                   --etc /tmp/movi-etc --state /tmp/movi-state \
#                   --no-systemd --no-desktop
# ============================================================
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${PREFIX:-/opt/movi-ssh}"
BINDIR="${BINDIR:-/usr/local/bin}"
ETC="${ETC:-/etc/movi-ssh}"
STATE="${STATE:-/var/lib/movi-ssh}"
SKIP_SYSTEMD="${SKIP_SYSTEMD:-0}"
SKIP_DESKTOP="${SKIP_DESKTOP:-0}"

ORIGINAL_ARGS=("$@")

while (( $# )); do
    case "$1" in
        --prefix)     PREFIX="${2:?}"; shift 2 ;;
        --bindir)     BINDIR="${2:?}"; shift 2 ;;
        --etc)        ETC="${2:?}"; shift 2 ;;
        --state)      STATE="${2:?}"; shift 2 ;;
        --no-systemd) SKIP_SYSTEMD=1; shift ;;
        --no-desktop) SKIP_DESKTOP=1; shift ;;
        -h|--help)
            awk 'NR>1 && /^set /{exit} NR>1 {sub(/^# ?/,""); print}' "$0"
            exit 0
            ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done

echo
echo "MOVIVIP · GESTOR SSH — instalador"
echo "──────────────────────────────────────────────"
echo "  programa : $PREFIX"
echo "  comando  : $BINDIR/movi"
echo "  config   : $ETC"
echo "  estado   : $STATE"
echo

# ── Root: solo obligatorio si se tocan rutas del sistema ────
sistema=0
[[ "$PREFIX" == "/opt/movi-ssh" ]] && sistema=1
[[ "$BINDIR" == "/usr/local/bin" ]] && sistema=1
[[ "$ETC" == "/etc/movi-ssh" ]] && sistema=1
[[ "$STATE" == "/var/lib/movi-ssh" ]] && sistema=1

if [[ "$EUID" -ne 0 ]]; then
    if (( sistema )); then
        if command -v sudo >/dev/null 2>&1; then
            echo "Se requieren privilegios de root; relanzando con sudo..."
            exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
        fi
        echo "✖ Ejecute el instalador como root: sudo ./install.sh" >&2
        exit 1
    fi
    echo "⚠ Instalación en rutas propias sin root (modo de prueba)."
fi

# ── Dependencias ────────────────────────────────────────────
faltan=0
for cmd in bash python3 useradd usermod userdel chage passwd ss ps openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "✖ Falta el comando requerido: $cmd" >&2
        faltan=1
    fi
done
(( faltan == 0 )) || exit 1

# ── Programa ────────────────────────────────────────────────
install -d -m 755 "$PREFIX"
install -d -m 755 "$PREFIX/lib"

install -m 755 "$SRC/movi" "$PREFIX/movi"
for f in common.sh accounts.sh menu.sh cli.sh; do
    install -m 644 "$SRC/lib/$f" "$PREFIX/lib/$f"
done
install -m 755 "$SRC/lib/meter.py" "$PREFIX/lib/meter.py"
install -m 644 "$SRC/VERSION" "$PREFIX/VERSION"
[[ -f "$SRC/README.md" ]] && install -m 644 "$SRC/README.md" "$PREFIX/README.md"
install -m 755 "$SRC/uninstall.sh" "$PREFIX/uninstall.sh"

# Rutas fijadas en el arranque: así una instalación con --prefix/--etc/--state
# propios sigue siendo coherente al ejecutar el comando `movi` y el medidor.
cat > "$PREFIX/lib/paths.conf" <<PATHS
# Rutas fijadas por install.sh (el entorno puede sobrescribirlas)
MOVI_ETC=$ETC
MOVI_STATE=$STATE
PATHS
chmod 644 "$PREFIX/lib/paths.conf"

{
    printf '# Generado por install.sh a partir de lib/paths.conf\n'
    printf ': "${MOVI_ETC:=%s}"\n' "$ETC"
    printf ': "${MOVI_STATE:=%s}"\n' "$STATE"
    printf 'export MOVI_ETC MOVI_STATE\n'
} > "$PREFIX/lib/paths.sh"
chmod 644 "$PREFIX/lib/paths.sh"

# ── Configuración y estado ──────────────────────────────────
install -d -m 755 "$ETC"
install -d -m 700 "$STATE"

if [[ ! -f "$ETC/config.conf" ]]; then
    cat > "$ETC/config.conf" <<'CONF'
# ============================================================
#  MOVIVIP · GESTOR SSH — configuración
# ============================================================
# Días de vigencia por defecto al crear una cuenta (0 = sin límite).
DIAS_DEFECTO=30

# Consumo máximo por defecto en GB (0 = ilimitado).
GB_DEFECTO=0

# Conexiones simultáneas por defecto (0 = ilimitado).
CONEXIONES_DEFECTO=0

# 1 = bloquear la cuenta al alcanzar su límite de consumo.
# 0 = solo medir, nunca bloquear.
BLOQUEAR_AL_EXCEDER=1

# Shell de las cuentas creadas.
SHELL_USUARIO=/bin/bash

# Puerto SSH que se muestra en el resumen (vacío = leer sshd_config).
PUERTO_SSH=

# IP pública que se muestra en el resumen (vacío = IP local del servidor).
IP_PUBLICA=
CONF
    chmod 644 "$ETC/config.conf"
    echo "✔ Configuración creada: $ETC/config.conf"
else
    echo "↷ Se conserva la configuración existente: $ETC/config.conf"
fi

for f in passwords.conf limites_consumo.conf limites_conexiones.conf suspendidos.conf; do
    [[ -e "$ETC/$f" ]] || : > "$ETC/$f"
    chmod 600 "$ETC/$f"
done

# ── Comando movi ────────────────────────────────────────────
install -d -m 755 "$BINDIR"
ln -sfn "$PREFIX/movi" "$BINDIR/movi"
echo "✔ Comando instalado: $BINDIR/movi"

# ── systemd: medidor cada 15 segundos ───────────────────────
if [[ "$SKIP_SYSTEMD" == "1" ]]; then
    echo "↷ systemd omitido (--no-systemd)."
elif command -v systemctl >/dev/null 2>&1; then
    UNIT_DIR="/etc/systemd/system"
    cat > "$UNIT_DIR/movi-meter.service" <<UNIT
[Unit]
Description=MOVIVIP Gestor SSH - medidor de consumo por usuario
Documentation=file://$PREFIX/README.md
After=network.target

[Service]
Type=oneshot
Environment=MOVI_ETC=$ETC
Environment=MOVI_STATE=$STATE
ExecStart=/usr/bin/env python3 $PREFIX/lib/meter.py --collect
Nice=10
UNIT

    cat > "$UNIT_DIR/movi-meter.timer" <<'UNIT'
[Unit]
Description=MOVIVIP Gestor SSH - muestra de consumo cada 15 segundos

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=2s
Unit=movi-meter.service

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now movi-meter.timer >/dev/null 2>&1 || true
    systemctl start movi-meter.service >/dev/null 2>&1 || true
    echo "✔ Medidor instalado y activo (movi-meter.timer, cada 15 s)"
else
    echo "⚠ systemd no disponible: el medidor no se programó automáticamente."
    echo "  Añada a cron:  * * * * * python3 $PREFIX/lib/meter.py --collect"
    echo "  (cron no admite segundos: cada minuto es lo más fino posible)"
fi

# ── Lanzador de escritorio ──────────────────────────────────
if [[ "$SKIP_DESKTOP" != "1" ]]; then
    mkdir -p /usr/share/applications
    cat > /usr/share/applications/movi.desktop <<DESK
[Desktop Entry]
Type=Application
Name=MOVIVIP Gestor SSH
Comment=Crear, eliminar y medir consumo de usuarios SSH
Exec=$BINDIR/movi
Icon=utilities-terminal
Terminal=true
Categories=System;TerminalEmulator;
DESK
    chmod 644 /usr/share/applications/movi.desktop

    # Copia en el escritorio del usuario que lanzó sudo, si existe.
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        if [[ -n "$home" && -d "$home" ]]; then
            for escritorio in "$home/Escritorio" "$home/Desktop"; do
                if [[ -d "$escritorio" ]]; then
                    install -m 755 /usr/share/applications/movi.desktop "$escritorio/MOVIVIP-Gestor-SSH.desktop"
                    chown "$SUDO_USER":"$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" \
                        "$escritorio/MOVIVIP-Gestor-SSH.desktop" 2>/dev/null || true
                    break
                fi
            done
        fi
    fi
    echo "✔ Acceso directo de escritorio instalado"
fi

# ── Verificación ────────────────────────────────────────────
echo
echo "Verificación:"
if "$BINDIR/movi" version >/dev/null 2>&1; then
    echo "  ✔ $("$BINDIR/movi" version)"
else
    echo "  ✖ El comando no responde" >&2
    exit 1
fi

python3 "$PREFIX/lib/meter.py" --collect >/dev/null 2>&1 || true
if python3 "$PREFIX/lib/meter.py" --status >/dev/null 2>&1; then
    echo "  ✔ Medidor operativo"
else
    echo "  ✖ El medidor no responde" >&2
    exit 1
fi

echo
echo "Listo. Entre con el comando:  movi"
echo
