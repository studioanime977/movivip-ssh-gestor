#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — desinstalador
#
#      sudo ./uninstall.sh              Quita programa y servicio
#      sudo ./uninstall.sh --purge      Además borra configuración,
#                                       contraseñas guardadas y consumo
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/opt/movi-ssh}"
BINDIR="${BINDIR:-/usr/local/bin}"
ETC="${ETC:-/etc/movi-ssh}"
STATE="${STATE:-/var/lib/movi-ssh}"
PURGE=0
YES=0

ORIGINAL_ARGS=("$@")

while (( $# )); do
    case "$1" in
        --purge) PURGE=1; shift ;;
        --yes|-y) YES=1; shift ;;
        --prefix) PREFIX="${2:?}"; shift 2 ;;
        --bindir) BINDIR="${2:?}"; shift 2 ;;
        --etc) ETC="${2:?}"; shift 2 ;;
        --state) STATE="${2:?}"; shift 2 ;;
        -h|--help) awk 'NR>1 && /^set /{exit} NR>1 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done

if [[ "$EUID" -ne 0 && ( "$PREFIX" == "/opt/movi-ssh" || "$BINDIR" == "/usr/local/bin" ) ]]; then
    exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
fi

if (( ! YES )); then
    echo "Se quitará el programa de $PREFIX y el comando $BINDIR/movi."
    if (( PURGE )); then
        echo "Además se borrarán $ETC y $STATE (contraseñas y consumo)."
    fi
    read -rp "¿Continuar? [s/N]: " resp
    [[ "$resp" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 0; }
fi

if [[ "$EUID" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now movi-meter.timer >/dev/null 2>&1 || true
    systemctl stop movi-meter.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/movi-meter.timer /etc/systemd/system/movi-meter.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f /usr/share/applications/movi.desktop
fi

if [[ -L "$BINDIR/movi" || -f "$BINDIR/movi" ]]; then
    rm -f "$BINDIR/movi"
    echo "✔ Comando $BINDIR/movi eliminado"
fi

rm -rf "$PREFIX"
echo "✔ Programa eliminado de $PREFIX"

if (( PURGE )); then
    rm -rf "$ETC" "$STATE"
    echo "✔ Configuración y estado eliminados ($ETC, $STATE)"
else
    echo "↷ Se conservan $ETC y $STATE (use --purge para borrarlos)"
fi

echo "Desinstalación completada."
