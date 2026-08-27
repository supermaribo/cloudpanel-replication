#!/usr/bin/env bash
# MySQL auth for CloudPanel: root@localhost is often denied without a password.
# Use clpctl db:show:master-credentials (typically root@127.0.0.1).

MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-}"

mysql_cli() {
  if [[ -n "${MYSQL_DEFAULTS_FILE}" ]]; then
    mysql --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"
  else
    mysql "$@"
  fi
}

mysqldump_cli() {
  if [[ -n "${MYSQL_DEFAULTS_FILE}" ]]; then
    mysqldump --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"
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
m = re.search(r"-h\s*([0-9.]+)", text)
if m:
    host = m.group(1)
if not password:
    sys.exit(1)
print(f"{user}\t{password}\t{host}\t{port}")
PY
}

# Build a mode-600 mysql client cnf for this run.
ensure_mysql_defaults() {
  local cnf="${CLP_SYNC_TMP_DIR}/mysql-client.cnf"
  mkdir -p "${CLP_SYNC_TMP_DIR}"

  if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]] \
     && mysql --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" --batch -N -e "SELECT 1" >/dev/null 2>&1; then
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
    cat >"${cnf}" <<EOF
[client]
user=${user}
password=${pass}
host=${host}
port=${port}
EOF
    chmod 600 "${cnf}"
    if mysql --defaults-extra-file="${cnf}" --batch -N -e "SELECT 1" >/dev/null 2>&1; then
      MYSQL_DEFAULTS_FILE="${cnf}"
      log_info "MySQL client using CloudPanel master credentials (${user}@${host})"
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

# Run a SQL string on the standby with CloudPanel MySQL credentials.
remote_mysql_sql() {
  local sql="$1"
  local f="${CLP_SYNC_TMP_DIR}/remote-one.sql"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  printf '%s\n' "${sql}" >"${f}"
  chmod 600 "${f}"
  remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
  rsync -a -e "${rsync_ssh}" "${f}" "$(standby_target):/var/tmp/clp-sync-import/remote-one.sql"
  remote_mysql_file /var/tmp/clp-sync-import/remote-one.sql
  remote "rm -f /var/tmp/clp-sync-import/remote-one.sql"
}

# Run a SQL file on the standby with that host's CloudPanel MySQL credentials.
remote_mysql_file() {
  local remote_sql="$1"
  remote bash -s -- "${remote_sql}" <<'EOS'
set -euo pipefail
SQL="$1"
if mysql --batch -N -e "SELECT 1" >/dev/null 2>&1; then
  mysql < "${SQL}"
  exit 0
fi
python3 - "${SQL}" <<'PY'
import os, re, subprocess, sys, tempfile
sql_path = sys.argv[1]
out = subprocess.check_output(["clpctl", "db:show:master-credentials"], text=True, stderr=subprocess.STDOUT)

def grab(*labels):
    for lab in labels:
        m = re.search(rf'(?im)(?:\|\s*)?{lab}\s*(?:\||:)\s*([^\s|]+)', out)
        if m:
            return m.group(1).strip().strip("'\"")
    return ""

user = grab("User Name", "UserName", "Username", "User") or "root"
password = grab("Password")
host = grab("Host") or "127.0.0.1"
port = grab("Port") or "3306"
m = re.search(r"-p'([^']+)'", out)
if m:
    password = m.group(1)
if not password:
    sys.exit("no mysql password from clpctl on standby")
fd, cnf = tempfile.mkstemp(prefix="clp-mysql-", dir="/var/tmp")
os.chmod(cnf, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(f"[client]\nuser={user}\npassword={password}\nhost={host}\nport={port}\n")
try:
    with open(sql_path) as stdin:
        subprocess.check_call(["mysql", f"--defaults-extra-file={cnf}"], stdin=stdin)
finally:
    os.unlink(cnf)
PY
EOS
}
