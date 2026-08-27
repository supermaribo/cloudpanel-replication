#!/usr/bin/env bash
# MySQL auth for CloudPanel: root@localhost is unix_socket (ERROR 1698).
# Prefer an exclusive defaults-file (not extra-file) so ~/.my.cnf cannot
# force a Unix socket. On the standby, use lib/standby-mysql.py.

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

# Quote only the password. host/protocol must stay unquoted so the client
# uses TCP to 127.0.0.1. Do not put connect-timeout here — mysqldump rejects it.
lines = [
    "[client]",
    "user=" + os.environ["MYSQL_CNF_USER"],
    "password=" + q(os.environ["MYSQL_CNF_PASS"]),
    "host=" + (os.environ.get("MYSQL_CNF_HOST") or "127.0.0.1"),
    "port=" + (os.environ.get("MYSQL_CNF_PORT") or "3306"),
    "protocol=tcp",
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
    if mysqldump_cli --single-transaction --quick --routines --triggers \
      --skip-dump-date \
      --set-gtid-purged=OFF \
      --default-character-set=utf8mb4 \
      "${db_name}" | gzip -c >"${dest}" && [[ -s "${dest}" ]]; then
      return 0
    fi
    log_warn "mysqldump failed for ${db_name}; falling back to clpctl db:export"
    rm -f "${dest}"
  fi
  log_info "Exporting ${db_name} via clpctl db:export (read-only)"
  clpctl db:export --databaseName="${db_name}" --file="${dest}"
}

# Standby mysql client: unix socket root, no ~/.my.cnf, no python.
# Stdin is forwarded (dump import). Extra args are appended on the remote side.
_standby_mysql() {
  local extra=""
  extra="$(printf '%q ' "$@")"
  ssh_opts
  ssh "${SSH_OPTS[@]}" -o ServerAliveInterval=5 -o ServerAliveCountMax=120 \
    "$(standby_target)" \
    "m=/usr/bin/mysql; [ -x \"\$m\" ] || m=\$(command -v mysql)
     [ -n \"\$m\" ] || { echo standby-mysql: mysql client missing >&2; exit 1; }
     sock=/run/mysqld/mysqld.sock; [ -S \"\$sock\" ] || sock=/var/run/mysqld/mysqld.sock
     [ -S \"\$sock\" ] || { echo standby-mysql: no mysqld socket >&2; exit 1; }
     exec \"\$m\" --no-defaults -u root --protocol=SOCKET --socket=\"\$sock\" --skip-password --batch --force --binary-mode --max-allowed-packet=512M ${extra}"
}

kill_stale_standby_imports() {
  remote 'pkill -f /var/tmp/clp-sync-import 2>/dev/null || true
    pkill -f standby-mysql.py 2>/dev/null || true
    true'
}

# Dump is local .sql.gz. CREATE DATABASE then stream gunzip | ssh mysql.
import_database_standby() {
  local db_name="$1" dump_gz="$2"
  [[ "${db_name}" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  [[ -s "${dump_gz}" ]] || return 1

  kill_stale_standby_imports

  log_info "CREATE DATABASE ${db_name} on standby"
  if ! _standby_mysql -N -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"; then
    log_error "CREATE DATABASE ${db_name} failed on standby"
    return 1
  fi

  log_info "Streaming ${db_name} into standby mysql (dump | ssh, socket root)"
  if ! gunzip -c "${dump_gz}" \
      | grep -v 'sandbox mode' \
      | grep -v '^SET @@GLOBAL.GTID_PURGED' \
      | _standby_mysql --init-command='SET SESSION FOREIGN_KEY_CHECKS=0; SET SESSION UNIQUE_CHECKS=0;' "${db_name}"; then
    log_error "Import stream failed for ${db_name}"
    return 1
  fi
  return 0
}

remote_mysql_query() {
  _standby_mysql -N -e "$1"
}

remote_mysql_sql() {
  _standby_mysql -e "$1"
}

remote_mysql_file() {
  local sql_file="$1"
  _standby_mysql <"${sql_file}"
}

remote_mysql_import_gz() {
  import_database_standby "$1" "$2"
}
