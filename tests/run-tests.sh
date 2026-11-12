#!/bin/bash
# ============================================================
#  MOVIVIP · GESTOR SSH — batería de pruebas
#
#  Monta un sistema falso (passwd, shadow, useradd, chage, passwd,
#  ss, ps) en un directorio temporal y ejercita el menú completo
#  sin tocar el sistema real ni necesitar root.
#
#      ./tests/run-tests.sh
# ============================================================
set -u

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[1;92m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[1;91m✗\033[0m %s\n' "$1"; }

assert_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (esperado: '$3' | obtenido: '$2')"; fi
}
assert_contains() {
    if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (no contiene '$3')"; fi
}
assert_not_contains() {
    if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (contiene '$3')"; fi
}
assert_file() {
    if [[ -e "$2" ]]; then ok "$1"; else bad "$1 (no existe $2)"; fi
}
assert_no_file() {
    if [[ ! -e "$2" ]]; then ok "$1"; else bad "$1 (existe $2)"; fi
}
assert_rc() {
    if [[ "$2" -eq "$3" ]]; then ok "$1"; else bad "$1 (rc esperado $3 | obtenido $2)"; fi
}

# ── Sistema falso ───────────────────────────────────────────
export MOVI_ALLOW_NONROOT=1
export MOVI_NO_COLOR=1
export MOVI_ETC="$TMP/etc"
export MOVI_STATE="$TMP/state"
export MOVI_PASSWD="$TMP/passwd"
export MOVI_SHADOW="$TMP/shadow"
export STUB_DIR="$TMP/stub"
export PATH="$TMP/bin:$PATH"

mkdir -p "$MOVI_ETC" "$MOVI_STATE" "$STUB_DIR/log" "$STUB_DIR/expiry" "$STUB_DIR/locked" "$TMP/bin"

cat > "$MOVI_PASSWD" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
cat > "$MOVI_SHADOW" <<'EOF'
root:$6$fake:19000:0:99999:7:::
daemon:!:19000:0:99999:7:::
nobody:!:19000:0:99999:7:::
EOF
chmod 600 "$MOVI_PASSWD" "$MOVI_SHADOW"

cat > "$MOVI_ETC/config.conf" <<'EOF'
DIAS_DEFECTO=30
GB_DEFECTO=0
CONEXIONES_DEFECTO=0
BLOQUEAR_AL_EXCEDER=1
SHELL_USUARIO=/bin/bash
PUERTO_SSH=22
IP_PUBLICA=10.10.10.10
EOF

# ── Stubs ───────────────────────────────────────────────────
cat > "$TMP/bin/useradd" <<'STUB'
#!/bin/bash
home=""; shell="/bin/bash"; user=""
while (( $# )); do
    case "$1" in
        -m|-M) shift ;;
        -d) home="$2"; shift 2 ;;
        -s) shell="$2"; shift 2 ;;
        -G|-g|-u|-c|-e|-p|-k|-b) shift 2 ;;
        -*) shift ;;
        *) user="$1"; shift ;;
    esac
done
if grep -q "^$user:" "$MOVI_PASSWD"; then echo "useradd: el usuario ya existe" >&2; exit 9; fi
uid=$(( 2000 + $(wc -l < "$MOVI_PASSWD") ))
printf '%s:x:%d:%d::%s:%s\n' "$user" "$uid" "$uid" "${home:-/home/$user}" "$shell" >> "$MOVI_PASSWD"
printf '%s:!:19000:0:99999:7:::\n' "$user" >> "$MOVI_SHADOW"
[[ -n "$home" ]] && mkdir -p "$home"
echo "useradd $user" >> "$STUB_DIR/log/useradd"
exit 0
STUB

cat > "$TMP/bin/usermod" <<'STUB'
#!/bin/bash
hash=""; user=""
while (( $# )); do
    case "$1" in
        -p) hash="$2"; shift 2 ;;
        -e) shift 2 ;;
        -*) shift ;;
        *) user="$1"; shift ;;
    esac
