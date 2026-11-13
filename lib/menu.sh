#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — menú interactivo
#  Requiere common.sh y accounts.sh cargados.
# ============================================================

movi_menu_cabecera() {
    local titulo="MOVIVIP · GESTOR SSH  v$MOVI_VERSION"
    local sub="Crear · Eliminar · Editar · Consumo GB"
    printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$CYAN" "$RESET"
    printf '%s║%s  %-60s%s║%s\n' "$CYAN" "$WHITE" "$titulo" "$CYAN" "$RESET"
    printf '%s║%s  %-60s%s║%s\n' "$CYAN" "$GRAY" "$sub" "$CYAN" "$RESET"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$CYAN" "$RESET"
}

movi_menu_pedir_usuario() {
    local prompt="${1:-Usuario}"
    local u
    read -rp "  $prompt: " u || return 1
    printf '%s' "$u"
}

# ── 1. Crear ────────────────────────────────────────────────
movi_wizard_crear() {
    movi_clear
    movi_titulo "CREAR USUARIO SSH"

    local modo u p dias gb conns
    printf '  [1] Aleatorio   (usuario y contraseña generados)\n'
    printf '  [2] Manual      (escribir usuario y contraseña)\n\n'
    read -rp "  Modo [2]: " modo || return 0

    if [[ "$modo" == "1" ]]; then
        u="$(movi_usuario_aleatorio)" || { movi_err "No se pudo generar el usuario."; return 1; }
        p="$(movi_pass_aleatoria)" || { movi_err "No se pudo generar la contraseña."; return 1; }
        printf '\n  Usuario generado   : %s%s%s\n' "$WHITE" "$u" "$RESET"
        printf '  Contraseña generada: %s%s%s\n' "$WHITE" "$p" "$RESET"
    else
        read -rp "  Usuario: " u || return 0
        [[ -z "$u" ]] && { movi_err "El usuario es obligatorio."; return 1; }
        read -rsp "  Contraseña (Enter = generar): " p || return 0
        printf '\n'
        [[ -z "$p" ]] && p="$(movi_pass_aleatoria)"
    fi

    read -rp "  Días de vigencia [$DIAS_DEFECTO] (0 = sin límite): " dias || return 0
    dias="${dias:-$DIAS_DEFECTO}"

    read -rp "  Consumo máximo en GB [$GB_DEFECTO] (0 = ilimitado): " gb || return 0
    gb="${gb:-$GB_DEFECTO}"

    read -rp "  Conexiones simultáneas [$CONEXIONES_DEFECTO] (0 = ilimitado): " conns || return 0
    conns="${conns:-$CONEXIONES_DEFECTO}"

    printf '\n'
    if movi_crear_usuario "$u" "$p" "$dias" "$gb" "$conns"; then
        movi_resumen_cuenta "$u" "$p" "$dias" "$gb" "$conns"
    fi
}

