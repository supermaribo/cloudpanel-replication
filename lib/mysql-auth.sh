#!/usr/bin/env bash
# MySQL auth for CloudPanel: root@localhost is unix_socket (ERROR 1698).
# Prefer an exclusive defaults-file (not extra-file) so ~/.my.cnf cannot
# force a Unix socket. On the standby, fall back to debian-sys-maint.

MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-}"

mysql_cli() {
  if [[ -n "${MYSQL_DEFAULTS_FILE}" ]]; then
    mysql --defaults-file="${MYSQL_DEFAULTS_FILE}" "$@"
  else
    mysql "$@"
  fi
}

mysqldump_cli() {
  if [[ -n "${MYSQL_DEFAULTS_FILE}" ]]; then
    mysqldump --defaults-file="${MYSQL_DEFAULTS_FILE}" "$@"
  else
    mysqldump "$@"
  fi
}

_parse_clp_master_creds() {
  CLP_CREDS_TEXT="$1" python3 - <<'PY'
import os, re, sys
text = os.environ.get("CLP_CREDS_TEXT") or ""

def grab(*labels):
    for lab in labels:
        m = re.search(rf'(?im)(?:\|\s*)?{lab}\s*(?:\||:)\s*([^\s|]+)', text)
        if m:
            return m.group(1).strip().strip("'\"")
    return ""

user = grab("User Name", "UserName", "Username", "User") or "root"
password = grab("Password")
host = grab("Host") or "127.0.0.1"
port = grab("Port") or "3306"
m = re.search(r"-p'([^']+)'", text)
if m:
    password = m.group(1)
else:
    m = re.search(r'-p"([^"]+)"', text)
    if m:
        password = m.group(1)
m = re.search(r"-h\s*([0-9.]+)", text)
if m:
    host = m.group(1)
if not password:
    sys.exit(1)
print(f"{user}\t{password}\t{host}\t{port}")
PY
}

_write_mysql_cnf() {
  local cnf="$1" user="$2" pass="$3" host="${4:-127.0.0.1}" port="${5:-3306}"
  MYSQL_CNF_PATH="${cnf}" MYSQL_CNF_USER="${user}" MYSQL_CNF_PASS="${pass}" \
    MYSQL_CNF_HOST="${host}" MYSQL_CNF_PORT="${port}" python3 - <<'PY'
import os, pathlib
path = pathlib.Path(os.environ["MYSQL_CNF_PATH"])

def q(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

lines = [
    "[client]",
    "user=" + q(os.environ["MYSQL_CNF_USER"]),
    "password=" + q(os.environ["MYSQL_CNF_PASS"]),
    "host=" + q(os.environ.get("MYSQL_CNF_HOST") or "127.0.0.1"),
    "port=" + q(os.environ.get("MYSQL_CNF_PORT") or "3306"),
    "protocol=tcp",
    "connect-timeout=10",
]
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY
}

# Build a mode-600 mysql client cnf for this run (master dump path).
ensure_mysql_defaults() {
  local cnf="${CLP_SYNC_TMP_DIR}/mysql-client.cnf"
  mkdir -p "${CLP_SYNC_TMP_DIR}"

  if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]] \
     && mysql --defaults-file="${MYSQL_DEFAULTS_FILE}" --batch -N -e "SELECT 1" >/dev/null 2>&1; then
    return 0
  fi

  if mysql --batch -N -e "SELECT 1" >/dev/null 2>&1; then
    MYSQL_DEFAULTS_FILE=""
    return 0
  fi

  local out line user pass host port
  out="$(clpctl db:show:master-credentials 2>/dev/null || true)"
  if line="$(_parse_clp_master_creds "${out}")"; then
    IFS=$'\t' read -r user pass host port <<<"${line}"
    _write_mysql_cnf "${cnf}" "${user}" "${pass}" "127.0.0.1" "${port}"
    if mysql --defaults-file="${cnf}" --batch -N -e "SELECT 1" >/dev/null 2>&1; then
      MYSQL_DEFAULTS_FILE="${cnf}"
      log_info "MySQL client using CloudPanel master credentials (${user}@127.0.0.1)"
      return 0
    fi
  fi

  log_warn "Could not authenticate as MySQL root; will use clpctl db:export instead"
  MYSQL_DEFAULTS_FILE=""
  return 1
}

# Dump one database to dest (.sql.gz). Prefers mysqldump; falls back to clpctl db:export.
dump_database() {
  local db_name="$1" dest="$2"
  ensure_mysql_defaults || true
  if mysql_cli --batch -N -e "SELECT 1" >/dev/null 2>&1; then
    mysqldump_cli --single-transaction --quick --routines --triggers \
      --skip-dump-date \
      --default-character-set=utf8mb4 \
      "${db_name}" | gzip -c >"${dest}"
    return 0
  fi
  log_info "Exporting ${db_name} via clpctl db:export (read-only)"
  clpctl db:export --databaseName="${db_name}" --file="${dest}"
}