done
if [[ -n "$hash" && -n "$user" ]]; then
    awk -F: -v OFS=: -v u="$user" -v h="$hash" '$1==u { $2=h } { print }' "$MOVI_SHADOW" > "$MOVI_SHADOW.tmp"
    mv -f "$MOVI_SHADOW.tmp" "$MOVI_SHADOW"
fi
echo "usermod $user" >> "$STUB_DIR/log/usermod"
exit 0
STUB

cat > "$TMP/bin/userdel" <<'STUB'
#!/bin/bash
borrar_home=0; user=""
while (( $# )); do
    case "$1" in
        -r) borrar_home=1; shift ;;
        -f|-R|-Z) shift ;;
        -*) shift ;;
        *) user="$1"; shift ;;
    esac
done
home="$(awk -F: -v u="$user" '$1==u { print $6 }' "$MOVI_PASSWD")"
grep -q "^$user:" "$MOVI_PASSWD" || { echo "userdel: no existe" >&2; exit 6; }
awk -F: -v u="$user" '$1!=u' "$MOVI_PASSWD" > "$MOVI_PASSWD.tmp"; mv -f "$MOVI_PASSWD.tmp" "$MOVI_PASSWD"
awk -F: -v u="$user" '$1!=u' "$MOVI_SHADOW" > "$MOVI_SHADOW.tmp"; mv -f "$MOVI_SHADOW.tmp" "$MOVI_SHADOW"
(( borrar_home )) && [[ -n "$home" && "$home" != "/" ]] && rm -rf "$home"
echo "userdel $user" >> "$STUB_DIR/log/userdel"
exit 0
STUB

cat > "$TMP/bin/chage" <<'STUB'
#!/bin/bash
exp=""; listar=0; user=""
while (( $# )); do
    case "$1" in
        -l) listar=1; shift ;;
        -E) exp="$2"; shift 2 ;;
        -m|-M|-I|-W) shift 2 ;;
        -*) shift ;;
        *) user="$1"; shift ;;
    esac
done
if (( listar )); then
    valor="never"
    [[ -f "$STUB_DIR/expiry/$user" ]] && valor="$(cat "$STUB_DIR/expiry/$user")"
    printf 'Last password change                                    : Jan 01, 2026\n'
    printf 'Password expires                                        : never\n'
    printf 'Password inactive                                       : never\n'
    printf 'Account expires                                         : %s\n' "$valor"
    printf 'Minimum number of days between password change          : 0\n'
    printf 'Maximum number of days between password change          : 99999\n'
    printf 'Number of days of warning before password expires       : 7\n'
    exit 0
fi
if [[ -n "$exp" ]]; then
    if [[ "$exp" == "-1" ]]; then
        rm -f "$STUB_DIR/expiry/$user"
    else
        printf '%s' "$exp" > "$STUB_DIR/expiry/$user"
    fi
fi
exit 0
STUB

cat > "$TMP/bin/passwd" <<'STUB'
#!/bin/bash
case "${1:-}" in
    -l) touch "$STUB_DIR/locked/$2"; echo "passwd: password expiry information changed."; exit 0 ;;
    -u) rm -f "$STUB_DIR/locked/$2"; exit 0 ;;
    -S)
        if [[ -f "$STUB_DIR/locked/$2" ]]; then
            echo "$2 L 01/01/2026 0 99999 7 -1"
        else
            echo "$2 P 01/01/2026 0 99999 7 -1"
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
STUB

cat > "$TMP/bin/pkill" <<'STUB'
#!/bin/bash
echo "pkill $*" >> "$STUB_DIR/log/pkill"
exit 0
STUB