# ── 2. Eliminar ─────────────────────────────────────────────
movi_wizard_eliminar() {
    movi_clear
    movi_titulo "ELIMINAR USUARIO SSH"

    local -a users=()
    mapfile -t users < <(movi_usuarios_sistema)
    if (( ${#users[@]} == 0 )); then
        movi_warn "No hay usuarios SSH para eliminar."
        return 0
    fi

    movi_cargar_uso
    local i=1 u
    for u in "${users[@]}"; do
        printf '  [%d] %-16s expira: %-12s consumo: %s\n' \
            "$i" "$u" "$(movi_expira "$u")" "$(movi_human "${MOVI_USO[$u]:-0}")"
        ((i++))
    done
    printf '\n  Ejemplos: 1   ·   1 2 3   ·   0 = cancelar\n'
    local sel
    read -rp "  Seleccione: " sel || return 0
    [[ "$sel" == "0" || -z "$sel" ]] && return 0

    local -a objetivo=()
    local n
    for n in $sel; do
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#users[@]} )); then
            objetivo+=("${users[$((n - 1))]}")
        else
            movi_warn "Se ignora la selección inválida: $n"
        fi
    done
    (( ${#objetivo[@]} )) || { movi_err "Selección inválida."; return 1; }

    printf '\n  Se eliminarán: %s\n' "${objetivo[*]}"
    local resp
    read -rp "  ¿Confirma? [s/N]: " resp || return 0
    [[ "$resp" =~ ^[sSyY]$ ]] || { movi_info "Cancelado."; return 0; }

    local borrados=0
    for u in "${objetivo[@]}"; do
        if movi_eliminar_usuario "$u" 0; then
            movi_ok "Usuario '$u' eliminado."
            ((borrados++))
        fi
    done
    printf '\n  Total eliminados: %d\n' "$borrados"
}

# ── 3. Editar ───────────────────────────────────────────────
movi_wizard_editar() {
    local u="${1:-}"
    if [[ -z "$u" ]]; then
        movi_clear
        movi_titulo "EDITAR / RENOVAR USUARIO"
        local -a users=()
        mapfile -t users < <(movi_usuarios_sistema)
        if (( ${#users[@]} == 0 )); then
            movi_warn "No hay usuarios SSH registrados."
            return 0
        fi
        local i=1 x
        for x in "${users[@]}"; do
            printf '  [%d] %-16s expira: %s\n' "$i" "$x" "$(movi_expira "$x")"
            ((i++))
        done
        local sel
        read -rp "  Seleccione [0=Salir]: " sel || return 0
        [[ "$sel" == "0" || -z "$sel" ]] && return 0
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#users[@]} )); then
            movi_err "Selección inválida."
            return 1
        fi
        u="${users[$((sel - 1))]}"
    fi

    movi_usuario_existe "$u" || { movi_err "El usuario '$u' no existe."; return 1; }

    while true; do
        movi_clear
        movi_titulo "EDITAR: $u"

        local exp uso lim connlim estado pass
        exp="$(movi_expira "$u")"
        uso="$(movi_uso_humano "$u")"
        lim="$(movi_kv_get "$(movi_archivo_limites)" "$u")"
        [[ -z "$lim" ]] && lim=0
        connlim="$(movi_kv_get "$(movi_archivo_conexiones)" "$u")"
        [[ -z "$connlim" ]] && connlim=0
        estado="$(movi_estado_cuenta "$u" "$exp")"
        pass="$(movi_password_guardada "$u")"

        printf '  Usuario    : %s%s%s\n' "$WHITE" "$u" "$RESET"
        printf '  Expira     : %s\n' "$exp"
        printf '  Consumo    : %s\n' "$uso"
        if [[ "$lim" == "0" ]]; then printf '  Límite GB  : ilimitado\n'; else printf '  Límite GB  : %s\n' "$(movi_human "$lim")"; fi
        if [[ "$connlim" == "0" ]]; then printf '  Conexiones : ilimitado\n'; else printf '  Conexiones : %s\n' "$connlim"; fi
        printf '  Estado     : %s\n' "$estado"
        printf '  Contraseña : %s\n\n' "${pass:-no guardada}"

        printf '  [1] Cambiar contraseña\n'
        printf '  [2] Renovar (días)\n'
        printf '  [3] Límite de consumo (GB)\n'
        printf '  [4] Límite de conexiones\n'
        printf '  [5] Bloquear / desbloquear\n'
        printf '  [6] Reiniciar contador de consumo\n'
        printf '  [0] Volver\n\n'

        local op
        read -rp "  Opción: " op || return 0
        case "$op" in
            1)
                local p1 p2
                read -rsp "  Nueva contraseña: " p1 || continue
                printf '\n'
                read -rsp "  Repetir contraseña: " p2 || continue
                printf '\n'
                if [[ -z "$p1" || "$p1" != "$p2" ]]; then
                    movi_err "Las contraseñas no coinciden o están vacías."
                    movi_pausa; continue
                fi
                if movi_set_password "$u" "$p1"; then
                    movi_ok "Contraseña actualizada."
                else
                    movi_err "No se pudo actualizar la contraseña."
                fi
                movi_pausa
                ;;
            2)
                local d fecha
                read -rp "  Días a renovar [30]: " d || continue
                d="${d:-30}"
                if fecha="$(movi_renovar_usuario "$u" "$d")"; then
                    if [[ "$fecha" == "-1" ]]; then
                        movi_ok "Cuenta sin expiración."
                    else
                        movi_ok "Cuenta renovada hasta: $fecha"
                    fi
                else
                    movi_err "No se pudo renovar (días inválidos)."
                fi
                movi_pausa
                ;;
            3)
                local g
                read -rp "  Nuevo límite en GB [0 = ilimitado]: " g || continue
                g="${g:-0}"
                if movi_limite_consumo "$u" "$g"; then
                    movi_ok "Límite de consumo actualizado."
                else
                    movi_err "GB inválidos: '$g'."
                fi
                movi_pausa
                ;;
            4)
                local c
                read -rp "  Conexiones simultáneas [0 = ilimitado]: " c || continue
                c="${c:-0}"
                if movi_limite_conexiones "$u" "$c"; then
                    movi_ok "Límite de conexiones actualizado."
                else
                    movi_err "Valor inválido: '$c'."
                fi
                movi_pausa
                ;;
            5)
                if [[ "$estado" == BLOQUEADO* ]]; then
                    movi_desbloquear_usuario "$u" && movi_ok "Usuario desbloqueado."
                else
                    movi_bloquear_usuario "$u" manual && movi_ok "Usuario bloqueado."
                fi
                movi_pausa
                ;;
            6)
                movi_reset_consumo "$u" && movi_ok "Contador de consumo reiniciado."
                movi_pausa
                ;;
            0|"") return 0 ;;
            *) movi_err "Opción inválida."; movi_pausa ;;
        esac
    done
}

# ── 4. Lista ────────────────────────────────────────────────
movi_menu_lista() {
    movi_clear
    movi_titulo "USUARIOS SSH Y CONSUMO"
    movi_tabla_usuarios tabla
    printf '\n  %sConsumo medido por el medidor de MOVIVIP (SSH).%s\n' "$GRAY" "$RESET"
}

# ── 5. Consumo de un usuario ────────────────────────────────
movi_menu_consumo() {
    movi_clear
    movi_titulo "DETALLE DE CONSUMO"
    local u
    u="$(movi_menu_pedir_usuario "Usuario")" || return 0
    movi_usuario_existe "$u" || { movi_err "El usuario '$u' no existe."; return 1; }

    local bytes lim pct
    bytes="$(movi_uso_bytes "$u")"
    lim="$(movi_kv_get "$(movi_archivo_limites)" "$u")"
    [[ -z "$lim" ]] && lim=0

    printf '  Usuario : %s%s%s\n' "$WHITE" "$u" "$RESET"
    printf '  Consumo : %s\n' "$(movi_human "$bytes")"
    if [[ "$lim" == "0" ]]; then
        printf '  Límite  : ilimitado\n'
    else
        pct="$(LC_ALL=C awk -v a="$bytes" -v b="$lim" 'BEGIN{ if (b>0) printf "%.1f", a*100/b; else print 0 }')"
        printf '  Límite  : %s (%s%% usado)\n' "$(movi_human "$lim")" "$pct"
    fi

    local resp
    read -rp "  ¿Reiniciar el contador de este usuario? [s/N]: " resp || return 0
    if [[ "$resp" =~ ^[sSyY]$ ]]; then
        movi_reset_consumo "$u" && movi_ok "Contador reiniciado."
    fi
}

# ── 6. Conexiones activas ───────────────────────────────────
movi_menu_online() {
    movi_clear
    movi_titulo "CONEXIONES SSH ACTIVAS"
    local salida
    salida="$("$MOVI_PYTHON" "$MOVI_LIB/meter.py" --online 2>/dev/null)"
    if [[ -z "$salida" ]]; then
        movi_info "Sin conexiones SSH activas en este momento."
        return 0
    fi
    printf '  %-18s %s\n' "USUARIO" "SESIONES"
    printf '  %s\n' "────────────────────────"
    local u c
    while IFS='|' read -r u c; do
        [[ -n "$u" ]] && printf '  %-18s %s\n' "$u" "$c"
    done <<< "$salida"
}

# ── 7. Reiniciar contadores ─────────────────────────────────
movi_menu_reset() {
    movi_clear
    movi_titulo "REINICIAR CONTADOR DE CONSUMO"
    printf '  [1] Un usuario\n'
    printf '  [2] Todos los usuarios\n'
    printf '  [0] Volver\n\n'
    local op
    read -rp "  Opción: " op || return 0
    case "$op" in
        1)
            local u
            u="$(movi_menu_pedir_usuario "Usuario")" || return 0
            movi_usuario_existe "$u" || { movi_err "El usuario '$u' no existe."; return 1; }
            local resp
            read -rp "  ¿Reiniciar el consumo de '$u'? [s/N]: " resp || return 0
            if [[ "$resp" =~ ^[sSyY]$ ]]; then
                movi_reset_consumo "$u" && movi_ok "Contador de '$u' reiniciado."
            fi
            ;;
        2)
            local resp
            read -rp "  ¿Reiniciar el consumo de TODOS? [s/N]: " resp || return 0
            if [[ "$resp" =~ ^[sSyY]$ ]]; then
                movi_reset_consumo all && movi_ok "Contadores reiniciados."
            fi
            ;;
        *) return 0 ;;
    esac
}

