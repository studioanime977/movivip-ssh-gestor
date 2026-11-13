#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — núcleo compartido
#  Rutas, colores, validaciones y utilidades.
#
#  Todas las rutas se pueden sobrescribir por entorno. La batería
#  de pruebas (tests/run-tests.sh) monta un sistema falso con esto,
#  sin tocar el sistema real.
# ============================================================

# ── Rutas ───────────────────────────────────────────────────
MOVI_HOME="${MOVI_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
MOVI_LIB="${MOVI_LIB:-$MOVI_HOME/lib}"
MOVI_ETC="${MOVI_ETC:-/etc/movi-ssh}"
MOVI_STATE="${MOVI_STATE:-/var/lib/movi-ssh}"
MOVI_PASSWD="${MOVI_PASSWD:-/etc/passwd}"
MOVI_SHADOW="${MOVI_SHADOW:-/etc/shadow}"
MOVI_PYTHON="${MOVI_PYTHON:-python3}"
MOVI_CONFIG="$MOVI_ETC/config.conf"
MOVI_VERSION="$(cat "$MOVI_HOME/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]')"
[[ -n "$MOVI_VERSION" ]] || MOVI_VERSION="1.0.0"

# ── Colores (se apagan si no hay terminal o MOVI_NO_COLOR=1) ─
if [[ -t 1 && "${MOVI_NO_COLOR:-0}" != "1" ]]; then
    GREEN=$'\e[1;92m'
    RED=$'\e[1;91m'
    YELLOW=$'\e[1;93m'
    BLUE=$'\e[1;94m'
    CYAN=$'\e[1;96m'
    MAGENTA=$'\e[1;95m'
    WHITE=$'\e[1;97m'
    GRAY=$'\e[1;90m'
    RESET=$'\e[0m'
else
    GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""
    MAGENTA=""; WHITE=""; GRAY=""; RESET=""
fi

# ── Valores por defecto (los puede cambiar config.conf) ─────
DIAS_DEFECTO=30
GB_DEFECTO=0
CONEXIONES_DEFECTO=0
BLOQUEAR_AL_EXCEDER=1
CORTAR_EXCESO_CONEXIONES=1
SHELL_USUARIO=/bin/bash
PUERTO_SSH=""
IP_PUBLICA=""

# ── Configuración ───────────────────────────────────────────
movi_config_load() {
    [[ -r "$MOVI_CONFIG" ]] || return 0
    local clave valor
    while IFS='=' read -r clave valor || [[ -n "$clave" ]]; do
        clave="${clave//[[:space:]]/}"
        valor="${valor%$'\r'}"
        [[ -z "$clave" || "$clave" == \#* ]] && continue
        case "$clave" in
            DIAS_DEFECTO)         [[ "$valor" =~ ^[0-9]+$ ]] && DIAS_DEFECTO="$valor" ;;
            GB_DEFECTO)           [[ "$valor" =~ ^[0-9]+([.,][0-9]+)?$ ]] && GB_DEFECTO="$valor" ;;
            CONEXIONES_DEFECTO)   [[ "$valor" =~ ^[0-9]+$ ]] && CONEXIONES_DEFECTO="$valor" ;;
            BLOQUEAR_AL_EXCEDER)  BLOQUEAR_AL_EXCEDER="$valor" ;;
            CORTAR_EXCESO_CONEXIONES) CORTAR_EXCESO_CONEXIONES="$valor" ;;
            SHELL_USUARIO)        [[ -n "$valor" ]] && SHELL_USUARIO="$valor" ;;
            PUERTO_SSH)           PUERTO_SSH="$valor" ;;
            IP_PUBLICA)           IP_PUBLICA="$valor" ;;
        esac
    done < "$MOVI_CONFIG"
}

# ── Mensajes ────────────────────────────────────────────────
movi_ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$1"; }
movi_err()  { printf '%s✖%s %s\n' "$RED" "$RESET" "$1" >&2; }
movi_warn() { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$1"; }
movi_info() { printf '  %s\n' "$1"; }

movi_clear() { [[ -t 1 ]] && clear; }

movi_pausa() {
    [[ -t 0 ]] || return 0
    read -rp "  Enter para continuar..." _ || true
}

movi_titulo() {
    printf '\n%s══ %s ══%s\n\n' "$CYAN" "$1" "$RESET"
}

# ── Validaciones ────────────────────────────────────────────
movi_es_numero() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

movi_es_decimal() { [[ "${1:-}" =~ ^[0-9]+([.,][0-9]+)?$ ]]; }

movi_usuario_valido() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; }

movi_password_valida() {
    [[ -n "${1:-}" ]] || return 1
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || return 1
    return 0
}

# ── Utilidades numéricas ────────────────────────────────────
# Convierte bytes a texto legible (B, KB, MB, GB, TB, PB).
movi_human() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    LC_ALL=C awk -v b="$bytes" 'BEGIN{
        split("B KB MB GB TB PB", u, " "); i = 1;
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i];
        else printf "%.2f %s", b, u[i];
    }'
}