cat > "$TMP/bin/id" <<'STUB'
#!/bin/bash
user="${!#}"
if grep -q "^$user:" "$MOVI_PASSWD"; then
    [[ "${1:-}" == "-u" ]] && awk -F: -v u="$user" '$1==u { print $3 }' "$MOVI_PASSWD"
    exit 0
fi
exit 1
STUB

cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
case "${1:-}" in
    is-active) exit 3 ;;
    is-enabled) exit 1 ;;
    *) exit 0 ;;
esac
STUB

chmod +x "$TMP/bin/"*

# ── Utilidades de prueba ────────────────────────────────────
M() { "$SRC/movi" "$@"; }
MET() { "$MOVI_PYTHON" "$SRC/lib/meter.py" "$@"; }
export MOVI_PYTHON="${MOVI_PYTHON:-python3}"

escribir_muestra() {
    local bytes="$1"
    cat > "$TMP/ss_est.txt" <<EOF
0 0 10.0.0.5:22 1.2.3.4:51000 users:(("sshd",pid=200,fd=4)) uid:0 ino:1 sk:aaaa1
	 ts sack cubic bytes_sent:100 bytes_acked:1000 bytes_received:$bytes
EOF
    cat > "$TMP/ss_listen.txt" <<'EOF'
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=100,fd=3))
EOF
    cat > "$TMP/ps.txt" <<'EOF'
100 1 root sshd sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups
200 100 test1 sshd sshd: test1@pts/0
EOF
}

