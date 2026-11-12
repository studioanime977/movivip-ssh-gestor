#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — operaciones sobre cuentas
#  Crear, eliminar, editar, bloquear, límites y consumo.
#  Requiere lib/common.sh ya cargado.
# ============================================================

movi_archivo_passwords()  { printf '%s' "$MOVI_ETC/passwords.conf"; }
movi_archivo_limites()    { printf '%s' "$MOVI_ETC/limites_consumo.conf"; }
movi_archivo_conexiones() { printf '%s' "$MOVI_ETC/limites_conexiones.conf"; }
movi_archivo_suspendidos(){ printf '%s' "$MOVI_ETC/suspendidos.conf"; }

movi_asegurar_dirs() {
    mkdir -p "$MOVI_ETC" "$MOVI_STATE" 2>/dev/null || true
    chmod 755 "$MOVI_ETC" 2>/dev/null || true
    chmod 700 "$MOVI_STATE" 2>/dev/null || true
    local f
    for f in "$(movi_archivo_passwords)" "$(movi_archivo_limites)" \
             "$(movi_archivo_conexiones)" "$(movi_archivo_suspendidos)"; do
        [[ -e "$f" ]] || : > "$f" 2>/dev/null || true
        chmod 600 "$f" 2>/dev/null || true
    done
}

# ── Contraseña ──────────────────────────────────────────────
movi_set_password() {
    local u="$1" p="$2" hash=""
    hash="$(printf '%s\n' "$p" | openssl passwd -6 -stdin 2>/dev/null)" || hash=""
    if [[ -n "$hash" ]]; then
        usermod -p "$hash" "$u" >/dev/null 2>&1 || return 1
    else
        printf '%s:%s\n' "$u" "$p" | chpasswd >/dev/null 2>&1 || return 1
    fi
    movi_kv_set "$(movi_archivo_passwords)" "$u" "$p"
}

movi_password_guardada() {
    movi_kv_get "$(movi_archivo_passwords)" "$1"
}

# ── Crear ───────────────────────────────────────────────────
movi_crear_usuario() {
    local u="${1:-}" p="${2:-}"
    local dias="${3:-$DIAS_DEFECTO}"
    local gb="${4:-$GB_DEFECTO}"
    local conns="${5:-$CONEXIONES_DEFECTO}"
    local bytes

    movi_asegurar_dirs

    movi_usuario_valido "$u" || { movi_err "Nombre de usuario inválido: '$u' (minúsculas, empieza por letra, máx. 32)."; return 1; }
    if movi_usuario_existe "$u"; then
        movi_err "El usuario '$u' ya existe."
        return 1
    fi
    movi_password_valida "$p" || { movi_err "Contraseña inválida (vacía o con salto de línea)."; return 1; }
    movi_es_numero "$dias" || { movi_err "Días inválidos: '$dias'."; return 1; }
    movi_es_numero "$conns" || { movi_err "Conexiones inválidas: '$conns'."; return 1; }
    bytes="$(movi_gb_a_bytes "$gb")" || { movi_err "Límite en GB inválido: '$gb'."; return 1; }

    local -a alta=(useradd -s "$SHELL_USUARIO")
    if [[ ! -d "/home/$u" ]]; then
        alta+=(-m -d "/home/$u")
    fi
    alta+=("$u")

    if ! "${alta[@]}" >/dev/null 2>&1; then
        movi_err "No se pudo crear el usuario '$u' (useradd)."
        return 1
    fi

    if ! movi_set_password "$u" "$p"; then
        userdel -r "$u" >/dev/null 2>&1 || userdel "$u" >/dev/null 2>&1
        movi_err "No se pudo asignar la contraseña; se deshizo el alta."
        return 1
    fi

    if (( dias > 0 )); then
        chage -E "$(date -d "+$dias days" +%Y-%m-%d)" "$u" >/dev/null 2>&1
    else
        chage -E -1 "$u" >/dev/null 2>&1
    fi
    chage -m 0 -M 99999 "$u" >/dev/null 2>&1 || true
    passwd -u "$u" >/dev/null 2>&1 || true

    movi_kv_set "$(movi_archivo_limites)" "$u" "$bytes"
    movi_kv_set "$(movi_archivo_conexiones)" "$u" "$conns"
    movi_prefijo_del "$(movi_archivo_suspendidos)" "$u"
    return 0
}

