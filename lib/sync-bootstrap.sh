#!/usr/bin/env bash
# Ensure sites and databases exist on the standby (idempotent).

_panel_has_database() {
  local db_name="$1"
  remote "sqlite3 '${CLP_DB_PATH}' \"SELECT id FROM \\\"database\\\" WHERE name = '$(sql_escape "${db_name}")' LIMIT 1;\"" 2>/dev/null || true
}

bootstrap_site_on_standby() {
  local domain="$1" site_user="$2" site_type="$3" php_version="$4" vhost_template="${5:-Generic}"
  local password exists add_rc=0

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

  exists="$(remote "sqlite3 '${CLP_DB_PATH}' \"SELECT id FROM site WHERE domain_name = '$(sql_escape "${domain}")' LIMIT 1;\"")" || true
  if [[ -n "${exists}" ]]; then
    log_info "Standby already has site ${domain} (id=${exists})"
    return 0
  fi

  password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  [[ -n "${php_version}" ]] || php_version="8.3"
  vhost_template="Generic"

  # Failed prior runs can leave a Linux user and/or /home/<user> without a panel
  # site. CloudPanel then errors: "siteUser: This value already exists."
  log_info "Clearing orphan Linux user/home for ${site_user} on standby (panel has no site yet)"
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

  log_info "Creating ${site_type} site on standby: ${domain} (user=${site_user})"

  set +e
  case "${site_type}" in
    php)
      remote clpctl site:add:php \
        --domainName="${domain}" \
        --phpVersion="${php_version}" \
        --vhostTemplate="Generic" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}"
      add_rc=$?
      ;;
    nodejs)
      remote clpctl site:add:nodejs \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --nodejsVersion=22 \
        --appPort=3000
      add_rc=$?
      ;;
    python)
      remote clpctl site:add:python \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --pythonVersion=3.12 \
        --appPort=8080
      add_rc=$?
      ;;
    static)
      remote clpctl site:add:static \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}"
      add_rc=$?
      ;;
    reverse-proxy)
      remote clpctl site:add:reverse-proxy \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --reverseProxyUrl="http://127.0.0.1:8080"
      add_rc=$?
      ;;
    *)
      set -e
      log_warn "No bootstrap handler for type=${site_type} domain=${domain}"
      return 0
      ;;
  esac
  set -e

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

  if [[ "${add_rc}" -ne 0 ]]; then
    log_error "clpctl site:add failed for ${domain} (exit ${add_rc})"
    return "${add_rc}"
  fi

  log_ok "Created site ${domain} on standby"
}

_clpctl_db_add() {
  local domain="$1" db_name="$2" db_user="$3" password="$4"
  local logf="/var/tmp/clp-sync-import/db-add.log"
  remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
  remote bash -s -- "${domain}" "${db_name}" "${db_user}" "${password}" "${logf}" <<'EOS'
set +e
domain="$1"; db_name="$2"; db_user="$3"; password="$4"; logf="$5"
{
  echo "clpctl db:add domain=${domain} db=${db_name} user=${db_user}"
  clpctl db:add \
    --domainName="${domain}" \
    --databaseName="${db_name}" \
    --databaseUserName="${db_user}" \
    --databaseUserPassword="${password}"
  echo "EXIT=$?"
} >"${logf}" 2>&1
exit 0
EOS
  remote "cat ${logf}" || true
}

_standby_drop_mysql_db_user() {
  local db_name="$1" db_user="$2"
  remote_mysql_sql "DROP DATABASE IF EXISTS \`${db_name}\`; DROP USER IF EXISTS '${db_user}'@'localhost'; DROP USER IF EXISTS '${db_user}'@'127.0.0.1'; DROP USER IF EXISTS '${db_user}'@'%'; FLUSH PRIVILEGES;"
}

bootstrap_database_on_standby() {
  local domain="$1" db_name="$2" db_user="$3" site_user="$4"
  local password exists add_out

  [[ -n "${db_name}" ]] || return 0
  [[ -n "${db_user}" ]] || db_user="${db_name}"

  exists="$(_panel_has_database "${db_name}")"
  if [[ -n "${exists}" ]]; then
    log_info "Standby already has database ${db_name}"
    return 0
  fi

  # clpctl rejects many app .env passwords (policy). Use a compliant password;
  # sync_mysql reconcile_db_passwords will set the real app password after import.
  password="Clp$(openssl rand -hex 8)Aa1!"

  log_info "Creating database ${db_name} for ${domain} on standby"
  add_out="$(_clpctl_db_add "${domain}" "${db_name}" "${db_user}" "${password}")"
  if [[ "${add_out}" == *EXIT=0* ]] || [[ "${add_out}" == *"has been added"* ]]; then
    log_ok "Created database ${db_name}"
    return 0
  fi

  log_warn "db:add failed for ${db_name}:"
  printf '%s\n' "${add_out}" >&2

  log_info "Dropping orphan MySQL objects for ${db_name} on standby, then retrying"
  _standby_drop_mysql_db_user "${db_name}" "${db_user}" || true

  add_out="$(_clpctl_db_add "${domain}" "${db_name}" "${db_user}" "${password}")"
  if [[ "${add_out}" == *EXIT=0* ]] || [[ "${add_out}" == *"has been added"* ]]; then
    log_ok "Created database ${db_name} after cleanup"
    return 0
  fi

  log_error "db:add still failed for ${db_name}:"
  printf '%s\n' "${add_out}" >&2
  return 1
}

run_bootstrap() {
  local db_snap="$1"
  local id domain user type php_ver vhost
  local site_id domain_name site_user db_name db_user
  local n

  n="$(inventory_sites "${db_snap}" | grep -c . || true)"
  log_info "Bootstrapping missing sites on standby (${n} site(s) in master inventory)"
  while IFS=$'\t' read -r id domain user type php_ver vhost; do
    [[ -n "${domain}" ]] || continue
    log_info "Inventory site: ${domain} user=${user} type=${type}"
    bootstrap_site_on_standby "${domain}" "${user}" "${type}" "${php_ver}" "${vhost}"
  done < <(inventory_sites "${db_snap}")

  log_info "Bootstrapping missing databases on standby"
  while IFS=$'\t' read -r site_id domain_name site_user db_name db_user; do
    [[ -n "${db_name}" ]] || continue
    bootstrap_database_on_standby "${domain_name}" "${db_name}" "${db_user}" "${site_user}"
  done < <(inventory_databases "${db_snap}")
}
