#!/usr/bin/env bash
# Standby-side pull: files, nginx/php, panel sqlite, MySQL SOURCE import.

local_mysql() {
  local sock m
  m=/usr/bin/mysql
  [[ -x "${m}" ]] || m="$(command -v mysql)"
  sock=/run/mysqld/mysqld.sock
  [[ -S "${sock}" ]] || sock=/var/run/mysqld/mysqld.sock
  [[ -S "${sock}" ]] || die "local mysqld socket missing"
  "${m}" --no-defaults -u root --protocol=SOCKET --socket="${sock}" \
    --skip-password --batch --force --binary-mode --max-allowed-packet=512M "$@"
}

kill_stale_mysql_imports() {
  pkill -f '/var/tmp/clp-sync' 2>/dev/null || true
  pkill -f 'mysql.*--binary-mode' 2>/dev/null || true
  local ids
  ids="$(local_mysql -N -e "SELECT ID FROM information_schema.processlist WHERE ID != CONNECTION_ID() AND COMMAND != 'Sleep';" 2>/dev/null || true)"
  local id
  for id in ${ids}; do
    [[ "${id}" =~ ^[0-9]+$ ]] || continue
    local_mysql -e "KILL ${id}" 2>/dev/null || true
  done
  true
}

pull_probe() {
  log_info "Probing master ${MASTER_HOST}"
  master_ssh clp-sync-probe | head -5
}

pull_panel_sqlite() {
  local dest="${CLP_SYNC_TMP_DIR}/db.sq3"
  log_info "Pulling CloudPanel sqlite snapshot"
  master_ssh clp-panel-backup >"${dest}"
  [[ -s "${dest}" ]] || die "empty panel snapshot"
  chmod 600 "${dest}"
  sqlite3 "${dest}" "PRAGMA integrity_check;" | grep -qx ok || die "panel snapshot failed integrity_check"
  echo "${dest}"
}

ensure_linux_users() {
  local db_snap="$1"
  local user
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    if ! id -u "${user}" >/dev/null 2>&1; then
      log_info "Creating Linux user ${user}"
      useradd --disabled-password --gecos "" --home "/home/${user}" --shell /bin/bash "${user}" || true
    fi
    mkdir -p "/home/${user}/htdocs" "/home/${user}/logs/nginx"
    chown -R "${user}:${user}" "/home/${user}" 2>/dev/null || true
  done < <(inventory_site_users "${db_snap}")
}

pull_site_files() {
  local db_snap="$1"
  local user excludes="${RSYNC_EXCLUDES_FILE}"
  [[ -f "${excludes}" ]] || die "Missing ${excludes}"
  log_info "Pulling site home directories"
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    mkdir -p "/home/${user}"
    rsync_from_master "/home/${user}/" "/home/${user}/" --exclude-from="${excludes}" \
      || die "could not pull /home/${user}"
    chown -R "${user}:${user}" "/home/${user}" 2>/dev/null || true
  done < <(inventory_site_users "${db_snap}")
  log_ok "Site files pulled"
}

