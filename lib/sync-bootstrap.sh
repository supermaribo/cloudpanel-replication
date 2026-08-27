#!/usr/bin/env bash
# Ensure sites and databases exist on the standby (idempotent).

_panel_has_database() {
  local db_name="$1"
  remote "sqlite3 '${CLP_DB_PATH}' \"SELECT id FROM \\\"database\\\" WHERE name = '$(sql_escape "${db_name}")' LIMIT 1;\"" 2>/dev/null || true
}

bootstrap_site_on_standby() {
  local domain="$1" site_user="$2" site_type="$3" php_version="$4" vhost_template="${5:-Generic}"
  local password exists

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

  if remote "id -u $(printf '%q' "${site_user}") >/dev/null 2>&1"; then
    log_warn "Linux user ${site_user} exists on standby but site ${domain} missing in panel"
  fi

  log_info "Creating ${site_type} site on standby: ${domain} (user=${site_user})"

  case "${site_type}" in
    php)
      remote clpctl site:add:php \
        --domainName="${domain}" \
        --phpVersion="${php_version}" \
        --vhostTemplate="Generic" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}"
      ;;
    nodejs)
      remote clpctl site:add:nodejs \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --nodejsVersion=22 \
        --appPort=3000
      ;;
    python)
      remote clpctl site:add:python \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --pythonVersion=3.12 \
        --appPort=8080
      ;;
    static)
      remote clpctl site:add:static \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}"
      ;;
    reverse-proxy)
      remote clpctl site:add:reverse-proxy \
        --domainName="${domain}" \
        --siteUser="${site_user}" \
        --siteUserPassword="${password}" \
        --reverseProxyUrl="http://127.0.0.1:8080"
      ;;
    *)
      log_warn "No bootstrap handler for type=${site_type} domain=${domain}"
      return 0
      ;;
  esac

  log_ok "Created site ${domain} on standby"
}

_clpctl_db_add() {
  local domain="$1" db_name="$2" db_user="$3" password="$4"
  remote clpctl db:add \
    --domainName="${domain}" \
    --databaseName="${db_name}" \
    --databaseUserName="${db_user}" \
    --databaseUserPassword="${password}"
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

  if password="$(guess_db_password "${site_user}" "${domain}" "${db_name}")"; then
    log_info "Using DB password from app config for ${db_name}"
  else
    password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
    log_warn "Could not find DB password for ${db_name}; generated one (file sync + password reconcile will match the app)."
    echo "${domain}|${db_name}|${db_user}|${password}" >>"${CLP_SYNC_STATE_DIR}/generated-db-passwords.log"
    chmod 600 "${CLP_SYNC_STATE_DIR}/generated-db-passwords.log"
  fi

  log_info "Creating database ${db_name} for ${domain} on standby"
  if add_out="$(_clpctl_db_add "${domain}" "${db_name}" "${db_user}" "${password}" 2>&1)"; then
    log_ok "Created database ${db_name}"
    return 0
  fi

  log_warn "db:add failed for ${db_name}: ${add_out}"
  log_info "Dropping orphan MySQL objects for ${db_name} on standby, then retrying db:add"
  remote_mysql_sql "DROP DATABASE IF EXISTS \`${db_name}\`; DROP USER IF EXISTS '${db_user}'@'localhost'; DROP USER IF EXISTS '${db_user}'@'127.0.0.1'; FLUSH PRIVILEGES;" || true

  if add_out="$(_clpctl_db_add "${domain}" "${db_name}" "${db_user}" "${password}" 2>&1)"; then
    log_ok "Created database ${db_name} after cleanup"
    return 0
  fi

  log_error "db:add still failed for ${db_name}: ${add_out}"
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
