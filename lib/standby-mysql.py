#!/usr/bin/env python3
"""Standby MySQL helper. CloudPanel root is root@127.0.0.1 (TCP).
root@localhost is unix_socket (ERROR 1698). debian.cnf is usually absent.
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


def write_cnf(user, password, host="127.0.0.1", port="3306"):
    fd, path = tempfile.mkstemp(prefix="clp-mysql-", dir="/var/tmp")
    os.chmod(path, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(
            "[client]\n"
            f"user={user}\n"
            f"password={q_cnf(password)}\n"
            f"host={host}\n"
            f"port={port}\n"
            "protocol=tcp\n"
        )
    return path


def probe(cmd, timeout=15):
    try:
        p = subprocess.run(
            cmd + ["-N", "-e", "SELECT 1"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        if p.returncode == 0:
            return True
        err = (p.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        if err:
            print(f"standby-mysql: probe failed: {err[-1]}", flush=True)
        return False
    except subprocess.TimeoutExpired:
        print("standby-mysql: probe timed out", flush=True)
        return False


def php_ping(user, password, port):
    env = os.environ.copy()
    env["CLP_MYSQL_USER"] = user
    env["CLP_MYSQL_PASS"] = password
    env["CLP_MYSQL_PORT"] = str(port)
    code = r"""
mysqli_report(MYSQLI_REPORT_OFF);
$m = @new mysqli("127.0.0.1", getenv("CLP_MYSQL_USER"), getenv("CLP_MYSQL_PASS"), "", intval(getenv("CLP_MYSQL_PORT") ?: "3306"));
if ($m->connect_errno) { fwrite(STDERR, $m->connect_error . "\n"); exit(1); }
echo "ok\n";
"""
    try:
        p = subprocess.run(
            ["php", "-r", code],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            text=True,
        )
        if p.returncode == 0 and "ok" in (p.stdout or ""):
            return True
        err = (p.stderr or "").strip().splitlines()
        if err:
            print(f"standby-mysql: php probe failed: {err[-1]}", flush=True)
        return False
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"standby-mysql: php probe skipped: {e}", flush=True)
        return False


def php_sql(user, password, port, sql):
    env = os.environ.copy()
    env["CLP_MYSQL_USER"] = user
    env["CLP_MYSQL_PASS"] = password
    env["CLP_MYSQL_PORT"] = str(port)
    env["CLP_MYSQL_SQL"] = sql
    code = r"""
