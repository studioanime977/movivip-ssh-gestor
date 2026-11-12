#!/usr/bin/env python3
"""MOVIVIP · GESTOR SSH — medidor de consumo por usuario SSH.

Atribuye a cada cuenta el tráfico de sus sockets SSH leyendo los contadores
que el kernel publica en `ss -i` (bytes_acked + bytes_received) y acumula los
incrementos en un estado JSON protegido con flock.

Uso:
    meter.py --collect              Una muestra + acumulado (lo llama el timer)
    meter.py --usage USER           Consumo legible (ej. 1.25 GB)
    meter.py --usage-bytes USER     Consumo en bytes
    meter.py --dump                 user|bytes|conexiones  (una línea por usuario)
    meter.py --online               user|sesiones activas
    meter.py --reset USER|all       Pone el contador a cero
    meter.py --forget USER          Borra al usuario del estado
    meter.py --status               Resumen clave=valor del estado

Para pruebas o depuración se puede alimentar la entrada con archivos:
    --ss-file FILE --listen-file FILE --ps-file FILE
"""

import argparse
from dataclasses import dataclass
import fcntl
from ipaddress import ip_address
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from typing import Optional


SSHD = {"sshd", "sshd-session"}
OWNER = re.compile(r'\("([^"]+)",pid=(\d+),fd=(\d+)\)')
COOKIE = re.compile(r"\bsk:([0-9a-f]+)\b")
NUMBERS = re.compile(r"\b(bytes_acked|bytes_received):(\d+)\b")
USERNAME = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")
KEEP = 86400  # conservar cookies vistos en el último día


def _env(name, default):
    value = os.environ.get(name, "")
    if value:
        return value
    # Instalación con rutas propias: install.sh deja lib/paths.conf junto a
    # este archivo. El entorno siempre tiene prioridad.
    try:
        for line in Path(__file__).resolve().with_name("paths.conf").read_text(
            errors="replace"
        ).splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            if key.strip() == name and val.strip():
                return val.strip().strip('"').strip("'")
    except OSError:
        pass
    return default


ETC = Path(_env("MOVI_ETC", "/etc/movi-ssh"))
STATE = Path(_env("MOVI_STATE", "/var/lib/movi-ssh"))
PASSWD = Path(_env("MOVI_PASSWD", "/etc/passwd"))
LIMITS = ETC / "limites_consumo.conf"
SUSPEND = ETC / "suspendidos.conf"
CONFIG = ETC / "config.conf"


@dataclass(frozen=True)
class Connection:
    local: tuple
    peer: tuple
    owners: tuple
    cookie: str = ""
    measured: Optional[int] = None


# ── Sistema ────────────────────────────────────────────────
def exec_cmd(args):
    """Ejecuta un comando y devuelve (rc, stdout). Nunca lanza excepción."""
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=20,
            env={**os.environ, "LC_ALL": "C"},
        )
        return result.returncode, result.stdout
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def run(args):
    return exec_cmd(args)[1]


def boot_id():
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        return ""


def config():
    data = {}
    try:
        for line in CONFIG.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return data


def enforcement_enabled():
    value = config().get("BLOQUEAR_AL_EXCEDER", "1").lower()
    return value not in {"0", "no", "off", "false", "nunca"}


# ── Parseo de ss ───────────────────────────────────────────
def endpoint(value):
    host, _, port = value.rpartition(":")
    if not port.isdecimal():
        return None
    host = host.strip("[]").split("%", 1)[0]
    if host != "*":
        try:
            addr = ip_address(host)
            host = str(getattr(addr, "ipv4_mapped", None) or addr)
        except ValueError:
            return None
    return host, int(port)


def tcp_rows(text, listening=False):
    current = None
    numbers = {}
    for line in text.splitlines():
        fields = line.split()
        if not fields:
            continue
        start = 1 if fields[0] in {"ESTAB", "LISTEN"} else 0
        local = endpoint(fields[start + 2]) if len(fields) >= start + 4 else None
        peer = endpoint(fields[start + 3]) if local else None
        if local and (peer or listening):
            if current:
                yield Connection(*current, sum(numbers.values()) if numbers else None)
            cookie = COOKIE.search(line)
            current = (
                local,
                peer or ("*", 0),
                tuple(OWNER.findall(line)),
                cookie.group(1) if cookie and cookie.group(1) != "0" else "",
            )
            numbers = {}
        if current:
            numbers.update((key, int(value)) for key, value in NUMBERS.findall(line))
    if current:
        yield Connection(*current, sum(numbers.values()) if numbers else None)


