#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — interfaz de comandos
#  Requiere common.sh, accounts.sh y menu.sh cargados.
# ============================================================

movi_ayuda() {
    cat <<'AYUDA'
MOVIVIP · GESTOR SSH — crear, eliminar y medir consumo de usuarios SSH

USO
  movi                          Menú interactivo
  movi <comando> [opciones]     Modo directo (scripts / automatización)

COMANDOS
  add [usuario]                 Crear usuario SSH
      --pass CLAVE              Contraseña (si falta, se genera o se pregunta)
      --days N                  Días de vigencia (0 = sin límite)   [30]
      --gb N                    Consumo máximo en GB (0 = ilimitado) [0]
      --conns N                 Conexiones simultáneas (0 = ilimitado) [0]
      --random                  Genera usuario y contraseña aleatorios

  del USUARIO [--keep-home] [--yes]
                                Eliminar usuario (cierra sus sesiones)
  edit USUARIO                  Editar / renovar (menú)
      --pass CLAVE --days N --gb N --conns N
  list [--plain]                Lista usuarios, expiración, consumo y estado
  usage [USUARIO]               Consumo en GB (sin usuario: todos)
  reset USUARIO|all [--yes]     Reiniciar contador de consumo
  online                        Conexiones SSH activas
  block USUARIO                 Bloquear cuenta
  unblock USUARIO               Desbloquear cuenta
  status                        Estado del medidor y del servicio
  help | version

EJEMPLOS
  movi add juan --pass 'Clave123!' --days 30 --gb 100 --conns 2
  movi add --random
  movi list
  movi usage juan
  movi reset juan
  movi del juan --yes

El medidor corre cada 15 segundos por systemd y acumula el tráfico de cada
sesión SSH. Si BLOQUEAR_AL_EXCEDER=1 (config.conf), la cuenta se bloquea
automáticamente al alcanzar su límite y se desbloquea al ampliarlo.
AYUDA
}

movi_cmd_add() {
    local user="" pass="" dias="$DIAS_DEFECTO" gb="$GB_DEFECTO"
    local conns="$CONEXIONES_DEFECTO" aleatorio=0

    if (( $# == 0 )) && [[ -t 0 ]]; then
        movi_wizard_crear
        return $?
    fi

    while (( $# )); do
        case "$1" in
            --pass)   pass="${2:-}"; shift 2 ;;
            --days)   dias="${2:-}"; shift 2 ;;
            --gb)     gb="${2:-}"; shift 2 ;;
            --conns)  conns="${2:-}"; shift 2 ;;
            --random) aleatorio=1; shift ;;
            -h|--help) movi_ayuda; return 0 ;;
            -*) movi_err "Opción desconocida: $1"; return 2 ;;
            *)
                if [[ -z "$user" ]]; then user="$1"; else movi_err "Sobra el argumento: $1"; return 2; fi
                shift
                ;;
        esac
    done

    if [[ "$aleatorio" == "1" || -z "$user" ]]; then
        user="$(movi_usuario_aleatorio)" || { movi_err "No se pudo generar el usuario."; return 1; }
    fi

    if [[ -z "$pass" ]]; then
        if [[ -t 0 ]]; then
            read -rsp "  Contraseña para '$user' (Enter = generar): " pass || return 1
            printf '\n'
        fi
        [[ -z "$pass" ]] && pass="$(movi_pass_aleatoria)"
    fi

    if ! movi_crear_usuario "$user" "$pass" "$dias" "$gb" "$conns"; then
        return 1
    fi

    movi_resumen_cuenta "$user" "$pass" "$dias" "$gb" "$conns"
    return 0
}

movi_cmd_del() {
    local user="" keep=0 yes=0
    while (( $# )); do
        case "$1" in
            --keep-home) keep=1; shift ;;
            --yes|-y) yes=1; shift ;;
            -h|--help) movi_ayuda; return 0 ;;
            -*) movi_err "Opción desconocida: $1"; return 2 ;;
            *)
                if [[ -z "$user" ]]; then user="$1"; else movi_err "Sobra el argumento: $1"; return 2; fi
                shift
                ;;
        esac
    done

    [[ -n "$user" ]] || { movi_err "Indique el usuario a eliminar: movi del USUARIO"; return 2; }
    movi_usuario_existe "$user" || { movi_err "El usuario '$user' no existe."; return 2; }

    if [[ "$yes" != "1" ]]; then
        if [[ -t 0 ]]; then
            local resp
            read -rp "  ¿Eliminar definitivamente a '$user'? [s/N]: " resp || return 1
            [[ "$resp" =~ ^[sSyY]$ ]] || { movi_info "Cancelado."; return 1; }
        else
            movi_err "Modo no interactivo: use --yes para confirmar."
            return 2
        fi
    fi

    movi_eliminar_usuario "$user" "$keep" || return 1
    movi_ok "Usuario '$user' eliminado."
}

