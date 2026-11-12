# MOVIVIP · GESTOR SSH

Menú independiente para **crear, eliminar y editar usuarios SSH** con
**medición de consumo en GB por usuario**. Se instala con un solo comando y
se abre escribiendo:

```bash
movi
```

No depende del panel MoviVIP: usa su propia base de datos y su propio medidor.

---

## 1. Instalación

```bash
cd ~/Escritorio/MOVIVIP-GESTOR-SSH
sudo ./install.sh
```

El instalador:

- copia el programa a `/opt/movi-ssh`
- crea el comando `/usr/local/bin/movi`
- crea la configuración en `/etc/movi-ssh/config.conf`
- guarda el estado del medidor en `/var/lib/movi-ssh`
- instala y activa `movi-meter.timer` (una muestra cada 60 segundos)
- añade el acceso directo “MOVIVIP Gestor SSH” al menú de aplicaciones y al
  escritorio

Para desinstalar:

```bash
sudo /opt/movi-ssh/uninstall.sh           # conserva configuración y consumo
sudo /opt/movi-ssh/uninstall.sh --purge   # borra todo
```

---

## 2. Uso

### Menú interactivo

```bash
movi
```

```
[1] Crear usuario SSH
[2] Eliminar usuario SSH
[3] Editar / renovar usuario
[4] Lista de usuarios y consumo (GB)
[5] Detalle de consumo de un usuario
[6] Conexiones SSH activas
[7] Reiniciar contador de consumo
[8] Estado del medidor
[0] Salir
```

### Comandos directos (scripts / automatización)

```bash
movi add juan --pass 'Clave123!' --days 30 --gb 100 --conns 2
movi add --random
movi list
movi list --plain
movi usage juan
movi reset juan
movi online
movi edit juan --days 60 --gb 200
movi block juan
movi unblock juan
movi del juan --yes
movi status
```

Opciones de `add` / `edit`:

| Opción | Significado | Defecto |
|---|---|---|
| `--pass CLAVE` | contraseña (si falta se genera) | aleatoria |
| `--days N` | días de vigencia (`0` = sin límite) | 30 |
| `--gb N` | consumo máximo en GB (`0` = ilimitado) | 0 |
| `--conns N` | conexiones simultáneas (`0` = ilimitado) | 0 |
| `--random` | usuario y contraseña aleatorios | — |

`del` acepta `--keep-home` (conservar `/home/usuario`) y `--yes`
(confirmación no interactiva).

---

## 3. Cómo se mide el consumo

El medidor (`lib/meter.py`) corre cada minuto desde systemd y:

1. Lee los sockets SSH establecidos con `ss -i` y sus contadores
   `bytes_acked` + `bytes_received`.
2. Atribuye cada socket a su cuenta cruzando el PID de la sesión `sshd`
   con el usuario autenticado (`ps`).
3. Acumula **solo el incremento** de cada socket en
   `/var/lib/movi-ssh/consumo.json`, con bloqueo entre procesos para que dos
   muestras simultáneas no se pisen.

Con `BLOQUEAR_AL_EXCEDER=1` (valor por defecto), cuando una cuenta alcanza su
límite se bloquea automáticamente (`passwd -l`) y se desbloquea sola si el
límite se amplía o el contador se reinicia.

Comandos internos del medidor (útiles para depurar):

```bash
python3 /opt/movi-ssh/lib/meter.py --usage juan
python3 /opt/movi-ssh/lib/meter.py --dump
python3 /opt/movi-ssh/lib/meter.py --status
python3 /opt/movi-ssh/lib/meter.py --collect
```

---

## 4. Configuración

`/etc/movi-ssh/config.conf`:

```ini
DIAS_DEFECTO=30           # días al crear una cuenta
GB_DEFECTO=0              # consumo máximo por defecto (0 = ilimitado)
CONEXIONES_DEFECTO=0      # conexiones simultáneas por defecto
BLOQUEAR_AL_EXCEDER=1     # 1 = bloquear al superar el límite
SHELL_USUARIO=/bin/bash
PUERTO_SSH=               # vacío = leer /etc/ssh/sshd_config
IP_PUBLICA=               # vacío = IP local del servidor
```

Después de cambiarla no hay que reiniciar nada: el menú y el medidor leen el
archivo en cada ejecución.

---

## 5. Archivos

```
/opt/movi-ssh/                 programa
/opt/movi-ssh/movi             lanzador (enlazado como /usr/local/bin/movi)
/opt/movi-ssh/lib/common.sh    rutas, colores, validaciones
/opt/movi-ssh/lib/accounts.sh  creación, borrado, límites
/opt/movi-ssh/lib/menu.sh      menú interactivo
/opt/movi-ssh/lib/cli.sh       comandos directos
/opt/movi-ssh/lib/meter.py     medidor de consumo
/opt/movi-ssh/lib/paths.conf   rutas fijadas por el instalador (medidor)
/opt/movi-ssh/lib/paths.sh     rutas fijadas por el instalador (menú)
/opt/movi-ssh/uninstall.sh     desinstalador
/etc/movi-ssh/config.conf      configuración
/etc/movi-ssh/passwords.conf   contraseñas guardadas (modo 600)
/etc/movi-ssh/limites_consumo.conf
/etc/movi-ssh/limites_conexiones.conf
/etc/movi-ssh/suspendidos.conf
/var/lib/movi-ssh/consumo.json estado acumulado del medidor
```

---

## 6. Pruebas

La batería completa no necesita root ni toca el sistema real: monta usuarios,
`ss` y `ps` falsos en un directorio temporal.

```bash
./tests/run-tests.sh
```

Cubre: sintaxis, creación, validaciones, contraseñas, expiración, límites,
medición y acumulación de bytes, bloqueo/desbloqueo automático, edición,
reinicio de contador, eliminación, instalación y desinstalación en rutas
temporales y arranque del menú.

---

## 7. Requisitos

- Linux con `bash`, `python3`, `ss` (iproute2), `ps` (procps), `openssl`
- `useradd`, `usermod`, `userdel`, `chage`, `passwd`
- systemd (recomendado; si no existe, el instalador imprime la línea de cron)

> El medidor atribuye el tráfico de sesiones SSH (y `sshd-session`). Los
> protocolos extra del panel MoviVIP (Xray, WireGuard, etc.) no forman parte
> de este medidor independiente.