# ── Parseo de ps ───────────────────────────────────────────
def processes(text):
    """Devuelve {pid: usuario} para procesos de sesión sshd."""
    result = {}
    users = {}
    for row in text.splitlines():
        fields = row.split(None, 4)
        if len(fields) != 5:
            continue
        pid, parent, account, command, args = fields
        result[pid] = (parent, account, command, args)
        if command not in SSHD or account in {"root", "sshd", "nobody"}:
            continue
        title = re.fullmatch(r"sshd(?:-session)?:\s+([^@ ]+)(?:@[^ ]+)?(?:\s+.*)?", args)
        if title and title.group(1) == account and USERNAME.fullmatch(account):
            users[pid] = account
    for pid, name in list(users.items()):
        parent = result[pid][0]
        if parent in result and result[parent][2] in SSHD and result[parent][3].startswith(
            (f"sshd: {name} ", f"sshd-session: {name} ")
        ):
            users[parent] = name
    return users


def ps_table(args):
    if args.ps_file:
        try:
            return Path(args.ps_file).read_text(errors="replace")
        except OSError:
            return ""
    for spec in ("pid=,ppid=,user:64=,comm=,args=", "pid=,ppid=,user=,comm=,args="):
        rc, out = exec_cmd(["ps", "-ww", "-eo", spec])
        if rc == 0 and out:
            return out
    return ""


def ss_table(kind, args):
    if kind == "est" and args.ss_file:
        try:
            return Path(args.ss_file).read_text(errors="replace")
        except OSError:
            return ""
    if kind == "listen" and args.listen_file:
        try:
            return Path(args.listen_file).read_text(errors="replace")
        except OSError:
            return ""
    flags = "-Hntpie" if kind == "est" else "-Hlnpt"
    argv = ["ss", flags]
    if kind == "est":
        argv += ["state", "established"]
    return run(argv)


def sample(args):
    """Devuelve {cookie: (usuario, bytes)} de la muestra actual."""
    users = processes(ps_table(args))
    connections = list(tcp_rows(ss_table("est", args)))
    listening = list(tcp_rows(ss_table("listen", args), listening=True))
    ssh_ports = {c.local[1] for c in listening if any(n in SSHD for n, _, _ in c.owners)} or {22}

    meters = {}
    for conn in connections:
        if not conn.cookie or conn.measured is None:
            continue
        names = {
            users[pid]
            for name, pid, _ in conn.owners
            if name in SSHD and pid in users and conn.local[1] in ssh_ports
        }
        if len(names) != 1:
            continue
        name = next(iter(names))
        previous = meters.get(conn.cookie)
        if previous is None or (previous[0] == name and conn.measured >= previous[1]):
            meters[conn.cookie] = (name, conn.measured)
    return meters


# ── Estado acumulado ───────────────────────────────────────
def state_path():
    return STATE / "consumo.json"


def load_state():
    try:
        data = json.loads(state_path().read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    STATE.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(dir=STATE, prefix=".consumo-", delete=False)
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(json.dumps(state, ensure_ascii=True, separators=(",", ":")).encode())
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, state_path())
    finally:
        temporary.unlink(missing_ok=True)