# Convierte GB (admite decimales, coma o punto) a bytes.
movi_gb_a_bytes() {
    local g="${1:-0}"
    g="${g//,/.}"
    [[ "$g" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    LC_ALL=C awk -v g="$g" 'BEGIN{ printf "%.0f\n", g * 1073741824 }'
}

# ── Credenciales aleatorias ─────────────────────────────────
# 16 caracteres con mayúscula, minúscula, dígito y símbolo.
# Sin espacio, comillas, $, `, \ ni ":" para no romper archivos.
movi_pass_aleatoria() {
    local p i simbolo
    for (( i = 0; i < 200; i++ )); do
        p="$(LC_ALL=C tr -dc 'A-Za-z0-9!#%*+=?@-' </dev/urandom 2>/dev/null | head -c 16)"
        [[ "${#p}" -eq 16 ]] || continue
        [[ "$p" =~ [A-Z] ]] || continue
        [[ "$p" =~ [a-z] ]] || continue
        [[ "$p" =~ [0-9] ]] || continue
        simbolo=0
        case "$p" in *[#%*+=?@-]*) simbolo=1 ;; esac
        [[ "$simbolo" == "1" ]] || continue
        printf '%s' "$p"
        return 0
    done
    return 1
}

movi_usuario_aleatorio() {
    local u i
    for (( i = 0; i < 200; i++ )); do
        u="mv$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 7)"
        [[ "${#u}" -eq 9 ]] || continue
        movi_usuario_existe "$u" && continue
        printf '%s' "$u"
        return 0
    done
    return 1
}

# ── Archivos clave=valor ────────────────────────────────────
movi_kv_get() {
    local f="$1" k="$2"
    [[ -r "$f" ]] || return 1
    awk -F= -v k="$k" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

movi_kv_set() {
    local f="$1" k="$2" v="$3" tmp
    mkdir -p "$(dirname -- "$f")" 2>/dev/null || true
    tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
    if [[ -r "$f" ]]; then
        awk -F= -v k="$k" '$1!=k' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s=%s\n' "$k" "$v" >> "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
}

movi_kv_del() {
    local f="$1" k="$2" tmp
    [[ -f "$f" ]] || return 0
    tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
    awk -F= -v k="$k" '$1!=k' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
}

# Borra líneas cuyo primer campo (separador |) sea $2.
movi_prefijo_del() {
    local f="$1" k="$2" tmp
    [[ -f "$f" ]] || return 0
    tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
    awk -F'|' -v k="$k" '$1!=k' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
}

# ── Usuarios del sistema ────────────────────────────────────
movi_usuario_existe() {
    [[ -n "${1:-}" ]] || return 1
    awk -F: -v u="$1" '$1==u { found=1 } END { exit(found ? 0 : 1) }' "$MOVI_PASSWD" 2>/dev/null && return 0
    id -u "$1" >/dev/null 2>&1
}

# Usuarios "de cliente": UID >= 1000 y que no sean nobody.
movi_usuarios_sistema() {
    awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody" { print $1 }' "$MOVI_PASSWD" 2>/dev/null | sort
}

# ── Fechas / expiración ─────────────────────────────────────
movi_expira() {
    local u="$1" out
    out="$(LC_ALL=C chage -l "$u" 2>/dev/null | awk -F: '/Account expires/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
    printf '%s' "${out:-desconocido}"
}

# Devuelve epoch, o -1 si la cuenta no expira.
movi_expira_epoch() {
    local v="${1:-}"
    if [[ -z "$v" || "$v" == "never" || "$v" == "-1" ]]; then
        echo -1
        return 0
    fi
    local e
    e="$(date -d "$v" +%s 2>/dev/null)" || e=-1
    echo "$e"
}

# Motivo por el que movi suspendió una cuenta (vacío si movi no la tocó).
movi_motivo_suspension() {
    local f="$MOVI_ETC/suspendidos.conf"
    [[ -r "$f" ]] || return 0
    awk -F'|' -v u="$1" '$1==u { print $3; exit }' "$f"
}

movi_estado_cuenta() {
    local u="$1" exp="${2:-}"
    local pw motivo
    pw="$(LC_ALL=C passwd -S "$u" 2>/dev/null | awk '{ print $2 }')"
    if [[ "$pw" == L* ]]; then
        # Distingue el bloqueo de movi del que ya traía la cuenta del sistema
        # (nube/cuentas de llave: contraseña `!` o `!!` en shadow).
        motivo="$(movi_motivo_suspension "$u")"
        case "$motivo" in
            consumo) printf '%s' "BLOQUEADO (límite)" ;;
            manual)  printf '%s' "BLOQUEADO" ;;
            *)       printf '%s' "CLAVE BLOQUEADA" ;;
        esac
        return 0
    fi
    local e
    e="$(movi_expira_epoch "$exp")"
    if [[ "$e" != "-1" && "$e" -lt "$(date +%s)" ]]; then
        printf '%s' "EXPIRADO"
        return 0
    fi
    printf '%s' "ACTIVO"
}

# ── Servidor ────────────────────────────────────────────────
movi_ip() {
    local ip="${IP_PUBLICA:-}"
    [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
    printf '%s' "${ip:-127.0.0.1}"
}

movi_ssh_port() {
    local p="${PUERTO_SSH:-}"
    if [[ -z "$p" ]]; then
        p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2; exit }' /etc/ssh/sshd_config 2>/dev/null)"
    fi
    printf '%s' "${p:-22}"
}

# ── Root ────────────────────────────────────────────────────
movi_requiere_root() {
    [[ "${MOVI_ALLOW_NONROOT:-0}" == "1" ]] && return 0
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}
