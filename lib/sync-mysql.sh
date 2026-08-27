#!/usr/bin/env bash
# Dump MySQL databases on primary; import on standby only when dump changed.

_mysql_should_skip() {
  local name="$1"
  [[ ",${MYSQL_SKIP_DATABASES}," == *",${name},"* ]]
}

sync_mysql() {
  local db_snap="$1"
  local dump_dir="${CLP_SYNC_TMP_DIR}/db"
  local checksum_dir="${CLP_SYNC_STATE_DIR}/db-checksums"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"

  mkdir -p "${dump_dir}" "${checksum_dir}"
  require_cmds mysqldump gzip sha256sum

  local site_id domain site_user db_name db_user
  local dump_file checksum_file old_sum new_sum remote_tmp

  log_info "Syncing MySQL databases"
  while IFS='|' read -r site_id domain site_user db_name db_user; do
    [[ -n "${db_name}" ]] || continue
    if _mysql_should_skip "${db_name}"; then
      continue
    fi

    dump_file="${dump_dir}/${db_name}.sql.gz"
    checksum_file="${checksum_dir}/${db_name}.sha256"
    remote_tmp="/var/tmp/clp-sync-import/${db_name}.sql.gz"

    log_info "Dumping ${db_name}"
    mysqldump --single-transaction --quick --routines --triggers \
      --default-character-set=utf8mb4 \
      "${db_name}" | gzip -c >"${dump_file}"

    new_sum="$(sha256_file "${dump_file}")"
    old_sum=""
    [[ -f "${checksum_file}" ]] && old_sum="$(cat "${checksum_file}")"

    if [[ "${MYSQL_SKIP_UNCHANGED}" == "1" && "${new_sum}" == "${old_sum}" ]]; then
      log_info "Unchanged ${db_name} (skip import)"
      continue
    fi

    log_info "Importing ${db_name} on standby"
    remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
    rsync -a -e "${rsync_ssh}" "${dump_file}" "$(standby_target):${remote_tmp}"

    if remote clpctl db:import --databaseName="${db_name}" --file="${remote_tmp}"; then
      echo "${new_sum}" >"${checksum_file}"
      remote "rm -f '${remote_tmp}'"
      log_ok "Imported ${db_name}"
    else
      log_error "Import failed for ${db_name}"
      return 1
    fi
  done < <(inventory_databases "${db_snap}")

  reconcile_db_passwords "${db_snap}"
  log_ok "MySQL sync complete"
}

# Align standby MySQL user passwords with credentials embedded in primary app configs.
reconcile_db_passwords() {
  local db_snap="$1"
  local site_id domain site_user db_name db_user password sql_file rsync_ssh
  local remote_sql="/var/tmp/clp-sync-import/alter-user.sql"
  rsync_ssh="$(rsync_ssh_cmd)"
  sql_file="${CLP_SYNC_TMP_DIR}/alter-user.sql"

  log_info "Reconciling MySQL user passwords on standby from app configs"
  while IFS='|' read -r site_id domain site_user db_name db_user; do
    [[ -n "${db_name}" && -n "${db_user}" ]] || continue
    if _mysql_should_skip "${db_name}"; then
      continue
    fi
    if ! password="$(guess_db_password "${site_user}" "${domain}" "${db_name}")"; then
      continue
    fi
    # Escape single quotes for SQL string literals
    local sql_pass
    sql_pass="$(printf '%s' "${password}" | sed "s/'/''/g")"
    printf "ALTER USER '%s'@'localhost' IDENTIFIED BY '%s';\nFLUSH PRIVILEGES;\n" \
      "$(sql_escape "${db_user}")" "${sql_pass}" >"${sql_file}"
    chmod 600 "${sql_file}"
    remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
    rsync -a -e "${rsync_ssh}" "${sql_file}" "$(standby_target):${remote_sql}"
    if remote "mysql < '${remote_sql}' && rm -f '${remote_sql}'"; then
      log_info "Aligned password for MySQL user ${db_user}"
    else
      log_warn "Could not ALTER USER ${db_user} on standby"
    fi
  done < <(inventory_databases "${db_snap}")
  rm -f "${sql_file}"
}