# ── Eliminar ────────────────────────────────────────────────
movi_olvidar_usuario() {
    local u="$1"
    movi_kv_del "$(movi_archivo_passwords)" "$u"
    movi_kv_del "$(movi_archivo_limites)" "$u"
    movi_kv_del "$(movi_archivo_conexiones)" "$u"
    movi_prefijo_del "$(movi_archivo_suspendidos)" "$u"
    "$MOVI_PYTHON" "$MOVI_LIB/meter.py" --forget "$u" >/dev/null 2>&1 || true
}

movi_eliminar_usuario() {
    local u="${1:-}" conservar_home="${2:-0}"
    local rc=0
    movi_usuario_existe "$u" || { movi_err "El usuario '$u' no existe."; return 2; }

    pkill -u "$u" >/dev/null 2>&1 || true
    sleep 0.2

    if [[ "$conservar_home" == "1" ]]; then
        userdel "$u" >/dev/null 2>&1 || rc=$?
    else
        userdel -r "$u" >/dev/null 2>&1 || userdel -f "$u" >/dev/null 2>&1 || rc=$?
    fi
    if (( rc != 0 )); then
        movi_err "No se pudo eliminar '$u' (userdel)."
        return 1
    fi

    movi_olvidar_usuario "$u"
    return 0
}

# ── Renovar / límites / bloqueo ─────────────────────────────
movi_renovar_usuario() {
    local u="$1" dias="$2" fecha
    movi_usuario_existe "$u" || return 2
    movi_es_numero "$dias" || return 1
    if (( dias > 0 )); then
        fecha="$(date -d "+$dias days" +%Y-%m-%d)"
    else
        fecha="-1"
    fi
    chage -E "$fecha" "$u" >/dev/null 2>&1 || return 1
    printf '%s' "$fecha"
}

movi_limite_consumo() {
    local u="$1" gb="$2" bytes
    movi_usuario_existe "$u" || return 2
    bytes="$(movi_gb_a_bytes "$gb")" || return 1
    movi_kv_set "$(movi_archivo_limites)" "$u" "$bytes" || return 1
    # Aplica el nuevo límite de inmediato (bloquea o desbloquea).
    "$MOVI_PYTHON" "$MOVI_LIB/meter.py" --enforce >/dev/null 2>&1 || true
}

movi_limite_conexiones() {
    local u="$1" n="$2"
    movi_usuario_existe "$u" || return 2
    movi_es_numero "$n" || return 1
    movi_kv_set "$(movi_archivo_conexiones)" "$u" "$n"
}

movi_bloquear_usuario() {
    local u="$1" motivo="${2:-manual}"
    movi_usuario_existe "$u" || return 2
    passwd -l "$u" >/dev/null 2>&1 || return 1
    movi_prefijo_del "$(movi_archivo_suspendidos)" "$u"
    printf '%s|%s|%s\n' "$u" "$(date +%s)" "$motivo" >> "$(movi_archivo_suspendidos)"
    chmod 600 "$(movi_archivo_suspendidos)" 2>/dev/null || true
}

movi_desbloquear_usuario() {
    local u="$1"
    movi_usuario_existe "$u" || return 2
    passwd -u "$u" >/dev/null 2>&1 || true
    movi_prefijo_del "$(movi_archivo_suspendidos)" "$u"
}

# ── Consumo ─────────────────────────────────────────────────
movi_uso_bytes() {
    local u="$1" b
    b="$("$MOVI_PYTHON" "$MOVI_LIB/meter.py" --usage-bytes "$u" 2>/dev/null)" || b=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    printf '%s' "$b"
}

movi_uso_humano() {
    movi_human "$(movi_uso_bytes "$1")"
}

movi_reset_consumo() {
    local u="$1"
    "$MOVI_PYTHON" "$MOVI_LIB/meter.py" --reset "$u" >/dev/null 2>&1
    # Con el contador en cero, un bloqueo por consumo deja de tener sentido.
    "$MOVI_PYTHON" "$MOVI_LIB/meter.py" --enforce >/dev/null 2>&1 || true
}

# Mapas globales: consumo, límites y conexiones por usuario.
declare -gA MOVI_USO=()
declare -gA MOVI_LIM=()
declare -gA MOVI_CONEXIONES=()
declare -gA MOVI_CONNLIM=()

movi_cargar_uso() {
    MOVI_USO=()
    MOVI_CONEXIONES=()
    local u b c
    while IFS='|' read -r u b c; do
        [[ -n "$u" ]] || continue
        MOVI_USO["$u"]="${b:-0}"
        MOVI_CONEXIONES["$u"]="${c:-0}"
    done < <("$MOVI_PYTHON" "$MOVI_LIB/meter.py" --dump 2>/dev/null)
}

