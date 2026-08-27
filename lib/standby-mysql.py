#!/usr/bin/env python3
"""Standby-only MySQL import helper.

NEVER run this on the live master. It may restart mysqld and ALTER root
on the standby so CloudPanel's copied sqlite password matches Percona.

Dump happens on the master (read-only). This file only runs over SSH on
the standby: create database + import.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import time

os.environ.pop("MYSQL_HOST", None)
os.environ.pop("MYSQL_UNIX_PORT", None)
os.environ.pop("MYSQL_PWD", None)

PERSIST_CNF = "/var/lib/clp-sync/standby-mysql-root.cnf"
SKIP_GRANT_ONCE = "/var/lib/clp-sync/mysql-skip-grant-done"


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
    return ["mysql", f"--defaults-file={cnf}", "--batch", "--raw", "--quick"]


def conf_dirs():
    # Percona/MySQL only. Do not write mariadb.conf.d on this stack.
    dirs = []
    for p in (
        "/etc/mysql/mysql.conf.d",
        "/etc/mysql/conf.d",
        "/etc/mysql/percona-server.conf.d",
        "/etc/percona-server.conf.d",
    ):
        if os.path.isdir(p):
            dirs.append(p)
    if not dirs:
        os.makedirs("/etc/mysql/conf.d", exist_ok=True)
        dirs.append("/etc/mysql/conf.d")
    return dirs


def write_server_dropin(filename, body):
    for d in conf_dirs():
        path = os.path.join(d, filename)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o644)
        print(f"standby-mysql: wrote {path}", flush=True)


def remove_server_dropin(filename):
    for d in conf_dirs():
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


def wait_mysql_up(timeout=45):
    unit = mysql_unit()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if subprocess.call(["systemctl", "is-active", "--quiet", unit]) == 0:
            for sock in ("/run/mysqld/mysqld.sock", "/var/run/mysqld/mysqld.sock"):
                if os.path.exists(sock):
                    time.sleep(1)
                    return True
        time.sleep(1)
    return subprocess.call(["systemctl", "is-active", "--quiet", unit]) == 0


def restart_mysql():
    unit = mysql_unit()
    print(f"standby-mysql: restarting {unit} (standby only)", flush=True)
    subprocess.check_call(["systemctl", "restart", unit])
    if not wait_mysql_up():
        print("standby-mysql: warning: mysql did not become ready after restart", flush=True)


def ensure_skip_name_resolve():
    marker = os.path.join("/var/lib/clp-sync", "mysql-skip-name-resolve")
    already = any(
        os.path.isfile(os.path.join(d, "zz-clp-sync-skip-name-resolve.cnf"))
        for d in conf_dirs()
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


def chown_mysql(path):
    try:
        import grp
        import pwd

        os.chown(path, pwd.getpwnam("mysql").pw_uid, grp.getgrnam("mysql").gr_gid)
    except Exception:
        pass
    os.chmod(path, 0o600)


def looks_like_cnf(path):
    try:
        head = open(path, encoding="utf-8", errors="replace").read(4096)
    except OSError:
        return False
    return "[client]" in head or "[mysql]" in head


def align_sql(user, password):
    escaped = sql_quote(password)
    return [
        "FLUSH PRIVILEGES",
        f"CREATE USER IF NOT EXISTS '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        f"CREATE USER IF NOT EXISTS '{user}'@'localhost' IDENTIFIED BY '{escaped}'",
        f"ALTER USER '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        f"ALTER USER '{user}'@'localhost' IDENTIFIED BY '{escaped}'",
        "FLUSH PRIVILEGES",
    ]


def socket_root_sql(sql, secret):
    env = os.environ.copy()
    env.pop("MYSQL_PWD", None)
    attempts = (
        ["mysql", "-u", "root", "--protocol=SOCKET", "--batch", "--skip-password", "-e", sql],
        ["mysql", "-u", "root", "--batch", "--skip-password", "-e", sql],
    )
    for args in attempts:
        p = subprocess.run(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            text=True,
            env=env,
        )
        err = redact((p.stderr or "") + (p.stdout or ""), secret)
        print(f"standby-mysql: socket-sql rc={p.returncode} {err[-200:]}", flush=True)
        if p.returncode == 0:
            return True
    return False


def skip_grant_align_root(user, password):
    """Standby Percona only. MySQL 8 blocks ALTER USER under
    skip-grant-tables until FLUSH PRIVILEGES in that session.
    init-file runs that at startup. Socket SQL is the fallback.
    """
    print("standby-mysql: aligning standby root password (skip-grant-tables, not master)", flush=True)
    os.makedirs("/var/lib/clp-sync", exist_ok=True)
    init_path = "/var/lib/clp-sync/mysql-init-align.sql"
    with open(init_path, "w") as f:
        f.write(";\n".join(align_sql(user, password)) + ";\n")
    chown_mysql(init_path)
    write_server_dropin(
        "zz-clp-sync-skip-grant.cnf",
        "[mysqld]\nskip-grant-tables\nskip-networking\n"
        f"init-file={init_path}\n",
    )
    restart_mysql()
    any_ok = False
    for sql in align_sql(user, password):
        if socket_root_sql(sql, password):
            any_ok = True
    try:
        os.unlink(init_path)
    except OSError:
        pass
    remove_server_dropin("zz-clp-sync-skip-grant.cnf")
    restart_mysql()
    with open(SKIP_GRANT_ONCE, "w") as f:
        f.write("1\n")
    return any_ok


def try_extra_cnfs():
    for path in (
        PERSIST_CNF,
        "/root/.my.cnf",
        "/root/.mysql-credentials",
        "/etc/mysql/debian.cnf",
    ):
        if not os.path.isfile(path) or not looks_like_cnf(path):
            continue
        cmd = mysql_cmd(path)
        print(f"standby-mysql: trying {path}", flush=True)
        if probe(cmd):
            print(f"standby-mysql: auth={path}", flush=True)
            return cmd, []
    return None, []


def build_client():
    assert_standby()
    extra, temps = try_extra_cnfs()
    if extra:
        return extra, temps, None

    user, password, port = parse_clpctl()
    cnf = write_cnf(user, password, "127.0.0.1", port)
    temps = [cnf]
    tcp = mysql_cmd(cnf)

    if probe(tcp, secret=password):
        print("standby-mysql: auth=cloudpanel-tcp", flush=True)
        persist_cnf(user, password, port)
        return tcp, temps, None

    print("standby-mysql: panel password does not match standby MySQL yet", flush=True)
    ensure_skip_name_resolve()
    if probe(tcp, secret=password):
        print("standby-mysql: auth=cloudpanel-tcp after skip-name-resolve", flush=True)
        persist_cnf(user, password, port)
        return tcp, temps, None

    skip_grant_align_root(user, password)
    if probe(tcp, secret=password):
        print("standby-mysql: auth=cloudpanel-tcp after standby root align", flush=True)
        persist_cnf(user, password, port)
        return tcp, temps, None

    extra, _ = try_extra_cnfs()
    if extra:
        return extra, temps, None

    sys.exit(
        "standby mysql import auth failed. Master was not changed. "
        "Dump already works; standby root password does not match panel sqlite."
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
            with open(sql_path, "wb") as outf:
                subprocess.check_call(["gunzip", "-c", gz], stdout=outf, timeout=180)
            print(f"standby-mysql: import {db}", flush=True)
            with open(sql_path, "rb") as inf:
                run_cmd(cmd, [db], env=env, stdin=inf, timeout=600)
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