# Run mysql on the standby using CloudPanel master credentials.
# mode: query <sql> | exec-file <path> | import-gz <db> <gz>
# Never probe passwordless mysql — it can hang on a password prompt.
_remote_mysql() {
  remote bash -s -- "$@" <<'EOS'
set -euo pipefail
echo "standby-mysql: mode=$1" >&2
python3 - "$@" <<'PY'
import os, re, subprocess, sys, tempfile

mode = sys.argv[1]
args = sys.argv[2:]
os.environ.pop("MYSQL_HOST", None)
os.environ.pop("MYSQL_UNIX_PORT", None)

def grab(text, *labels):
    for lab in labels:
        m = re.search(rf'(?im)(?:\|\s*)?{lab}\s*(?:\||:)\s*([^\s|]+)', text)
        if m:
            return m.group(1).strip().strip("'\"")
    return ""

def q(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

def write_cnf(user, password, host="127.0.0.1", port="3306"):
    fd, path = tempfile.mkstemp(prefix="clp-mysql-", dir="/var/tmp")
    os.chmod(path, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(
            "[client]\n"
            f"user={q(user)}\n"
            f"password={q(password)}\n"
            f"host={q(host)}\n"
            f"port={q(port)}\n"
            "protocol=tcp\n"
            "connect-timeout=10\n"
        )
    return path

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
    return user, password, port, out

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

def repair_root_localhost(admin_cmd, user, password):
    # 127.0.0.1 often reverse-DNSes to localhost, so CloudPanel's
    # root@127.0.0.1 password never matches. Allow the same password on
    # root@localhost (keep unix_socket as an OR plugin when MariaDB supports it).
    escaped = password.replace("\\", "\\\\").replace("'", "''")
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
            subprocess.check_call(
                admin_cmd + ["-e", sql],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            continue

def mysql_cmd():
    user, password, port, _raw = parse_clpctl()
    temps = []
    try:
        cnf = write_cnf(user, password, "127.0.0.1", port)
        temps.append(cnf)
        tcp = [
            "mysql",
            f"--defaults-file={cnf}",
            "--batch",
            "--raw",
            "--quick",
        ]
        if probe(tcp):
            print("standby-mysql: auth=cloudpanel-tcp", flush=True)
            return tcp, temps

        print(
            "standby-mysql: cloudpanel TCP failed (likely root@localhost unix_socket / 1698)",
            flush=True,
        )

        debian = "/etc/mysql/debian.cnf"
        if os.path.isfile(debian):
            deb = [
                "mysql",
                f"--defaults-file={debian}",
                "--batch",
                "--raw",
                "--quick",
            ]
            if probe(deb):
                print("standby-mysql: auth=debian-sys-maint; repairing root@localhost", flush=True)
                repair_root_localhost(deb, user, password)
                if probe(tcp):
                    print("standby-mysql: auth=cloudpanel-tcp after repair", flush=True)
                    return tcp, temps
                print("standby-mysql: auth=debian-sys-maint", flush=True)
                return deb, temps

        sys.exit(
            "standby mysql auth failed: CloudPanel root@127.0.0.1 was rejected as "
            "root@localhost (ERROR 1698) and /etc/mysql/debian.cnf is missing or unusable"
        )
    except BaseException:
        for path in temps:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise

cmd, temps = mysql_cmd()
try:
    if mode == "query":
        subprocess.check_call(cmd + ["-N", "-e", args[0]], stdin=subprocess.DEVNULL, timeout=60)
    elif mode == "exec-file":
        print(f"standby-mysql: exec {args[0]}", flush=True)
        with open(args[0], "rb") as stdin:
            subprocess.check_call(cmd, stdin=stdin, timeout=120)
    elif mode == "import-gz":
        db, gz = args[0], args[1]
        if not re.fullmatch(r"[A-Za-z0-9_]+", db):
            sys.exit(f"refusing unsafe database name: {db}")
        print(f"standby-mysql: create database {db}", flush=True)
        subprocess.check_call(
            cmd + ["-N", "-e", f"CREATE DATABASE IF NOT EXISTS `{db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"],
            stdin=subprocess.DEVNULL,
            timeout=30,
        )
        sql_path = gz[:-3] if gz.endswith(".gz") else gz + ".sql"
        print(f"standby-mysql: decompress {gz}", flush=True)
        with open(sql_path, "wb") as outf:
            subprocess.check_call(["gunzip", "-c", gz], stdout=outf, timeout=180)
        print(f"standby-mysql: import {db}", flush=True)
        with open(sql_path, "rb") as inf:
            subprocess.check_call(cmd + [db], stdin=inf, timeout=600)
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
PY
EOS
}

remote_mysql_query() {
  _remote_mysql query "$1"
}

# Run a SQL string on the standby with CloudPanel MySQL credentials.
remote_mysql_sql() {
  local sql="$1"
  local f="${CLP_SYNC_TMP_DIR}/remote-one.sql"
  local rsync_ssh rc=0
  rsync_ssh="$(rsync_ssh_cmd)"
  printf '%s\n' "${sql}" >"${f}"
  chmod 600 "${f}"
  remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
  rsync -a -e "${rsync_ssh}" "${f}" "$(standby_target):/var/tmp/clp-sync-import/remote-one.sql"
  remote_mysql_file /var/tmp/clp-sync-import/remote-one.sql || rc=$?
  remote "rm -f /var/tmp/clp-sync-import/remote-one.sql" || true
  return "${rc}"
}

# Run a SQL file on the standby with that host's CloudPanel MySQL credentials.
remote_mysql_file() {
  _remote_mysql exec-file "$1"
}

remote_mysql_import_gz() {
  local db_name="$1" remote_gz="$2"
  _remote_mysql import-gz "${db_name}" "${remote_gz}"
}
