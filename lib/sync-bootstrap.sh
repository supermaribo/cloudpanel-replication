#!/usr/bin/env bash
# Ensure sites and databases exist on the standby (idempotent).

_panel_has_database() {
  local db_name="$1"
  remote bash -s -- "${CLP_DB_PATH}" "${db_name}" <<'EOS'
python3 - "$1" "$2" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
name = sys.argv[2]
for table in ("database", "databases"):
    try:
        row = con.execute(f'SELECT id FROM "{table}" WHERE name = ? LIMIT 1', (name,)).fetchone()
        if row:
            print(row[0])
            break
    except sqlite3.Error:
        pass
PY
EOS
}

_ensure_linux_site_user() {
  local site_user="$1"
  [[ -n "${site_user}" ]] || return 0
  case "${site_user}" in
    root|clp|mysql|www-data|nginx|nobody|daemon) return 0 ;;
  esac
  remote bash -s -- "${site_user}" <<'EOS'
set -u
u="$1"
mkdir -p "/home/${u}" "/home/${u}/logs/nginx" "/home/${u}/htdocs" 2>/dev/null || true
if id -u "$u" >/dev/null 2>&1; then
  chown -R "${u}:${u}" "/home/${u}/logs" 2>/dev/null || true
  exit 0
fi
getent group "$u" >/dev/null 2>&1 || groupadd "$u"
if ! useradd -m -d "/home/${u}" -s /bin/bash -g "$u" "$u" 2>/dev/null; then
  useradd -m -d "/home/${u}" -s /bin/bash "$u"
fi
mkdir -p "/home/${u}" "/home/${u}/logs/nginx" "/home/${u}/htdocs"
chown -R "${u}:${u}" "/home/${u}/logs" 2>/dev/null || true
chown "${u}:${u}" "/home/${u}" 2>/dev/null || true
echo "created linux user ${u}"
EOS
}

_standby_site_id() {
  local domain="$1"
  remote bash -s -- "${CLP_DB_PATH}" "${domain}" <<'EOS'
python3 - "$1" "$2" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=15)
con.execute("PRAGMA busy_timeout=15000")
row = con.execute("SELECT id FROM site WHERE domain_name = ? LIMIT 1", (sys.argv[2],)).fetchone()
if row:
    print(row[0])
PY
EOS
}

bootstrap_site_on_standby() {
  local domain="$1" site_user="$2" site_type="$3" php_version="$4" vhost_template="${5:-Generic}"
  local password exists add_out add_rc=0

  domain="${domain//$'\r'/}"
  site_user="${site_user//$'\r'/}"
  site_type="${site_type,,}"
  site_type="${site_type//$'\r'/}"
  case "${site_type}" in
    php|wordpress|woocommerce|"") site_type=php ;;
    node|node.js|nodejs) site_type=nodejs ;;
    reverse_proxy|reverseproxy) site_type=reverse-proxy ;;
  esac
  if ! site_type_allowed "${site_type}"; then
    log_warn "Unknown type '${site_type}' for ${domain}; treating as php"
    site_type=php
  fi

  [[ -n "${domain}" ]] || return 0

  exists="$(_standby_site_id "${domain}" 2>/dev/null || true)"
  exists="${exists//$'\r'/}"
  if [[ "${exists}" =~ ^[0-9]+$ ]]; then
    log_info "Standby already has site ${domain} (id=${exists})"
    _ensure_linux_site_user "${site_user}"
    return 0
  fi

  password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  [[ -n "${php_version}" ]] || php_version="8.3"
  vhost_template="Generic"

  log_info "Creating ${site_type} site on standby: ${domain} (user=${site_user})"
  add_out="$(_clpctl_site_add "${site_type}" "${domain}" "${php_version}" "${site_user}" "${password}")"
  add_rc="${add_out##*EXIT=}"
  add_rc="${add_rc%%$'\n'*}"
  if [[ "${add_out}" == *"has been added"* ]] || [[ "${add_rc}" == "0" ]]; then
    log_ok "Created site ${domain} on standby"
    return 0
  fi
  if [[ "${add_out}" == *"already exists"* ]]; then
    log_info "Standby already has ${domain} (clpctl: already exists)"
    _ensure_linux_site_user "${site_user}"
    return 0
  fi

  # Only now treat a leftover Linux user as an orphan blocking site:add.
  if [[ "${add_out}" == *"siteUser"* ]]; then
    log_info "Clearing orphan Linux user/home for ${site_user} on standby, then retrying site:add"
    remote bash -s -- "${site_user}" <<'EOS'