# ── 8. Estado del medidor ───────────────────────────────────
movi_menu_estado() {
    movi_clear
    movi_titulo "ESTADO DEL MEDIDOR"
    local timer="no disponible"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet movi-meter.timer 2>/dev/null; then
            timer="activo"
        else
            timer="inactivo"
        fi
    fi
    local upd
    upd="$("$MOVI_PYTHON" "$MOVI_LIB/meter.py" --status 2>/dev/null | awk -F= '$1=="actualizado"{print $2}')"
    printf '  Versión        : %s\n' "$MOVI_VERSION"
    printf '  Instalado en   : %s\n' "$MOVI_HOME"
    printf '  Configuración  : %s\n' "$MOVI_ETC"
    printf '  Estado         : %s\n' "$MOVI_STATE"
    printf '  Medidor        : %s\n' "$timer"
    if [[ -n "$upd" && "$upd" != "0" ]]; then
        printf '  Última muestra : %s\n' "$(date -d "@$upd" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$upd")"
    else
        printf '  Última muestra : sin datos\n'
    fi
    printf '  Bloqueo auto   : %s\n' "$BLOQUEAR_AL_EXCEDER"
}

# ── Menú principal ──────────────────────────────────────────
movi_menu() {
    while true; do
        movi_clear
        movi_menu_cabecera
        printf '\n'
        printf '  %s[1]%s Crear usuario SSH\n' "$GREEN" "$RESET"
        printf '  %s[2]%s Eliminar usuario SSH\n' "$GREEN" "$RESET"
        printf '  %s[3]%s Editar / renovar usuario\n' "$GREEN" "$RESET"
        printf '  %s[4]%s Lista de usuarios y consumo (GB)\n' "$GREEN" "$RESET"
        printf '  %s[5]%s Detalle de consumo de un usuario\n' "$GREEN" "$RESET"
        printf '  %s[6]%s Conexiones SSH activas\n' "$GREEN" "$RESET"
        printf '  %s[7]%s Reiniciar contador de consumo\n' "$GREEN" "$RESET"
        printf '  %s[8]%s Estado del medidor\n' "$GREEN" "$RESET"
        printf '  %s[0]%s Salir\n\n' "$RED" "$RESET"

        local op
        read -rp "  Opción: " op || return 0
        case "$op" in
            1) movi_wizard_crear; movi_pausa ;;
            2) movi_wizard_eliminar; movi_pausa ;;
            3) movi_wizard_editar; movi_pausa ;;
            4) movi_menu_lista; movi_pausa ;;
            5) movi_menu_consumo; movi_pausa ;;
            6) movi_menu_online; movi_pausa ;;
            7) movi_menu_reset; movi_pausa ;;
            8) movi_menu_estado; movi_pausa ;;
            0|q|Q|"") return 0 ;;
            *) movi_err "Opción inválida."; sleep 1 ;;
        esac
    done
}