mysqli_report(MYSQLI_REPORT_OFF);
$m = @new mysqli("127.0.0.1", getenv("CLP_MYSQL_USER"), getenv("CLP_MYSQL_PASS"), "", intval(getenv("CLP_MYSQL_PORT") ?: "3306"));
if ($m->connect_errno) { fwrite(STDERR, $m->connect_error . "\n"); exit(1); }
$sql = getenv("CLP_MYSQL_SQL");
if (!$m->query($sql)) { fwrite(STDERR, $m->error . "\n"); exit(1); }
"""
    p = subprocess.run(
        ["php", "-r", code],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=30,
        text=True,
    )
    return p.returncode == 0


def repair_root_localhost(run_sql, user, password):
    escaped = sql_quote(password)
    statements = [
        f"CREATE USER IF NOT EXISTS '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        f"ALTER USER '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        f"CREATE USER IF NOT EXISTS '{user}'@'localhost' IDENTIFIED BY '{escaped}'",
        (
            f"ALTER USER '{user}'@'localhost' IDENTIFIED VIA "
            f"mysql_native_password USING PASSWORD('{escaped}') OR unix_socket"
        ),
        f"ALTER USER '{user}'@'localhost' IDENTIFIED BY '{escaped}'",
        "FLUSH PRIVILEGES",
    ]
    for sql in statements:
        try:
            run_sql(sql)
        except Exception:
            continue


def conf_dirs():
    dirs = []
    for p in (
        "/etc/mysql/conf.d",
        "/etc/mysql/mysql.conf.d",
        "/etc/mysql/mariadb.conf.d",
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
    written = []
    for d in conf_dirs():
        path = os.path.join(d, filename)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o644)
        written.append(path)
        print(f"standby-mysql: wrote {path}", flush=True)
    return written


def remove_server_dropin(filename):
    for d in conf_dirs():
        path = os.path.join(d, filename)
        try:
            os.unlink(path)
            print(f"standby-mysql: removed {path}", flush=True)
        except FileNotFoundError:
            pass


def mysql_unit():
    for name in ("mysql", "mariadb", "mysqld"):
        if subprocess.call(["systemctl", "is-active", "--quiet", name]) == 0:
            return name
    return "mysql"


def wait_mysql_up(timeout=45):
    unit = mysql_unit()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if subprocess.call(["systemctl", "is-active", "--quiet", unit]) == 0:
            for sock in (
                "/run/mysqld/mysqld.sock",
                "/var/run/mysqld/mysqld.sock",
                "/tmp/mysql.sock",
            ):
                if os.path.exists(sock):
                    time.sleep(1)
                    return True
        time.sleep(1)
    return subprocess.call(["systemctl", "is-active", "--quiet", unit]) == 0


def restart_mysql():
    unit = mysql_unit()
    print(f"standby-mysql: restarting {unit}", flush=True)
    subprocess.check_call(["systemctl", "restart", unit])
    if not wait_mysql_up():
        print("standby-mysql: warning: mysql did not become ready after restart", flush=True)


def ensure_skip_name_resolve():
    """Standby-only. 127.0.0.1 reverse-DNSes to localhost, so CloudPanel's
    root@127.0.0.1 password is never used (ERROR 1698 unix_socket)."""
    marker = os.path.join("/var/lib/clp-sync", "mysql-skip-name-resolve")
    already = False
    for d in conf_dirs():
        if os.path.isfile(os.path.join(d, "zz-clp-sync-skip-name-resolve.cnf")):
            already = True
            break
    write_server_dropin(
        "zz-clp-sync-skip-name-resolve.cnf",
        "[mysqld]\nskip-name-resolve=ON\n",
    )
    os.makedirs("/var/lib/clp-sync", exist_ok=True)
    if already and os.path.isfile(marker):
        print("standby-mysql: skip-name-resolve already enabled", flush=True)
        return False
    restart_mysql()
    with open(marker, "w") as f:
        f.write("1\n")
    return True


def socket_root_sql(sql):
    attempts = (
        ["mysql", "-u", "root", "--protocol=SOCKET", "--batch", "--skip-password", "-e", sql],
        ["mysql", "-u", "root", "--batch", "--skip-password", "-e", sql],
        ["mysql", "--protocol=SOCKET", "--batch", "-e", sql],
    )
    last = ""
    for args in attempts:
        p = subprocess.run(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            text=True,
        )
        err = ((p.stderr or "") + (p.stdout or "")).strip().replace("\n", " ")
        print(f"standby-mysql: socket-sql rc={p.returncode} {err[-240:]}", flush=True)
        if p.returncode == 0:
            return True
        last = err
    return False


def skip_grant_repair(user, password):
    """Standby-only. MYSQLD_OPTS is ignored by CloudPanel's systemd unit;
    write a real mysqld drop-in instead. Do not FLUSH PRIVILEGES while
    skip-grant-tables is on (MariaDB reloads grants and locks us out)."""
    print("standby-mysql: skip-grant-tables via mysqld drop-in", flush=True)
    write_server_dropin(
        "zz-clp-sync-skip-grant.cnf",
        "[mysqld]\nskip-grant-tables\nskip-networking\n",
    )
    restart_mysql()
    escaped = sql_quote(password)
    statements = [
        f"CREATE USER IF NOT EXISTS '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        f"CREATE USER IF NOT EXISTS '{user}'@'localhost' IDENTIFIED BY '{escaped}'",
        f"ALTER USER '{user}'@'127.0.0.1' IDENTIFIED BY '{escaped}'",
        (
            f"ALTER USER '{user}'@'localhost' IDENTIFIED VIA "
            f"mysql_native_password USING PASSWORD('{escaped}') OR unix_socket"
        ),
        f"ALTER USER '{user}'@'localhost' IDENTIFIED BY '{escaped}'",
    ]
    any_ok = False
    for sql in statements:
        if socket_root_sql(sql):
            any_ok = True
    if not any_ok:
        print("standby-mysql: skip-grant SQL did not run (drop-in may not have loaded)", flush=True)
    remove_server_dropin("zz-clp-sync-skip-grant.cnf")
    restart_mysql()
    return any_ok


def build_client():
    user, password, port = parse_clpctl()
    temps = []
    bin_name = "mysql"
    cnf = write_cnf(user, password, "127.0.0.1", port)
    temps.append(cnf)
    tcp = [bin_name, f"--defaults-file={cnf}", "--batch", "--raw", "--quick"]
    env_tcp = [
        bin_name,
        "-h",
        "127.0.0.1",
        "-P",
        str(port),
        "-u",
        user,
        "--protocol=TCP",
        "--batch",
        "--raw",
        "--quick",
    ]

    def with_pwd(cmd):
        env = os.environ.copy()
        env["MYSQL_PWD"] = password
        return cmd, env

    if probe(tcp):
        print("standby-mysql: auth=cloudpanel-tcp", flush=True)
        return tcp, temps, None

    print("standby-mysql: defaults-file TCP failed", flush=True)
    cmd, env = with_pwd(env_tcp)
    try:
        p = subprocess.run(
            cmd + ["-N", "-e", "SELECT 1"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=15,
        )
        if p.returncode == 0:
            print("standby-mysql: auth=MYSQL_PWD-tcp", flush=True)
            return cmd, temps, env
        err = (p.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        if err:
            print(f"standby-mysql: MYSQL_PWD probe failed: {err[-1]}", flush=True)
    except subprocess.TimeoutExpired:
        print("standby-mysql: MYSQL_PWD probe timed out", flush=True)

    print("standby-mysql: enabling skip-name-resolve on standby MySQL", flush=True)
    ensure_skip_name_resolve()
    if probe(tcp):
        print("standby-mysql: auth=cloudpanel-tcp after skip-name-resolve", flush=True)
        return tcp, temps, None
    cmd, env = with_pwd(env_tcp)
    p = subprocess.run(
        cmd + ["-N", "-e", "SELECT 1"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=15,
    )
    if p.returncode == 0:
        print("standby-mysql: auth=MYSQL_PWD-tcp after skip-name-resolve", flush=True)
        return cmd, temps, env

    debian = "/etc/mysql/debian.cnf"
    if os.path.isfile(debian):
        deb = [bin_name, f"--defaults-file={debian}", "--batch", "--raw", "--quick"]
        if probe(deb):
            print("standby-mysql: auth=debian-sys-maint; repairing root@localhost", flush=True)

            def run_sql(sql):
                subprocess.check_call(
                    deb + ["-e", sql],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                )

            repair_root_localhost(run_sql, user, password)
            if probe(tcp):
                print("standby-mysql: auth=cloudpanel-tcp after repair", flush=True)
                return tcp, temps, None
            return deb, temps, None

    if php_ping(user, password, port):
        print("standby-mysql: php mysqli works; repairing root@localhost", flush=True)

        def run_sql(sql):
            php_sql(user, password, port, sql)

        repair_root_localhost(run_sql, user, password)
        if probe(tcp):
            print("standby-mysql: auth=cloudpanel-tcp after php repair", flush=True)
            return tcp, temps, None
        print("standby-mysql: CLI still blocked after php repair", flush=True)

    print("standby-mysql: last resort skip-grant-tables on standby MySQL", flush=True)
    skip_grant_repair(user, password)
    if probe(tcp):
        print("standby-mysql: auth=cloudpanel-tcp after skip-grant-tables", flush=True)
        return tcp, temps, None
    cmd, env = with_pwd(env_tcp)
    p = subprocess.run(
        cmd + ["-N", "-e", "SELECT 1"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=15,
    )
    if p.returncode == 0:
        print("standby-mysql: auth=MYSQL_PWD-tcp after skip-grant-tables", flush=True)
        return cmd, temps, env

    sys.exit(
        "standby mysql auth failed: 127.0.0.1 is authenticated as root@localhost "
        "(ERROR 1698). skip-name-resolve and skip-grant-tables repair did not fix it."
    )


def run_cmd(cmd, extra, env=None, stdin=None, timeout=120):
    subprocess.check_call(
        cmd + extra,
        stdin=stdin if stdin is not None else subprocess.DEVNULL,
        timeout=timeout,
        env=env,
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
            try:
                os.unlink(path)
            except OSError:
                pass


if __name__ == "__main__":
    main()
