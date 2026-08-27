#!/usr/bin/env bash
# SSL / Let's Encrypt / PHP-FPM / nginx — rsync deltas; reload only when files changed.

sync_nginx_ssl() {
  local changed=0

  log_info "Syncing nginx / SSL configs (changed files only)"

  for dir in sites-enabled sites-available ssl-certificates conf.d modules-enabled cloudflare; do
    if [[ -e "/etc/nginx/${dir}" ]]; then
      rsync_to_standby "/etc/nginx/${dir}" /etc/nginx/
      [[ "${RSYNC_CHANGED}" -eq 1 ]] && changed=1
    fi
  done

  for dir in /etc/letsencrypt /var/lib/letsencrypt; do
    if [[ -d "${dir}" ]]; then
      remote "mkdir -p '${dir}'"
      rsync_to_standby "${dir}/" "${dir}/"
      [[ "${RSYNC_CHANGED}" -eq 1 ]] && changed=1
    fi
  done

  for path in /home/clp/.acme.sh /home/clp/acme /home/clp/etc/ssl; do
    if [[ -e "${path}" ]]; then
      remote "mkdir -p '$(dirname "${path}")'"
      rsync_to_standby "${path}" "$(dirname "${path}")/"
      [[ "${RSYNC_CHANGED}" -eq 1 ]] && changed=1
    fi
  done

  if [[ "${changed}" -eq 1 ]]; then
    INC_CFG_CHANGES=$((INC_CFG_CHANGES + 1))
  fi

  if [[ "${RELOAD_NGINX_ON_STANDBY}" == "1" && "${changed}" -eq 1 ]]; then
    log_info "Testing and reloading nginx on standby"
    if remote "nginx -t && (systemctl reload nginx || systemctl reload cloudpanel-nginx || true)"; then
      log_ok "Nginx reloaded on standby"
    else
      log_warn "Nginx reload on standby failed — check configs manually"
    fi
  elif [[ "${changed}" -eq 0 ]]; then
    log_info "Nginx/SSL unchanged — skip reload"
  fi
}

sync_php_fpm_pools() {
  local any=0
  local changed=0
  local pool_dir

  log_info "Syncing PHP-FPM pool configs (changed files only)"
  shopt -s nullglob
  for pool_dir in /etc/php/*/fpm/pool.d; do
    [[ -d "${pool_dir}" ]] || continue
    any=1
    remote "mkdir -p '${pool_dir}'"
    rsync_to_standby "${pool_dir}/" "${pool_dir}/"
    [[ "${RSYNC_CHANGED}" -eq 1 ]] && changed=1
  done
  shopt -u nullglob

  if [[ "${any}" -eq 0 ]]; then
    log_info "No PHP-FPM pool.d directories found"
    return 0
  fi

  if [[ "${changed}" -eq 0 ]]; then
    log_info "PHP-FPM pools unchanged — skip reload"
    return 0
  fi

  INC_CFG_CHANGES=$((INC_CFG_CHANGES + 1))
  remote 'for s in php*-fpm php*-fpm.service; do systemctl reload "$s" 2>/dev/null || systemctl restart "$s" 2>/dev/null || true; done; true'
  log_ok "PHP-FPM pools updated and reloaded"
}

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

  local digest
  digest="$(cat "${cron_tmp}"/* | sha256sum | awk '{print $1}')"
  if checksum_eq crons "${digest}"; then
    log_info "Cron files unchanged — skip"
    INC_SKIPPED=$((INC_SKIPPED + 1))
    return 0
  fi

  log_info "Syncing site cron.d files to standby"
  for cron_file in "${cron_tmp}"/*; do
    local base
    base="$(basename "${cron_file}")"
    chmod 644 "${cron_file}"
    rsync -a -e "${rsync_ssh}" "${cron_file}" "$(standby_target):/etc/cron.d/${base}"
  done
  save_checksum crons "${digest}"
  INC_CFG_CHANGES=$((INC_CFG_CHANGES + 1))
  log_ok "Cron sync complete"
}
