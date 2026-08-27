#!/usr/bin/env python3
"""Standby-only MySQL import helper.

NEVER run this on the live master. Dump is read-only on the master.
This file only runs over SSH on the standby.

Do not put skip-grant-tables in systemd drop-ins. Debian AppArmor
blocks init-file under /var/lib/clp-sync and mysqld then refuses to start.
"""
from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import tempfile
import time

os.environ.pop("MYSQL_HOST", None)
os.environ.pop("MYSQL_UNIX_PORT", None)
os.environ.pop("MYSQL_PWD", None)

PERSIST_CNF = "/var/lib/clp-sync/standby-mysql-root.cnf"
SOCKETS = (
    "/run/mysqld/mysqld.sock",
    "/var/run/mysqld/mysqld.sock",
    "/tmp/mysql.sock",
)
DROPIN_DIRS = (
    "/etc/mysql/mysql.conf.d",
    "/etc/mysql/conf.d",
    "/etc/mysql/mariadb.conf.d",
    "/etc/mysql/percona-server.conf.d",
    "/etc/percona-server.conf.d",
)


def assert_standby():
    cfg = "/etc/clp-sync/config.env"
    role = ""
    if os.path.isfile("/etc/clp-sync/role"):
        role = open("/etc/clp-sync/role", encoding="utf-8").read().strip()
    if os.path.isfile(cfg):
        m = re.search(r"(?m)^ROLE=(\S+)", open(cfg, encoding="utf-8").read())
        if m:
            role = m.group(1).strip()
    if role == "master":
        sys.exit("standby-mysql: refusing to run on ROLE=master (no live MySQL changes)")


def grab(text, *labels):
    for lab in labels:
        m = re.search(rf"(?im)(?:\|\s*)?{lab}\s*(?:\||:)\s*([^\s|]+)", text)
        if m:
            return m.group(1).strip().strip("'\"")
    return ""


def q_cnf(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sql_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "''")


def redact(text: str, secret: str) -> str:
    if not text:
        return ""
    if secret:
        text = text.replace(secret, "***")
    return text.replace("\n", " ").strip()


def parse_clpctl():
    print("standby-mysql: fetching credentials", flush=True)
    out = subprocess.check_output(
        ["clpctl", "db:show:master-credentials"],
        stdin=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        timeout=30,
        text=True,
    )
    user = grab(out, "User Name", "UserName", "Username") or "root"
    password = grab(out, "Password")
    port = grab(out, "Port") or "3306"
    m = re.search(r"-p'([^']+)'", out)
    if m:
        password = m.group(1)
    else:
        m = re.search(r'-p"([^"]+)"', out)
        if m:
            password = m.group(1)
    if not password:
        sys.exit("no mysql password from clpctl on standby")
    return user, password, port


def write_cnf(user, password, host="127.0.0.1", port="3306", path=None):
    if path is None:
        fd, path = tempfile.mkstemp(prefix="clp-mysql-", dir="/var/tmp")
        os.close(fd)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(
            "[client]\n"
            f"user={user}\n"
            f"password={q_cnf(password)}\n"
            f"host={host}\n"
            f"port={port}\n"
            "protocol=tcp\n"
        )
    os.chmod(path, 0o600)
    return path


def persist_cnf(user, password, port):
    write_cnf(user, password, "127.0.0.1", port, PERSIST_CNF)
    print("standby-mysql: saved working client cnf on standby", flush=True)


def persist_socket_cnf(sock):
    os.makedirs("/var/lib/clp-sync", exist_ok=True)
    with open(PERSIST_CNF, "w") as f:
        f.write(f"[client]\nuser=root\nsocket={sock}\nprotocol=socket\n")
    os.chmod(PERSIST_CNF, 0o600)
    print("standby-mysql: saved socket client cnf on standby", flush=True)