def accumulate(meters):
    STATE.mkdir(parents=True, exist_ok=True)
    boot = boot_id()
    now = int(time.time())
    with (STATE / "consumo.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        totals = state.get("totals") or {}
        snapshots = state.get("sockets") if state.get("boot") == boot else {}
        snapshots = {
            cookie: value
            for cookie, value in (snapshots or {}).items()
            if isinstance(value, list) and len(value) == 3 and now - value[2] <= KEEP
        }
        for cookie, (name, amount) in meters.items():
            previous = snapshots.get(cookie)
            if previous:
                if previous[0] != name:
                    continue
                amount = max(amount, previous[1])
                delta = amount - previous[1]
            else:
                delta = amount
            totals[name] = int(totals.get(name, 0)) + max(0, int(delta))
            snapshots[cookie] = [name, amount, now]
        save_state({"boot": boot, "totals": totals, "sockets": snapshots, "updated": now})
    return {name: int(value) for name, value in totals.items()}


def usage_map():
    totals = load_state().get("totals") or {}
    return {name: int(value) for name, value in totals.items() if isinstance(value, (int, float))}


# ── Límites y bloqueo automático ───────────────────────────
def limits():
    data = {}
    try:
        for line in LIMITS.read_text(errors="replace").splitlines():
            if "=" not in line:
                continue
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip()
            if USERNAME.fullmatch(name) and value.isdigit():
                data[name] = int(value)
    except OSError:
        pass
    return data


def suspensions():
    data = {}
    try:
        for line in SUSPEND.read_text(errors="replace").splitlines():
            fields = line.split("|")
            if len(fields) >= 3 and USERNAME.fullmatch(fields[0].strip()):
                data[fields[0].strip()] = fields[2].strip()
    except OSError:
        pass
    return data


def save_suspensions(data):
    SUSPEND.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "w", dir=SUSPEND.parent, prefix=".susp-", delete=False, encoding="utf-8"
    )
    temporary = Path(handle.name)
    try:
        with handle:
            for name, reason in data.items():
                handle.write(f"{name}|{int(time.time())}|{reason}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, SUSPEND)
    finally:
        temporary.unlink(missing_ok=True)


def known_users():
    try:
        return {
            line.split(":", 1)[0]
            for line in PASSWD.read_text(errors="replace").splitlines()
            if ":" in line
        }
    except OSError:
        return set()


def enforce(totals):
    """Bloquea a quien superó su límite y desbloquea a quien ya no lo supera."""
    if not enforcement_enabled():
        return []
    lim = limits()
    susp = suspensions()
    existing = known_users()
    actions = []

    for name in sorted(set(lim) | set(susp)):
        if name not in existing:
            continue
        limit = lim.get(name, 0)
        used = int(totals.get(name, 0))
        over = limit > 0 and used >= limit
        marker = susp.get(name)

        if over and marker is None:
            rc, _ = exec_cmd(["passwd", "-l", name])
            if rc == 0:
                susp[name] = "consumo"
                actions.append(("bloqueado", name, used, limit))
        elif not over and marker == "consumo":
            rc, _ = exec_cmd(["passwd", "-u", name])
            if rc == 0:
                susp.pop(name, None)
                actions.append(("desbloqueado", name, used, limit))

    if susp != suspensions():
        save_suspensions(susp)
    return actions


# ── Comandos ───────────────────────────────────────────────
def human(number):
    if number is None:
        return "—"
    value = float(number)
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if value < 1024 or unit == "PB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1024
    return f"{value:.2f} PB"


def cmd_collect(args, do_enforce=True):
    meters = sample(args)
    totals = accumulate(meters)
    actions = enforce(totals) if do_enforce else []
    for action, name, used, limit in actions:
        print(f"{action}|{name}|{used}|{limit}")
    return 0


def cmd_dump(args):
    usage = usage_map()
    try:
        meters = sample(args)
    except Exception:
        meters = {}
    counts = {}
    for name, _ in meters.values():
        counts[name] = counts.get(name, 0) + 1
    for name in sorted(set(usage) | set(counts)):
        print(f"{name}|{usage.get(name, 0)}|{counts.get(name, 0)}")
    return 0


def cmd_online(args):
    counts = {}
    for name, _ in sample(args).values():
        counts[name] = counts.get(name, 0) + 1
    for name in sorted(counts):
        print(f"{name}|{counts[name]}")
    return 0


def cmd_usage(name, as_bytes=False):
    value = usage_map().get(name, 0)
    print(str(value) if as_bytes else human(value))
    return 0


def cmd_reset(name):
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "consumo.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        totals = state.get("totals") or {}
        sockets = state.get("sockets") or {}
        if name == "all":
            totals = {}
            sockets = {}
        else:
            totals.pop(name, None)
            sockets = {c: v for c, v in sockets.items() if v[0] != name}
        state["totals"] = totals
        state["sockets"] = sockets
        state["updated"] = int(time.time())
        save_state(state)
    return 0


def cmd_status():
    state = load_state()
    print(f"usuarios={len(state.get('totals') or {})}")
    print(f"actualizado={state.get('updated', 0)}")
    print(f"boot={state.get('boot', '')}")
    print(f"estado={STATE}")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="movi-meter",
        description="Medidor de consumo por usuario SSH de MOVIVIP Gestor SSH.",
    )
    parser.add_argument("--collect", action="store_true", help="toma una muestra y acumula")
    parser.add_argument("--no-enforce", action="store_true", help="no bloquea al exceder límite")
    parser.add_argument("--enforce", action="store_true", help="aplica límites con el consumo actual")
    parser.add_argument("--usage", metavar="USER", help="consumo legible del usuario")
    parser.add_argument("--usage-bytes", metavar="USER", help="consumo en bytes del usuario")
    parser.add_argument("--dump", action="store_true", help="user|bytes|conexiones")
    parser.add_argument("--online", action="store_true", help="user|sesiones activas")
    parser.add_argument("--reset", metavar="USER|all", help="pone el contador a cero")
    parser.add_argument("--forget", metavar="USER", help="borra al usuario del estado")
    parser.add_argument("--status", action="store_true", help="resumen del estado")
    parser.add_argument("--ss-file", help="archivo con salida de ss (pruebas)")
    parser.add_argument("--listen-file", help="archivo con salida de ss -l (pruebas)")
    parser.add_argument("--ps-file", help="archivo con salida de ps (pruebas)")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.collect:
        return cmd_collect(args, do_enforce=not args.no_enforce)
    if args.enforce:
        for action, name, used, limit in enforce(usage_map()):
            print(f"{action}|{name}|{used}|{limit}")
        return 0
    if args.usage is not None:
        return cmd_usage(args.usage, as_bytes=False)
    if args.usage_bytes is not None:
        return cmd_usage(args.usage_bytes, as_bytes=True)
    if args.dump:
        return cmd_dump(args)
    if args.online:
        return cmd_online(args)
    if args.reset is not None:
        return cmd_reset(args.reset)
    if args.forget is not None:
        return cmd_reset(args.forget)
    if args.status:
        return cmd_status()

    parser.error("se requiere una acción (--collect, --usage, --dump, --status...)")


if __name__ == "__main__":
    sys.exit(main())
