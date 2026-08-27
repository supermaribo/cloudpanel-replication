#!/usr/bin/env bash
# Full SSL / Let's Encrypt certificate mirror + PHP-FPM pools + nginx site config.

sync_nginx_ssl() {
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local changed=0

  log_info "Syncing nginx site configs (full mirror)"

  for dir in sites-enabled sites-available ssl-certificates conf.d modules-enabled cloudflare; do
    if [[ -e "/etc/nginx/${dir}" ]]; then
      log_info "rsync /etc/nginx/${dir}"
      rsync -a --delete -e "${rsync_ssh}" \
        "/etc/nginx/${dir}" \
        "$(standby_target):/etc/nginx/"
      changed=1
    fi
  done

  # ACME / certbot state if present (some installs / custom tooling)
  for dir in /etc/letsencrypt /var/lib/letsencrypt; do
    if [[ -d "${dir}" ]]; then
      log_info "rsync ${dir}"
      remote "mkdir -p '${dir}'"
      rsync -a --delete -e "${rsync_ssh}" "${dir}/" "$(standby_target):${dir}/"
      changed=1
    fi
  done

  # CloudPanel ACME / SSL helpers under panel home (if present)
  for path in /home/clp/.acme.sh /home/clp/acme /home/clp/etc/ssl; do
    if [[ -e "${path}" ]]; then
      log_info "rsync ${path}"
      remote "mkdir -p '$(dirname "${path}")'"
      rsync -a -e "${rsync_ssh}" "${path}" "$(standby_target):$(dirname "${path}")/"
      changed=1
    fi
  done

  if [[ "${RELOAD_NGINX_ON_STANDBY}" == "1" && "${changed}" -eq 1 ]]; then
    log_info "Testing and reloading nginx on standby"
    if remote "nginx -t && (systemctl reload nginx || systemctl reload cloudpanel-nginx || true)"; then
      log_ok "Nginx reloaded on standby"
    else
      log_warn "Nginx reload on standby failed — check configs manually"
    fi
  fi
}

# Mirror PHP-FPM pool configs so nginx upstream ports match the primary.
sync_php_fpm_pools() {
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local any=0
  local pool_dir

  log_info "Syncing PHP-FPM pool configs"
  shopt -s nullglob
  for pool_dir in /etc/php/*/fpm/pool.d; do
    [[ -d "${pool_dir}" ]] || continue
    any=1
    remote "mkdir -p '${pool_dir}'"
    rsync -a --delete -e "${rsync_ssh}" \
      "${pool_dir}/" \
      "$(standby_target):${pool_dir}/"
  done
  shopt -u nullglob

  if [[ "${any}" -eq 0 ]]; then
    log_info "No PHP-FPM pool.d directories found"
    return 0
  fi

  remote 'for s in php*-fpm php*-fpm.service; do systemctl reload "$s" 2>/dev/null || systemctl restart "$s" 2>/dev/null || true; done; true'
  log_ok "PHP-FPM pools mirrored and reloaded"
}

# Rewrite /etc/cron.d/<siteUser> on standby from primary inventory.
sync_crons() {
  local db_snap="$1"
  local cron_tmp="${CLP_SYNC_TMP_DIR}/crons"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"

  rm -rf "${cron_tmp}"
  mkdir -p "${cron_tmp}"

  local site_user minute hour day month weekday command
  local current_user=""
  local cron_file=""

  while IFS='|' read -r site_user minute hour day month weekday command; do
    [[ -n "${site_user}" && -n "${command}" ]] || continue
    if [[ "${site_user}" != "${current_user}" ]]; then
      current_user="${site_user}"
      cron_file="${cron_tmp}/${site_user}"
      {
        echo "# Managed by clp-sync — identical mirror of primary"
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
      } >"${cron_file}"
    fi
    echo "${minute} ${hour} ${day} ${month} ${weekday} ${site_user} ${command}" >>"${cron_file}"
  done < <(inventory_crons "${db_snap}")

  # Also copy any primary /etc/cron.d files named after site users (belt and suspenders)
  while IFS= read -r site_user; do
    [[ -n "${site_user}" ]] || continue
    if [[ -f "/etc/cron.d/${site_user}" && ! -f "${cron_tmp}/${site_user}" ]]; then
      cp -a "/etc/cron.d/${site_user}" "${cron_tmp}/${site_user}"
    fi
  done < <(inventory_site_users "${db_snap}")

  if [[ -z "$(ls -A "${cron_tmp}" 2>/dev/null || true)" ]]; then
    log_info "No site cron jobs to sync"
    return 0
  fi

  log_info "Syncing site cron.d files to standby"
  for cron_file in "${cron_tmp}"/*; do
    local base
    base="$(basename "${cron_file}")"
    chmod 644 "${cron_file}"
    rsync -a -e "${rsync_ssh}" "${cron_file}" "$(standby_target):/etc/cron.d/${base}"
  done
  log_ok "Cron sync complete"
}