movi_cmd_edit() {
    local user="${1:-}"
    if [[ -z "$user" || "$user" == -* ]]; then
        movi_wizard_editar
        return $?
    fi
    shift

    if (( $# == 0 )); then
        movi_wizard_editar "$user"
        return $?
    fi

    movi_usuario_existe "$user" || { movi_err "El usuario '$user' no existe."; return 2; }

    local pass="" dias="" gb="" conns="" cambios=0
    while (( $# )); do
        case "$1" in
            --pass)  pass="${2:-}"; shift 2 ;;
            --days)  dias="${2:-}"; shift 2 ;;
            --gb)    gb="${2:-}"; shift 2 ;;
            --conns) conns="${2:-}"; shift 2 ;;
            -h|--help) movi_ayuda; return 0 ;;
            *) movi_err "Opción desconocida: $1"; return 2 ;;
        esac
    done

    if [[ -n "$pass" ]]; then
        movi_set_password "$user" "$pass" || { movi_err "No se pudo cambiar la contraseña."; return 1; }
        movi_ok "Contraseña actualizada."
        cambios=1
    fi
    if [[ -n "$dias" ]]; then
        local fecha
        fecha="$(movi_renovar_usuario "$user" "$dias")" || { movi_err "Días inválidos: '$dias'."; return 1; }
        if [[ "$fecha" == "-1" ]]; then movi_ok "Cuenta sin expiración."; else movi_ok "Cuenta renovada hasta: $fecha"; fi
        cambios=1
    fi
    if [[ -n "$gb" ]]; then
        movi_limite_consumo "$user" "$gb" || { movi_err "GB inválidos: '$gb'."; return 1; }
        movi_ok "Límite de consumo actualizado."
        cambios=1
    fi
    if [[ -n "$conns" ]]; then
        movi_limite_conexiones "$user" "$conns" || { movi_err "Valor inválido: '$conns'."; return 1; }
        movi_ok "Límite de conexiones actualizado."
        cambios=1
    fi

    (( cambios )) || { movi_warn "Sin cambios: indique --pass, --days, --gb o --conns."; return 1; }
    return 0
}

movi_cmd_list() {
    local modo="tabla"
    [[ "${1:-}" == "--plain" ]] && modo="plano"
    movi_tabla_usuarios "$modo"
}

movi_cmd_usage() {
    local user="${1:-}"
    movi_cargar_limites
    if [[ -z "$user" ]]; then
        movi_cargar_uso
        local u
        for u in $(printf '%s\n' "${!MOVI_USO[@]}" | sort); do
            printf '%-18s %s\n' "$u" "$(movi_human "${MOVI_USO[$u]}")"
        done
        return 0
    fi
    movi_usuario_existe "$user" || { movi_err "El usuario '$user' no existe."; return 2; }
    local bytes lim pct
    bytes="$(movi_uso_bytes "$user")"
    lim="${MOVI_LIM[$user]:-0}"
    printf '%-18s %s\n' "Usuario" "$user"
    printf '%-18s %s\n' "Consumo" "$(movi_human "$bytes")"
    if [[ "$lim" == "0" ]]; then
        printf '%-18s %s\n' "Límite" "ilimitado"
    else
        pct="$(LC_ALL=C awk -v a="$bytes" -v b="$lim" 'BEGIN{ printf "%.1f", (b>0 ? a*100/b : 0) }')"
        printf '%-18s %s (%s%%)\n' "Límite" "$(movi_human "$lim")" "$pct"
    fi
}

movi_cmd_reset() {
    local user="${1:-}" yes=0
    shift || true
    while (( $# )); do
        case "$1" in
            --yes|-y) yes=1; shift ;;
            *) movi_err "Opción desconocida: $1"; return 2 ;;
        esac
    done
    [[ -n "$user" ]] || { movi_err "Indique el usuario o 'all'."; return 2; }
    if [[ "$user" != "all" ]]; then
        movi_usuario_existe "$user" || { movi_err "El usuario '$user' no existe."; return 2; }
    fi
    if [[ "$yes" != "1" && -t 0 ]]; then
        local resp
        read -rp "  ¿Reiniciar el consumo de '$user'? [s/N]: " resp || return 1
        [[ "$resp" =~ ^[sSyY]$ ]] || { movi_info "Cancelado."; return 1; }
    fi
    movi_reset_consumo "$user"
    movi_ok "Contador reiniciado: $user"
}