def cnf_is_socket(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return "protocol=socket" in text.replace(" ", "")


def probe(cmd, timeout=15, secret=""):
    env = os.environ.copy()
    env.pop("MYSQL_PWD", None)
    try:
        p = subprocess.run(
            cmd + ["-N", "-e", "SELECT 1"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            env=env,
        )
        if p.returncode == 0:
            return True
        err = (p.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        if err:
            print(f"standby-mysql: probe failed: {redact(err[-1], secret)}", flush=True)
        return False
    except subprocess.TimeoutExpired:
        print("standby-mysql: probe timed out", flush=True)
        return False


def mysql_cmd(cnf):
    cmd = ["mysql", f"--defaults-file={cnf}", "--batch", "--raw", "--quick", "--connect-timeout=5"]
    if cnf_is_socket(cnf):
        cmd.append("--skip-password")
    return cmd


def conf_dirs():
    dirs = [p for p in DROPIN_DIRS if os.path.isdir(p)]
    if not dirs:
        os.makedirs("/etc/mysql/conf.d", exist_ok=True)
        dirs.append("/etc/mysql/conf.d")
    return dirs


def write_server_dropin(filename, body):
    for d in conf_dirs():
        if "mariadb.conf.d" in d:
            continue
        path = os.path.join(d, filename)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o644)
        print(f"standby-mysql: wrote {path}", flush=True)


def remove_server_dropin(filename):
    for d in DROPIN_DIRS:
        path = os.path.join(d, filename)
        try:
            os.unlink(path)
            print(f"standby-mysql: removed {path}", flush=True)
        except FileNotFoundError:
            pass


def mysql_unit():
    for name in ("mysql", "mysqld"):
        if subprocess.call(["systemctl", "is-active", "--quiet", name]) == 0:
            return name
    return "mysql"


def wait_socket(timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if any(os.path.exists(s) for s in SOCKETS):
            time.sleep(0.5)
            return True
        time.sleep(0.3)
    return False


def wait_mysql_up(timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for name in ("mysql", "mysqld"):
            if subprocess.call(["systemctl", "is-active", "--quiet", name]) == 0:
                if any(os.path.exists(s) for s in SOCKETS):
                    time.sleep(1)
                    return True
        time.sleep(0.5)
    return False


def start_systemd_mysql():
    for name in ("mysql", "mysqld"):
        subprocess.call(
            ["systemctl", "reset-failed", name],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"standby-mysql: starting {name} (standby only)", flush=True)
        rc = subprocess.call(["systemctl", "start", name])
        if rc == 0 and wait_mysql_up(45):
            return True
    return wait_mysql_up(15)


def stop_systemd_mysql():
    for name in ("mysql", "mysqld"):
        subprocess.call(
            ["systemctl", "stop", name],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    deadline = time.time() + 30
    while time.time() < deadline:
        if not any(os.path.exists(s) for s in SOCKETS):
            return
        time.sleep(0.5)


def rescue_mysql():
    """Undo the skip-grant systemd drop-in that crashed mysqld, then start it."""
    remove_server_dropin("zz-clp-sync-skip-grant.cnf")
    for path in (
        "/var/lib/clp-sync/mysql-init-align.sql",
        "/var/lib/mysql/clp-sync-init.sql",
    ):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    if any(os.path.exists(s) for s in SOCKETS) and subprocess.call(
        ["systemctl", "is-active", "--quiet", "mysql"]
    ) == 0:
        return
    print("standby-mysql: recovering standby mysql after skip-grant drop-in failure", flush=True)
    if not start_systemd_mysql():
        print("standby-mysql: warning: mysql did not start after drop-in cleanup", flush=True)


def restart_mysql():
    unit = mysql_unit()
    print(f"standby-mysql: restarting {unit} (standby only)", flush=True)
    rc = subprocess.call(["systemctl", "restart", unit])
    if rc != 0:
        rescue_mysql()
        return
    if not wait_mysql_up():
        print("standby-mysql: warning: mysql did not become ready after restart", flush=True)


def ensure_skip_name_resolve():
    marker = os.path.join("/var/lib/clp-sync", "mysql-skip-name-resolve")
    already = any(
        os.path.isfile(os.path.join(d, "zz-clp-sync-skip-name-resolve.cnf"))
        for d in conf_dirs()
        if "mariadb.conf.d" not in d
    )
    write_server_dropin("zz-clp-sync-skip-name-resolve.cnf", "[mysqld]\nskip-name-resolve=ON\n")
    os.makedirs("/var/lib/clp-sync", exist_ok=True)
    if already and os.path.isfile(marker):
        print("standby-mysql: skip-name-resolve already enabled", flush=True)
        return False
    restart_mysql()
    with open(marker, "w") as f:
        f.write("1\n")
    return True


def looks_like_cnf(path):
    try:
        head = open(path, encoding="utf-8", errors="replace").read(4096)
    except OSError:
        return False
    return "[client]" in head or "[mysql]" in head


def socket_root_cmd(sock=None):
    socks = (sock,) if sock else SOCKETS
    for path in socks:
        if not os.path.exists(path):
            continue
        cmd = [
            "mysql",
            "--no-defaults",
            "-u",
            "root",
            "--protocol=SOCKET",
            f"--socket={path}",
            "--skip-password",
            "--batch",
            "--raw",
            "--connect-timeout=5",
        ]
        print(f"standby-mysql: trying socket root {path}", flush=True)
        if probe(cmd):
            print("standby-mysql: auth=socket-root", flush=True)
            persist_socket_cnf(path)
            return cmd
    return None


def run_sql(cmd, sql, secret=""):
    env = os.environ.copy()
    env.pop("MYSQL_PWD", None)
    p = subprocess.run(
        cmd + ["-e", sql],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        text=True,
        env=env,
    )
    err = redact((p.stderr or "") + (p.stdout or ""), secret)
    print(f"standby-mysql: sql rc={p.returncode} {err[-200:]}", flush=True)
    return p.returncode == 0


def align_tcp_root(cmd, user, password):
    """Set root@127.0.0.1 only. Leave root@localhost as unix_socket."""
    escaped = sql_quote(password)
    ok = False
    for sql in (
        f"CREATE USER IF NOT EXISTS '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        f"ALTER USER '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        "FLUSH PRIVILEGES",
    ):
        if run_sql(cmd, sql, password):
            ok = True
    return ok


def mysqld_bin():
    for p in ("/usr/sbin/mysqld", "/usr/sbin/mariadbd", "/usr/libexec/mysqld"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def tail_mysql_error():
    for path in (
        "/var/log/mysql/error.log",
        "/var/lib/mysql/error.log",
        "/var/log/mysql/clp-repair.err",
        "/var/lib/mysql/clp-repair.err",
    ):
        if not os.path.isfile(path):
            continue
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for line in lines[-8:]:
            print(f"standby-mysql: mysqld-log {line[:200]}", flush=True)


def skip_grant_oneshot(user, password):
    """Stop systemd mysql, start mysqld --skip-grant-tables ourselves, ALTER
    root@127.0.0.1, then start systemd mysql again. No conf.d drop-in.
    """
    print("standby-mysql: one-shot skip-grant mysqld (standby only, not systemd)", flush=True)
    remove_server_dropin("zz-clp-sync-skip-grant.cnf")
    binary = mysqld_bin()
    if not binary:
        print("standby-mysql: mysqld binary not found", flush=True)
        return False

    stop_systemd_mysql()
    os.makedirs("/run/mysqld", exist_ok=True)
    os.makedirs("/var/lib/clp-sync", exist_ok=True)
    try:
        import grp
        import pwd

        os.chown(
            "/run/mysqld",
            pwd.getpwnam("mysql").pw_uid,
            grp.getgrnam("mysql").gr_gid,
        )
    except Exception:
        pass

    sock = "/run/mysqld/mysqld.sock"
    pidfile = "/run/mysqld/mysqld-clp-repair.pid"
    if os.path.isdir("/var/log/mysql"):
        errfile = "/var/log/mysql/clp-repair.err"
    else:
        errfile = "/var/lib/mysql/clp-repair.err"
    for leftover in (sock, pidfile):
        try:
            os.unlink(leftover)
        except FileNotFoundError:
            pass

    cmd = [binary, "--skip-grant-tables", "--skip-networking", "--user=mysql"]
    if os.path.isfile("/etc/mysql/my.cnf"):
        cmd[1:1] = ["--defaults-file=/etc/mysql/my.cnf"]
    cmd += [f"--socket={sock}", f"--pid-file={pidfile}", f"--log-error={errfile}"]

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    up = False
    try:
        for _ in range(40):
            if os.path.exists(sock):
                up = True
                break
            if proc.poll() is not None:
                time.sleep(1)
                if os.path.exists(sock):
                    up = True
                    break
                print(f"standby-mysql: oneshot mysqld exited {proc.returncode}", flush=True)
                tail_mysql_error()
                break
            time.sleep(0.5)
        if not up:
            print("standby-mysql: oneshot mysqld did not create a socket", flush=True)
            tail_mysql_error()
            return False
        client = [
            "mysql",
            "-u",
            "root",
            "--protocol=SOCKET",
            f"--socket={sock}",
            "--skip-password",
            "--batch",
            "--raw",
            "--quick",
        ]
        if not probe(client):
            print("standby-mysql: oneshot socket probe failed", flush=True)
            return False
        run_sql(client, "FLUSH PRIVILEGES", password)
        align_tcp_root(client, user, password)
        return True
    finally:
        pid = None
        if os.path.isfile(pidfile):
            try:
                pid = int(open(pidfile, encoding="utf-8").read().strip())
            except (OSError, ValueError):
                pid = None
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        elif proc.poll() is None:
            proc.terminate()
        deadline = time.time() + 20
        while time.time() < deadline:
            if proc.poll() is not None and not os.path.exists(sock):
                break
            time.sleep(0.3)
        if proc.poll() is None:
            proc.kill()
        start_systemd_mysql()


def try_extra_cnfs():
    for path in (
        PERSIST_CNF,
        "/root/.my.cnf",
        "/root/.mysql-credentials",
        "/etc/mysql/debian.cnf",
    ):
        if not os.path.isfile(path) or not looks_like_cnf(path):
            continue
        # Last run saved a TCP root that can SELECT 1 but cannot CREATE DATABASE.
        if path == PERSIST_CNF and not cnf_is_socket(path):
            continue
        cmd = mysql_cmd(path)
        print(f"standby-mysql: trying {path}", flush=True)
        if probe(cmd):
            print(f"standby-mysql: auth={path}", flush=True)
            return cmd, []
    return None, []


def build_client():
    assert_standby()
    rescue_mysql()

    # Unix socket root is the CloudPanel admin account. Use it for CREATE + import.
    # Do not switch to TCP root@127.0.0.1 — that user can log in with no CREATE.
    sock_cmd = socket_root_cmd()
    if sock_cmd:
        print("standby-mysql: import client=socket-root", flush=True)
        return sock_cmd, [], None

    extra, temps = try_extra_cnfs()
    if extra:
        return extra, temps, None

    user, password, port = parse_clpctl()
    cnf = write_cnf(user, password, "127.0.0.1", port)
    temps = [cnf]
    tcp = mysql_cmd(cnf)

    print("standby-mysql: panel TCP root not used; socket root unavailable", flush=True)
    ensure_skip_name_resolve()
    sock_cmd = socket_root_cmd()
    if sock_cmd:
        print("standby-mysql: import client=socket-root", flush=True)
        return sock_cmd, temps, None

    skip_grant_oneshot(user, password)
    sock_cmd = socket_root_cmd()
    if sock_cmd:
        print("standby-mysql: import client=socket-root after skip-grant", flush=True)
        return sock_cmd, temps, None

    extra, _ = try_extra_cnfs()
    if extra:
        return extra, temps, None

    if probe(tcp, secret=password):
        print("standby-mysql: falling back to TCP root (may lack CREATE)", flush=True)
        return tcp, temps, None

    sys.exit(
        "standby mysql import auth failed. Master was not changed. "
        "Dump already works; standby MySQL would not accept a client."
    )


def run_cmd(cmd, extra, env=None, stdin=None, timeout=120):
    run_env = os.environ.copy()
    run_env.pop("MYSQL_PWD", None)
    if env:
        run_env.update(env)
        run_env.pop("MYSQL_PWD", None)
    subprocess.check_call(
        cmd + extra,
        stdin=stdin if stdin is not None else subprocess.DEVNULL,
        timeout=timeout,
        env=run_env,
    )


def main():
    mode = sys.argv[1]
    args = sys.argv[2:]
    cmd, temps, env = build_client()
    try:
        if mode == "query":
            run_cmd(cmd, ["-N", "-e", args[0]], env=env, timeout=60)
        elif mode == "exec-file":
            print(f"standby-mysql: exec {args[0]}", flush=True)
            with open(args[0], "rb") as stdin:
                run_cmd(cmd, [], env=env, stdin=stdin, timeout=120)
        elif mode == "import-gz":
            db, gz = args[0], args[1]
            if not re.fullmatch(r"[A-Za-z0-9_]+", db):
                sys.exit(f"refusing unsafe database name: {db}")
            print(f"standby-mysql: create database {db}", flush=True)
            run_cmd(
                cmd,
                [
                    "-N",
                    "-e",
                    f"CREATE DATABASE IF NOT EXISTS `{db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci",
                ],
                env=env,
                timeout=30,
            )
            sql_path = gz[:-3] if gz.endswith(".gz") else gz + ".sql"
            print(f"standby-mysql: decompress {gz}", flush=True)
            with subprocess.Popen(["gunzip", "-c", gz], stdout=subprocess.PIPE) as proc:
                with open(sql_path, "wb") as outf:
                    for line in proc.stdout:
                        if b"sandbox mode" in line[:80]:
                            continue
                        if line.lstrip().upper().startswith(b"SET @@GLOBAL.GTID_PURGED"):
                            continue
                        outf.write(line)
                if proc.wait() != 0:
                    sys.exit(f"gunzip failed for {gz}")
            size = os.path.getsize(sql_path)
            print(f"standby-mysql: import {db} ({size} bytes, binary-mode)", flush=True)
            with open(sql_path, "rb") as inf:
                run_cmd(
                    cmd,
                    ["--binary-mode", "--force", db],
                    env=env,
                    stdin=inf,
                    timeout=600,
                )
            os.unlink(sql_path)
            print(f"standby-mysql: import {db} done", flush=True)
        else:
            sys.exit(f"unknown mysql mode: {mode}")
    finally:
        for path in temps:
            if path == PERSIST_CNF:
                continue
            try:
                os.unlink(path)
            except OSError:
                pass


if __name__ == "__main__":
    main()