set -u
u="$1"
case "$u" in
  ""|root|clp|mysql|www-data|nginx|nobody|daemon) echo "refusing to modify protected user $u" >&2; exit 2 ;;
esac
mkdir -p /var/tmp/clp-sync-prehome
if [[ -d "/home/${u}" ]]; then
  rm -rf "/var/tmp/clp-sync-prehome/${u}"
  mv "/home/${u}" "/var/tmp/clp-sync-prehome/${u}"
fi
if id -u "$u" >/dev/null 2>&1; then
  pkill -KILL -u "$u" 2>/dev/null || true
  userdel -f "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
fi
if getent group "$u" >/dev/null 2>&1; then
  groupdel "$u" 2>/dev/null || true
fi
if [[ -d "/home/${u}" ]]; then
  rm -rf "/var/tmp/clp-sync-prehome/${u}"
  mv "/home/${u}" "/var/tmp/clp-sync-prehome/${u}"
fi
exit 0
EOS
    add_out="$(_clpctl_site_add "${site_type}" "${domain}" "${php_version}" "${site_user}" "${password}")"
    add_rc="${add_out##*EXIT=}"
    add_rc="${add_rc%%$'\n'*}"
    remote bash -s -- "${site_user}" <<'EOS'
set -u
u="$1"
pre="/var/tmp/clp-sync-prehome/${u}"
home="/home/${u}"
if [[ -d "${pre}" ]]; then
  mkdir -p "${home}"
  rsync -a "${pre}/" "${home}/"
  if id -u "$u" >/dev/null 2>&1; then
    chown -R "${u}:${u}" "${home}" 2>/dev/null || true
  fi
  rm -rf "${pre}"
fi
EOS
    if [[ "${add_out}" == *"has been added"* || "${add_out}" == *"already exists"* || "${add_rc}" == "0" ]]; then
      log_ok "Created site ${domain} on standby"
      return 0
    fi
  fi

  log_error "clpctl site:add failed for ${domain}: ${add_out}"
  return 1
}

_clpctl_site_add() {
  local site_type="$1" domain="$2" php_version="$3" site_user="$4" password="$5"
  local rc out
  set +e
  case "${site_type}" in
    php)
      out="$(remote clpctl site:add:php \
        --domainName="${domain}" \
        --phpVersion="${php_version}" \
        --vhostTemplate="Generic" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" 2>&1)"
      ;;
    nodejs)
      out="$(remote clpctl site:add:nodejs \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --nodejsVersion=22 \
        --appPort=3000 2>&1)"
      ;;
    python)
      out="$(remote clpctl site:add:python \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --pythonVersion=3.12 \
        --appPort=8080 2>&1)"
      ;;
    static)
      out="$(remote clpctl site:add:static \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" 2>&1)"
      ;;
    reverse-proxy)
      out="$(remote clpctl site:add:reverse-proxy \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --reverseProxyUrl="http://127.0.0.1:8080" 2>&1)"
      ;;
    *)
      set -e
      echo "EXIT=0"
      return 0
      ;;
  esac
  rc=$?
  set -e
  printf '%s\n' "${out}"
  echo "EXIT=${rc}"
}

_clpctl_db_add() {
  local domain="$1" db_name="$2" db_user="$3" password="$4"
  local rc out
  # Same argv path as site:add. Do not pass -vvv: /usr/bin/clpctl is a bash
  # wrapper that treats the first token as the command name.
  set +e
  out="$(remote clpctl db:add \
    --domainName="${domain}" \
    --databaseName="${db_name}" \
    --databaseUserName="${db_user}" \
    --databaseUserPassword="${password}" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${out}"
  echo "EXIT=${rc}"
  return 0
}

_standby_purge_panel_db_rows() {
  local db_name="$1" db_user="$2"
  remote bash -s -- "${CLP_DB_PATH}" "${db_name}" "${db_user}" <<'EOS'
python3 - "$1" "$2" "$3" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
db_name, db_user = sys.argv[2], sys.argv[3]
try:
    con.execute("DELETE FROM database_user WHERE user_name = ?", (db_user,))
except sqlite3.Error:
    pass
for table in ("database", "databases"):
    try:
        con.execute(f'DELETE FROM "{table}" WHERE name = ?', (db_name,))
    except sqlite3.Error:
        pass
con.commit()
print("purged panel sqlite rows for", db_name, db_user)
PY
EOS
}