movi_cargar_limites() {
    MOVI_LIM=()
    MOVI_CONNLIM=()
    local f u v
    f="$(movi_archivo_limites)"
    if [[ -r "$f" ]]; then
        while IFS='=' read -r u v; do
            [[ -n "$u" ]] && MOVI_LIM["$u"]="${v%$'\r'}"
        done < "$f"
    fi
    f="$(movi_archivo_conexiones)"
    if [[ -r "$f" ]]; then
        while IFS='=' read -r u v; do
            [[ -n "$u" ]] && MOVI_CONNLIM["$u"]="${v%$'\r'}"
        done < "$f"
    fi
}

# ── Tabla de usuarios ───────────────────────────────────────
movi_tabla_usuarios() {
    local modo="${1:-tabla}"
    local -a users=()
    mapfile -t users < <(movi_usuarios_sistema)

    if (( ${#users[@]} == 0 )); then
        movi_warn "No hay usuarios SSH registrados (UID >= 1000)."
        return 0
    fi

    movi_cargar_uso
    movi_cargar_limites

    local u exp uso lim conn connlim est
    if [[ "$modo" == "plano" ]]; then
        for u in "${users[@]}"; do
            exp="$(movi_expira "$u")"
            printf '%s|%s|%s|%s|%s\n' \
                "$u" "$exp" "${MOVI_USO[$u]:-0}" "${MOVI_LIM[$u]:-0}" \
                "$(movi_estado_cuenta "$u" "$exp")"
        done
        return 0
    fi

    printf '  %-3s %-16s %-12s %-11s %-11s %-6s %s\n' \
        "#" "USUARIO" "EXPIRA" "CONSUMO" "LIMITE" "CONEX" "ESTADO"
    printf '  %s\n' "───────────────────────────────────────────────────────────────────────────"

    local i=1
    for u in "${users[@]}"; do
        exp="$(movi_expira "$u")"
        uso="$(movi_human "${MOVI_USO[$u]:-0}")"
        lim="${MOVI_LIM[$u]:-0}"
        if [[ "$lim" == "0" ]]; then lim="ilimitado"; else lim="$(movi_human "$lim")"; fi
        conn="${MOVI_CONEXIONES[$u]:-0}"
        connlim="${MOVI_CONNLIM[$u]:-0}"
        [[ "$connlim" == "0" ]] && connlim="∞" || connlim="$conn/$connlim"
        [[ "$connlim" == "∞" ]] && conn="$conn"
        est="$(movi_estado_cuenta "$u" "$exp")"
        printf '  %-3d %-16s %-12s %-11s %-11s %-6s %s\n' \
            "$i" "$u" "$exp" "$uso" "$lim" "$connlim" "$est"
        ((i++))
    done
}

# ── Resumen de entrega ──────────────────────────────────────
movi_resumen_cuenta() {
    local u="$1" p="$2" dias="$3" gb="$4" conns="$5"
    local exp lim
    exp="$(movi_expira "$u")"
    if [[ "$(movi_gb_a_bytes "$gb")" == "0" ]]; then lim="ilimitado"; else lim="${gb} GB"; fi

    printf '\n'
    printf '%s╔══════════════════════════════════════════════════════╗%s\n' "$GREEN" "$RESET"
    printf '%s║%s            CUENTA SSH CREADA / ACTUALIZADA          %s║%s\n' "$GREEN" "$WHITE" "$GREEN" "$RESET"
    printf '%s╚══════════════════════════════════════════════════════╝%s\n' "$GREEN" "$RESET"
    printf '  Usuario     : %s%s%s\n' "$WHITE" "$u" "$RESET"
    printf '  Contrasena  : %s%s%s\n' "$WHITE" "$p" "$RESET"
    printf '  Servidor    : %s%s%s\n' "$WHITE" "$(movi_ip)" "$RESET"
    printf '  Puerto SSH  : %s%s%s\n' "$WHITE" "$(movi_ssh_port)" "$RESET"
    printf '  Expira      : %s%s%s\n' "$WHITE" "$exp" "$RESET"
    printf '  Consumo max : %s%s%s\n' "$WHITE" "$lim" "$RESET"
    if [[ "$conns" == "0" ]]; then
        printf '  Conexiones  : %silimitado%s\n' "$WHITE" "$RESET"
    else
        printf '  Conexiones  : %s%s%s\n' "$WHITE" "$conns" "$RESET"
    fi
    printf '\n'
}
