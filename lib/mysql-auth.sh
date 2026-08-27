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

# Run mysql on the standby using CloudPanel master credentials.
# mode: query <sql> | exec-file <path> | import-gz <db> <gz>
# Never probe passwordless mysql — it can hang on a password prompt.
_remote_mysql() {
  local helper="${CLP_SYNC_ROOT}/lib/standby-mysql.py"
  local rsync_ssh remote_helper="/var/tmp/clp-sync-import/standby-mysql.py"
  [[ -f "${helper}" ]] || die "Missing ${helper}"
  rsync_ssh="$(rsync_ssh_cmd)"
  remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
  rsync -a -e "${rsync_ssh}" "${helper}" "$(standby_target):${remote_helper}"
  remote python3 "${remote_helper}" "$@"
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