_standby_ensure_mysql_database() {
  local db_name="$1" db_user="$2" password="$3"
  local sql_db sql_user sql_pass
  if [[ ! "${db_name}" =~ ^[A-Za-z0-9_]+$ ]] || [[ ! "${db_user}" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "Refusing unsafe MySQL identifier db=${db_name} user=${db_user}"
    return 1
  fi
  sql_db="${db_name}"
  sql_user="${db_user}"
  sql_pass="$(printf '%s' "${password}" | sed "s/'/''/g")"
  remote_mysql_sql "$(cat <<SQL
CREATE DATABASE IF NOT EXISTS \`${sql_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${sql_user}'@'localhost' IDENTIFIED BY '${sql_pass}';
CREATE USER IF NOT EXISTS '${sql_user}'@'127.0.0.1' IDENTIFIED BY '${sql_pass}';
ALTER USER IF EXISTS '${sql_user}'@'localhost' IDENTIFIED BY '${sql_pass}';
ALTER USER IF EXISTS '${sql_user}'@'127.0.0.1' IDENTIFIED BY '${sql_pass}';
GRANT ALL PRIVILEGES ON \`${sql_db}\`.* TO '${sql_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${sql_db}\`.* TO '${sql_user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
)"
}

bootstrap_database_on_standby() {
  local domain="$1" db_name="$2" db_user="$3" site_user="$4"
  local mysql_pass app_pass

  [[ -n "${db_name}" ]] || return 0
  [[ -n "${db_user}" ]] || db_user="${db_name}"
  domain="${domain//$'\r'/}"
  site_user="${site_user//$'\r'/}"

  mysql_pass="Clp$(openssl rand -hex 8)Aa1#"
  if app_pass="$(guess_db_password "${site_user}" "${domain}" "${db_name}")"; then
    mysql_pass="${app_pass}"
  fi

  log_info "Ensuring MySQL database ${db_name} (${db_user}@${domain}) on standby"
  if _standby_ensure_mysql_database "${db_name}" "${db_user}" "${mysql_pass}"; then
    log_ok "MySQL database ${db_name} ready on standby"
    return 0
  fi
  log_error "Could not create MySQL database ${db_name} on standby"
  return 1
}

run_bootstrap() {
  local db_snap="$1"
  local id domain user type php_ver vhost
  local n site_fail=0

  n="$(inventory_sites "${db_snap}" | grep -c . || true)"
  log_info "Step 1/5: CloudPanel sites (${n} in master inventory)"
  while IFS=$'\t' read -r id domain user type php_ver vhost; do
    domain="${domain//$'\r'/}"
    user="${user//$'\r'/}"
    if [[ -z "${domain}" ]]; then
      log_warn "Skipping site id=${id:-?} user=${user:-?} (empty domain_name)"
      continue
    fi
    log_info "Inventory site: ${domain} user=${user} type=${type}"
    if ! bootstrap_site_on_standby "${domain}" "${user}" "${type}" "${php_ver}" "${vhost}"; then
      site_fail=$((site_fail + 1))
    fi
  done < <(inventory_sites "${db_snap}")
  if [[ "${site_fail}" -gt 0 ]]; then
    log_warn "${site_fail} site(s) failed to create — continuing with remaining sync steps"
  fi
}

ensure_inventory_linux_users() {
  local db_snap="$1" user
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    _ensure_linux_site_user "${user}"
  done < <(inventory_site_users "${db_snap}")
}

run_bootstrap_databases() {
  local db_snap="$1"
  local site_id domain_name site_user db_name db_user
  local db_fail=0 n

  n="$(inventory_databases "${db_snap}" | grep -c . || true)"
  log_info "Step 5/5: Databases (${n} in master inventory)"
  while IFS=$'\t' read -r site_id domain_name site_user db_name db_user; do
    [[ -n "${db_name}" ]] || continue
    if ! bootstrap_database_on_standby "${domain_name}" "${db_name}" "${db_user}" "${site_user}"; then
      db_fail=$((db_fail + 1))
    fi
  done < <(inventory_databases "${db_snap}")
  if [[ "${db_fail}" -gt 0 ]]; then
    log_error "${db_fail} database(s) failed to provision on standby"
    return 1
  fi
}