muestra() {
    MET --collect --ss-file "$TMP/ss_est.txt" --listen-file "$TMP/ss_listen.txt" --ps-file "$TMP/ps.txt" "$@"
}

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  MOVIVIP · GESTOR SSH — pruebas"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Sintaxis ─────────────────────────────────────────────
echo
echo "1) Sintaxis"
for f in "$SRC/movi" "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC"/lib/*.sh "$SRC/tests/run-tests.sh"; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $f"; fi
done
if "$MOVI_PYTHON" -m py_compile "$SRC/lib/meter.py" 2>/dev/null; then ok "python compila"; else bad "python compila"; fi

# ── 2. Comandos básicos ─────────────────────────────────────
echo
echo "2) Comandos básicos"
salida="$(M version 2>&1)"
assert_contains "movi version" "$salida" "movi 1.0.0"
salida="$(M help 2>&1)"
assert_contains "movi help" "$salida" "USO"
assert_contains "movi help muestra add" "$salida" "movi add"
M comando_inexistente >/dev/null 2>&1
assert_rc "comando desconocido devuelve 2" "$?" 2

# ── 3. Crear usuario ────────────────────────────────────────
echo
echo "3) Crear usuario"
salida="$(M add test1 --pass 'Clave123!' --days 30 --gb 100 --conns 2 2>&1)"
rc=$?
assert_rc "add rc=0" "$rc" 0
assert_contains "resumen de cuenta" "$salida" "CUENTA SSH CREADA"
assert_contains "resumen muestra usuario" "$salida" "test1"
grep -q '^test1:' "$MOVI_PASSWD" && ok "usuario en passwd" || bad "usuario en passwd"
assert_eq "contraseña guardada" "$(awk -F= '$1=="test1"{sub(/^[^=]*=/,""); print}' "$MOVI_ETC/passwords.conf")" "Clave123!"
assert_eq "límite GB guardado" "$(awk -F= '$1=="test1"{print $2}' "$MOVI_ETC/limites_consumo.conf")" "107374182400"
assert_eq "límite conexiones guardado" "$(awk -F= '$1=="test1"{print $2}' "$MOVI_ETC/limites_conexiones.conf")" "2"
esperado="$(date -d '+30 days' +%Y-%m-%d)"
assert_eq "expiración +30 días" "$(cat "$STUB_DIR/expiry/test1" 2>/dev/null)" "$esperado"
grep -q '^test1:' "$MOVI_SHADOW" && ok "hash de contraseña aplicado" || bad "hash de contraseña aplicado"

M add test1 --pass otra >/dev/null 2>&1
assert_rc "usuario duplicado rechazado" "$?" 1
M add 'Malo!' --pass x >/dev/null 2>&1
assert_rc "nombre inválido rechazado" "$?" 1
M add test2 --pass x --gb abc >/dev/null 2>&1
assert_rc "GB inválido rechazado" "$?" 1
M add test2 --pass x --conns abc >/dev/null 2>&1
assert_rc "conexiones inválidas rechazadas" "$?" 1
grep -q '^test2:' "$MOVI_PASSWD" && bad "usuario inválido no debe crearse" || ok "usuario inválido no se crea"

salida="$(M add test3 --days 0 2>&1)"
assert_rc "add sin contraseña (no interactivo) rc=0" "$?" 0
pass3="$(awk -F= '$1=="test3"{sub(/^[^=]*=/,""); print}' "$MOVI_ETC/passwords.conf")"
assert_eq "contraseña generada de 16 caracteres" "${#pass3}" 16
assert_eq "días 0 = sin expiración" "$(cat "$STUB_DIR/expiry/test3" 2>/dev/null)" ""

# ── 4. Lista ────────────────────────────────────────────────
echo
echo "4) Lista y consulta"
salida="$(M list 2>&1)"
assert_contains "lista contiene test1" "$salida" "test1"
assert_contains "lista muestra límite 100 GB" "$salida" "100.00 GB"
assert_contains "lista muestra estado ACTIVO" "$salida" "ACTIVO"
salida="$(M list --plain 2>&1)"
assert_contains "lista plana usa separador |" "$salida" "test1|"
salida="$(M usage test1 2>&1)"
assert_contains "usage muestra usuario" "$salida" "test1"
assert_contains "usage muestra límite" "$salida" "100.00 GB"

# ── 5. Medición ─────────────────────────────────────────────
echo
echo "5) Medición de consumo"
escribir_muestra 2000
muestra >/dev/null 2>&1
assert_eq "primera muestra: 3000 bytes" "$(MET --usage-bytes test1)" "3000"
assert_eq "consumo legible" "$(MET --usage test1)" "2.93 KB"
escribir_muestra 4000
muestra >/dev/null 2>&1
assert_eq "segunda muestra acumula solo el delta (5000)" "$(MET --usage-bytes test1)" "5000"
salida="$(MET --dump --ss-file "$TMP/ss_est.txt" --listen-file "$TMP/ss_listen.txt" --ps-file "$TMP/ps.txt")"
assert_contains "dump incluye test1" "$salida" "test1|5000|1"
salida="$(MET --online --ss-file "$TMP/ss_est.txt" --listen-file "$TMP/ss_listen.txt" --ps-file "$TMP/ps.txt")"
assert_eq "online cuenta 1 sesión" "$salida" "test1|1"

# Conexión que no es SSH (puerto 9999) no debe contarse.
cat > "$TMP/ss_est.txt" <<'EOF'
0 0 10.0.0.5:9999 1.2.3.4:51000 users:(("sshd",pid=200,fd=4)) uid:0 ino:1 sk:bbbb2
	 ts sack cubic bytes_acked:100 bytes_received:100
EOF
muestra >/dev/null 2>&1
assert_eq "conexión no-SSH ignorada" "$(MET --usage-bytes test1)" "5000"

# ── 6. Bloqueo automático por límite ────────────────────────
echo
echo "6) Bloqueo automático por consumo"
printf 'test1=1000\n' > "$MOVI_ETC/limites_consumo.conf"
escribir_muestra 2000
muestra >/dev/null 2>&1
assert_file "bloqueado al superar límite" "$STUB_DIR/locked/test1"
assert_contains "motivo registrado" "$(cat "$MOVI_ETC/suspendidos.conf")" "test1|"
salida="$(M list 2>&1)"
assert_contains "lista muestra BLOQUEADO" "$salida" "BLOQUEADO"

printf 'test1=0\n' > "$MOVI_ETC/limites_consumo.conf"
MET --enforce >/dev/null 2>&1
assert_no_file "desbloqueado al quitar el límite" "$STUB_DIR/locked/test1"
assert_not_contains "motivo borrado" "$(cat "$MOVI_ETC/suspendidos.conf" 2>/dev/null)" "test1"

# ── 7. Editar ───────────────────────────────────────────────
echo
echo "7) Editar / renovar"
M edit test1 --days 10 --gb 50 --conns 3 >/dev/null 2>&1
assert_rc "edit rc=0" "$?" 0
assert_eq "nueva expiración" "$(cat "$STUB_DIR/expiry/test1")" "$(date -d '+10 days' +%Y-%m-%d)"
assert_eq "nuevo límite GB" "$(awk -F= '$1=="test1"{print $2}' "$MOVI_ETC/limites_consumo.conf")" "53687091200"
assert_eq "nuevo límite conexiones" "$(awk -F= '$1=="test1"{print $2}' "$MOVI_ETC/limites_conexiones.conf")" "3"

M block test1 >/dev/null 2>&1
assert_file "block bloquea" "$STUB_DIR/locked/test1"
M unblock test1 >/dev/null 2>&1
assert_no_file "unblock desbloquea" "$STUB_DIR/locked/test1"

# ── 8. Reset ────────────────────────────────────────────────
echo
echo "8) Reiniciar contador"
M reset test1 --yes >/dev/null 2>&1
assert_rc "reset rc=0" "$?" 0
assert_eq "consumo a cero" "$(MET --usage-bytes test1)" "0"

# ── 9. Eliminar ─────────────────────────────────────────────
echo
echo "9) Eliminar usuario"
M del test1 --yes >/dev/null 2>&1
assert_rc "del rc=0" "$?" 0
grep -q '^test1:' "$MOVI_PASSWD" && bad "usuario eliminado de passwd" || ok "usuario eliminado de passwd"
grep -q '^test1=' "$MOVI_ETC/passwords.conf" && bad "contraseña eliminada" || ok "contraseña eliminada"
grep -q '^test1=' "$MOVI_ETC/limites_consumo.conf" && bad "límite eliminado" || ok "límite eliminado"
grep -q '^test1=' "$MOVI_ETC/limites_conexiones.conf" && bad "límite conexiones eliminado" || ok "límite conexiones eliminado"
assert_not_contains "estado del medidor limpio" "$(MET --dump)" "test1"
M del test1 --yes >/dev/null 2>&1
assert_rc "eliminar usuario inexistente devuelve 2" "$?" 2
M del test3 --yes >/dev/null 2>&1
assert_rc "segundo usuario eliminado" "$?" 0

# ── 10. Estado ──────────────────────────────────────────────
echo
echo "10) Estado del medidor"
salida="$(M status 2>&1)"
assert_contains "status muestra versión" "$salida" "version"
assert_contains "status muestra medidor" "$salida" "medidor"
assert_contains "status muestra bloqueo_auto" "$salida" "bloqueo_auto"

# ── 11. Instalador en rutas temporales ──────────────────────
echo
echo "11) Instalador (rutas temporales)"
"$SRC/install.sh" --prefix "$TMP/opt" --bindir "$TMP/bin-inst" \
    --etc "$TMP/etc-inst" --state "$TMP/state-inst" \
    --no-systemd --no-desktop > "$TMP/install.log" 2>&1
assert_rc "install.sh rc=0" "$?" 0
assert_file "programa instalado" "$TMP/opt/movi"
assert_file "comando movi instalado" "$TMP/bin-inst/movi"
assert_file "desinstalador instalado" "$TMP/opt/uninstall.sh"
assert_file "configuración creada" "$TMP/etc-inst/config.conf"
salida="$("$TMP/bin-inst/movi" version 2>&1)"
assert_contains "comando instalado responde" "$salida" "movi 1.0.0"
"$TMP/bin-inst/movi" add instalado --pass 'Clave123!' --days 5 --gb 10 >/dev/null 2>&1
assert_rc "comando instalado crea usuario" "$?" 0

# La instalación con rutas propias debe seguir siéndolo sin variables de entorno.
salida="$(env -u MOVI_ETC -u MOVI_STATE MOVI_ALLOW_NONROOT=1 MOVI_NO_COLOR=1 "$TMP/bin-inst/movi" status 2>&1)"
assert_contains "comando instalado usa su propia config" "$salida" "$TMP/etc-inst"
salida="$(env -u MOVI_ETC -u MOVI_STATE python3 "$TMP/opt/lib/meter.py" --status 2>&1)"
assert_contains "medidor instalado usa su propio estado" "$salida" "estado=$TMP/state-inst"

"$SRC/uninstall.sh" --prefix "$TMP/opt" --bindir "$TMP/bin-inst" \
    --etc "$TMP/etc-inst" --state "$TMP/state-inst" --yes >/dev/null 2>&1
assert_rc "uninstall.sh rc=0" "$?" 0
assert_no_file "programa eliminado" "$TMP/opt/movi"
assert_no_file "comando eliminado" "$TMP/bin-inst/movi"
assert_file "configuración conservada sin --purge" "$TMP/etc-inst/config.conf"

# ── 12. Menú interactivo (entrada simulada) ─────────────────
echo
echo "12) Menú interactivo"
salida="$(printf '0\n' | M 2>&1)"
assert_rc "menú sale con 0" "$?" 0
assert_contains "menú muestra opciones" "$salida" "Crear usuario SSH"
assert_contains "menú muestra consumo GB" "$salida" "consumo (GB)"

# Alta guiada por el menú: [1] Crear -> [2] Manual -> usuario/clave/días/GB/conexiones.
salida="$(printf '1\n2\nmenu1\n\n15\n5\n1\n\n0\n' | M 2>&1)"
assert_rc "menú: crear usuario rc=0" "$?" 0
assert_contains "menú: resumen de cuenta" "$salida" "CUENTA SSH CREADA"
grep -q '^menu1:' "$MOVI_PASSWD" && ok "menú: usuario creado" || bad "menú: usuario creado"
assert_eq "menú: límite 5 GB" "$(awk -F= '$1=="menu1"{print $2}' "$MOVI_ETC/limites_consumo.conf")" "5368709120"
assert_eq "menú: límite 1 conexión" "$(awk -F= '$1=="menu1"{print $2}' "$MOVI_ETC/limites_conexiones.conf")" "1"
assert_eq "menú: expiración 15 días" "$(cat "$STUB_DIR/expiry/menu1" 2>/dev/null)" "$(date -d '+15 days' +%Y-%m-%d)"

# Alta aleatoria por el menú: [1] Crear -> [1] Aleatorio -> valores por defecto.
antes="$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody"' "$MOVI_PASSWD" | wc -l)"
salida="$(printf '1\n1\n\n\n\n\n0\n' | M 2>&1)"
despues="$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody"' "$MOVI_PASSWD" | wc -l)"
assert_rc "menú: alta aleatoria rc=0" "$?" 0
assert_eq "menú: alta aleatoria crea un usuario" "$despues" "$((antes + 1))"
assert_contains "menú: muestra credenciales generadas" "$salida" "Contrasena"

# ── Resumen ─────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════"
if (( FAIL == 0 )); then
    printf '  \033[1;92mRESULTADO: %d pruebas correctas, 0 fallos\033[0m\n' "$PASS"
else
    printf '  \033[1;91mRESULTADO: %d correctas, %d FALLOS\033[0m\n' "$PASS" "$FAIL"
fi
echo "═══════════════════════════════════════════════════════════════"
(( FAIL == 0 ))
