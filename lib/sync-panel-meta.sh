#!/usr/bin/env bash
# Apply CloudPanel SQLite so panel UI users, sites, FTP, SSL metadata match primary.

sync_panel_meta() {
  local db_snap="$1"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local remote_dir="/var/lib/clp-sync"
  local remote_copy="${remote_dir}/primary-db.sq3"
  local apply="${APPLY_PANEL_DB:-1}"

  log_info "Publishing CloudPanel SQLite snapshot to standby"
  remote "mkdir -p '${remote_dir}' && chmod 700 '${remote_dir}'"
  rsync -a -e "${rsync_ssh}" "${db_snap}" "$(standby_target):${remote_copy}"

  remote "cp -a '${remote_copy}' '${remote_dir}/primary-db-$(date -u +%Y%m%dT%H%M%SZ).sq3' &&
    ls -1t '${remote_dir}'/primary-db-*.sq3 2>/dev/null | tail -n +8 | xargs -r rm -f"

  if [[ "${apply}" != "1" ]]; then
    log_info "APPLY_PANEL_DB=0 — left live panel DB untouched"
    return 0
  fi

  log_info "Applying primary CloudPanel DB as live standby panel DB (identical panel users/sites metadata)"
  remote bash -s <<EOF
set -euo pipefail
CLP_DB='${CLP_DB_PATH}'
SRC='${remote_copy}'
install -d -m 755 -o clp -g clp "\$(dirname "\$CLP_DB")"
# Brief consistency: copy into place; CloudPanel reads SQLite per request
cp -a "\$SRC" "\${CLP_DB}.new"
chown clp:clp "\${CLP_DB}.new"
chmod 660 "\${CLP_DB}.new"
mv -f "\${CLP_DB}.new" "\$CLP_DB"
# Drop compiled caches if present
rm -rf /home/clp/htdocs/app/var/cache/* 2>/dev/null || true
# Reload panel PHP if pooled
for s in php*-fpm; do systemctl reload "\$s" 2>/dev/null || true; done
true
EOF

  log_ok "Live CloudPanel DB mirrored (admin users, sites, FTP, SSL metadata)"
}

# Sync panel data files beyond sqlite (custom branding, etc.)
sync_panel_data_files() {
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local data_dir
  data_dir="$(dirname "${CLP_DB_PATH}")"

  if [[ ! -d "${data_dir}" ]]; then
    return 0
  fi

  log_info "Syncing CloudPanel data directory ${data_dir}"
  remote "install -d -m 755 -o clp -g clp '${data_dir}'"
  rsync -a -e "${rsync_ssh}" \
    --exclude 'db.sq3-journal' \
    --exclude 'db.sq3-wal' \
    --exclude 'db.sq3-shm' \
    "${data_dir}/" \
    "$(standby_target):${data_dir}/"
  remote "chown -R clp:clp '${data_dir}'"
  log_ok "Panel data directory mirrored"
}