pull_nginx_php() {
  local changed=0
  log_info "Pulling nginx / SSL / PHP-FPM"
  for dir in sites-enabled sites-available ssl-certificates conf.d modules-enabled cloudflare; do
    rsync_from_master "/etc/nginx/${dir}" "/etc/nginx/" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
  done
  shopt -s nullglob
  local pool_dir
  for pool_dir in /etc/php/*/fpm/pool.d; do
    mkdir -p "${pool_dir}"
    rsync_from_master "${pool_dir}/" "${pool_dir}/" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
  done
  shopt -u nullglob

  if [[ "${changed}" -eq 1 || "${RELOAD_NGINX_ON_STANDBY}" == "1" ]]; then
    for u in /home/*; do
      [[ -d "${u}" ]] || continue
      base="$(basename "${u}")"
      case "${base}" in root|clp|lost+found) continue ;; esac
      mkdir -p "${u}/logs/nginx"
    done
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    for s in php*-fpm; do
      systemctl reload "$s" 2>/dev/null || true
    done
  fi
  log_ok "Nginx/PHP pulled"
}

apply_panel_db_local() {
  local src="$1"
  local dest="${CLP_DB_PATH}"
  [[ "${APPLY_PANEL_DB}" == "1" ]] || return 0
  log_info "Applying panel sqlite locally"
  local units
  units="$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E 'php[0-9.]*-fpm|clp-php-fpm' || true)"
  local s
  for s in ${units}; do
    systemctl stop "${s}" || true
  done
  rm -f "${dest}-wal" "${dest}-shm" "${dest}-journal"
  cp -a "${src}" "${dest}.new"
  chown clp:clp "${dest}.new" 2>/dev/null || true
  chmod 660 "${dest}.new"
  mv -f "${dest}.new" "${dest}"
  rm -f "${dest}-wal" "${dest}-shm" "${dest}-journal"
  for s in ${units}; do
    systemctl start "${s}" || true
  done
  local n
  n="$(sqlite3 "${src}" 'SELECT COUNT(*) FROM user;' 2>/dev/null || echo 0)"
  log_ok "Panel sqlite applied (${n} user(s))"
}

pull_app_secret() {
  log_info "Pulling CloudPanel .env (APP_SECRET)"
  mkdir -p /home/clp/htdocs/app/files
  rsync_from_master "/home/clp/htdocs/app/files/.env" "/home/clp/htdocs/app/files/.env" 2>/dev/null || true
  rsync_from_master "/home/clp/htdocs/app/.env" "/home/clp/htdocs/app/.env" 2>/dev/null || true
}

disable_local_backup_jobs() {
  log_info "Disabling backup / image jobs on this standby"
  python3 - "${CLP_DB_PATH}" <<'PY' || true
import pathlib, re, sqlite3, sys
JOB_RE = re.compile(r"db:backup|remote-backup|\brclone\b|create_backup\.sh|aws:image:create", re.I)
p = pathlib.Path("/etc/cron.d/clp")
if p.is_file():
    lines = p.read_text(errors="replace").splitlines(True)
    out, ch = [], False
    for line in lines:
        raw = line.rstrip("\n")
        stripped = raw.lstrip()
        if stripped and not stripped.startswith("#") and JOB_RE.search(stripped):
            out.append("# clp-sync-disabled: " + stripped + "\n")
            ch = True
        else:
            out.append(line if line.endswith("\n") else line + "\n")
    if ch:
        p.write_text("".join(out))
        print("disabled jobs in", p)
try:
    con = sqlite3.connect(sys.argv[1])
    names = [c[1] for c in con.execute('PRAGMA table_info("config")')]
    keycol = next((n for n in names if n.lower() in ("name", "key")), None)
    valcol = next((n for n in names if n.lower() in ("value", "setting_value", "data")), None)
    if keycol and valcol:
        con.execute(f'UPDATE config SET "{valcol}" = ? WHERE "{keycol}" = ?', ("0", "remote_backup_enabled"))
        con.commit()
        print("sqlite remote_backup_enabled=0")
except sqlite3.Error as e:
    print("sqlite skip", e)
PY
}

pull_and_import_mysql() {
  local db_snap="$1"
  local dump_dir="${CLP_SYNC_TMP_DIR}/db"
  mkdir -p "${dump_dir}"
  kill_stale_mysql_imports

  local site_id domain site_user db_name db_user sql_file n
  log_info "Pulling MySQL dumps from master and loading locally"
  while IFS=$'\t' read -r site_id domain site_user db_name db_user; do
    [[ -n "${db_name}" ]] || continue
    [[ ",${MYSQL_SKIP_DATABASES}," == *",${db_name},"* ]] && continue
    sql_file="${dump_dir}/${db_name}.sql"
    log_info "Dumping ${db_name} from master (stdout, not stored on master)"
    master_ssh "clp-mysqldump ${db_name}" >"${sql_file}"
    [[ -s "${sql_file}" ]] || { log_error "empty dump ${db_name}"; return 1; }
    sed -i '/sandbox mode/d;/^SET @@GLOBAL.GTID_PURGED/d' "${sql_file}" || true
    n="$(wc -c <"${sql_file}")"
    log_info "CREATE DATABASE ${db_name}"
    local_mysql -N -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    log_info "Loading ${db_name} via SOURCE (${n} bytes)"
    local m sock
    m=/usr/bin/mysql
    [[ -x "${m}" ]] || m="$(command -v mysql)"
    sock=/run/mysqld/mysqld.sock
    [[ -S "${sock}" ]] || sock=/var/run/mysqld/mysqld.sock
    if ! timeout 180 "${m}" --no-defaults -u root --protocol=SOCKET --socket="${sock}" \
      --skip-password --batch --force --binary-mode --max-allowed-packet=512M \
      -e "SET SESSION FOREIGN_KEY_CHECKS=0; SET SESSION UNIQUE_CHECKS=0; source ${sql_file};"; then
      log_error "SOURCE ${db_name} failed or timed out"
      local_mysql -e "SHOW PROCESSLIST" || true
      return 1
    fi
    rm -f "${sql_file}"
    INC_MYSQL_IMPORT=$((INC_MYSQL_IMPORT + 1))
    log_ok "Imported ${db_name}"

    local pass sql_pass
    if password="$(guess_db_password "${site_user}" "${domain}" "${db_name}")"; then
      sql_pass="$(printf '%s' "${password}" | sed "s/'/''/g")"
      local_mysql -e "
        CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${sql_pass}';
        CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${sql_pass}';
        ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${sql_pass}';
        ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${sql_pass}';
        GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
        GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';
        FLUSH PRIVILEGES;" 2>/dev/null || log_warn "Could not GRANT ${db_user}"
    fi
  done < <(inventory_databases "${db_snap}")
  log_ok "MySQL pull complete"
}