movi_cmd_online() {
    local salida
    salida="$("$MOVI_PYTHON" "$MOVI_LIB/meter.py" --online 2>/dev/null)"
    if [[ -z "$salida" ]]; then
        movi_info "Sin conexiones SSH activas."
        return 0
    fi
    printf '%-18s %s\n' "USUARIO" "SESIONES"
    local u c
    while IFS='|' read -r u c; do
        [[ -n "$u" ]] && printf '%-18s %s\n' "$u" "$c"
    done <<< "$salida"
}

movi_cmd_block() {
    local user="${1:-}"
    [[ -n "$user" ]] || { movi_err "Indique el usuario."; return 2; }
    movi_bloquear_usuario "$user" manual || { movi_err "No se pudo bloquear '$user'."; return 1; }
    movi_ok "Usuario '$user' bloqueado."
}

movi_cmd_unblock() {
    local user="${1:-}"
    [[ -n "$user" ]] || { movi_err "Indique el usuario."; return 2; }
    movi_desbloquear_usuario "$user" || { movi_err "No se pudo desbloquear '$user'."; return 1; }
    movi_ok "Usuario '$user' desbloqueado."
}

movi_cmd_status() {
    local timer="no disponible" upd
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet movi-meter.timer 2>/dev/null; then
            timer="activo"
        else
            timer="inactivo"
        fi
    fi
    upd="$("$MOVI_PYTHON" "$MOVI_LIB/meter.py" --status 2>/dev/null | awk -F= '$1=="actualizado"{print $2}')"

    printf '%-16s %s\n' "version" "$MOVI_VERSION"
    printf '%-16s %s\n' "instalado" "$MOVI_HOME"
    printf '%-16s %s\n' "config" "$MOVI_ETC"
    printf '%-16s %s\n' "estado" "$MOVI_STATE"
    printf '%-16s %s\n' "usuarios" "$(movi_usuarios_sistema | wc -l | tr -d ' ')"
    printf '%-16s %s\n' "medidor" "$timer"
    if [[ -n "$upd" && "$upd" != "0" ]]; then
        printf '%-16s %s\n' "ultima_muestra" "$(date -d "@$upd" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$upd")"
    else
        printf '%-16s %s\n' "ultima_muestra" "sin datos"
    fi
    printf '%-16s %s\n' "bloqueo_auto" "$BLOQUEAR_AL_EXCEDER"
}

# ── Entrada principal ───────────────────────────────────────
movi_main() {
    movi_config_load

    local -a original=("$@")
    local cmd="${1:-menu}"

    case "$cmd" in
        help|-h|--help) movi_ayuda; return 0 ;;
        version|-v|--version) printf 'movi %s\n' "$MOVI_VERSION"; return 0 ;;
    esac

    if ! movi_requiere_root; then
        if [[ -t 0 && -t 1 ]] && command -v sudo >/dev/null 2>&1; then
            exec sudo -- "${MOVI_SELF:-$0}" "${original[@]}"
        fi
        movi_err "Se requieren privilegios de root. Ejecute: sudo movi"
        return 1
    fi

    movi_asegurar_dirs
    [[ $# -gt 0 ]] && shift

    case "$cmd" in
        menu|"")      movi_menu ;;
        add|crear)    movi_cmd_add "$@" ;;
        del|delete|eliminar) movi_cmd_del "$@" ;;
        edit|editar)  movi_cmd_edit "$@" ;;
        list|lista|ls) movi_cmd_list "$@" ;;
        usage|consumo) movi_cmd_usage "$@" ;;
        reset)        movi_cmd_reset "$@" ;;
        online|conectados) movi_cmd_online "$@" ;;
        block|bloquear)   movi_cmd_block "$@" ;;
        unblock|desbloquear) movi_cmd_unblock "$@" ;;
        status|estado) movi_cmd_status "$@" ;;
        *) movi_err "Comando desconocido: $cmd"; printf '\n'; movi_ayuda; return 2 ;;
    esac
}
