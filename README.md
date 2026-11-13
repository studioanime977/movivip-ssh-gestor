# MOVIVIP · GESTOR SSH

Menú independiente para **crear, eliminar y editar usuarios SSH** con **medición de consumo en GB por usuario**. Se instala con un solo comando y se abre escribiendo:

```bash
movi
```

No depende del panel MoviVIP: usa su propia base de datos y su propio medidor.

El medidor reconoce las sesiones por **sshd (puerto 22)** y también por **dropbear (puerto 90)**, así que factura también las conexiones que entran por el panel MoviVIP y las que entran por los puertos **80** y **8443** (los dos terminan en dropbear). Cuenta incluso las apps de VPN que abren canales de reenvío **sin shell** (`ssh -N`), tomando el usuario del registro de autenticación del sistema. Si un usuario supera su límite de conexiones simultáneas (`--conns`), se cortan las más recientes (configurable con `CORTAR_EXCESO_CONEXIONES=1` en `config.conf`).

---

## 1. Instalación rápida (automática)

**Opción 1 - Instalación directa:**
```bash
apt-get update -y && apt-get install -y curl
curl -fsSL -o /root/install.sh https://raw.githubusercontent.com/studioanime977/movivip-ssh-gestor/main/install.sh
chmod +x /root/install.sh
bash /root/install.sh
```

**Opción 2 - Instalación en una línea:**
```bash
apt-get update -y && apt-get install -y curl && curl -fsSL https://raw.githubusercontent.com/studioanime977/movivip-ssh-gestor/main/install.sh | bash
```

El instalador:
- copia el programa a `/opt/movi-ssh`
- crea el comando `/usr/local/bin/movi`
- crea la configuración en `/etc/movi-ssh/config.conf`
- guarda el estado del medidor en `/var/lib/movi-ssh`
- instala y activa `movi-meter.timer` (una muestra cada 15 segundos, para mayor precisión en los GB)
- añade el acceso directo “MOVIVIP Gestor SSH” al menú de aplicaciones y al escritorio

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
