#!/usr/bin/env bash
# Mirror Linux site/FTP/panel users: password hashes, shells, groups.

: "${SYNC_EXTRA_USERS:=clp}"

_all_mirror_usernames() {
  local db_snap="$1"
  local u
  inventory_site_users "${db_snap}"
  inventory_ftp_usernames "${db_snap}"
  local IFS=','
  # shellcheck disable=SC2086
  for u in ${SYNC_EXTRA_USERS}; do
    [[ -n "${u}" ]] && printf '%s\n' "${u}"
  done
}

sync_user_identities() {
  local db_snap="$1"
  local tsv="${CLP_SYNC_TMP_DIR}/users.tsv"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local user hash shell home groups

  : >"${tsv}"
  chmod 600 "${tsv}"

  log_info "Exporting Linux user identities from primary"
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    if ! id -u "${user}" >/dev/null 2>&1; then
      log_warn "Primary has no Linux user '${user}'"
      continue
    fi
    hash="$(getent shadow "${user}" | cut -d: -f2 || true)"
    shell="$(getent passwd "${user}" | cut -d: -f7 || true)"
    home="$(getent passwd "${user}" | cut -d: -f6 || true)"
    groups="$(id -Gn "${user}" | tr ' ' ',')"
    if [[ -z "${hash}" || "${hash}" == "!" || "${hash}" == "*" ]]; then
      log_warn "No usable password hash for ${user}"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${user}" "${hash}" "${shell}" "${home}" "${groups}" >>"${tsv}"
  done < <(_all_mirror_usernames "${db_snap}" | awk 'NF' | sort -u)

  if [[ ! -s "${tsv}" ]]; then
    log_warn "No user identities to sync"
    return 0
  fi

  remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
  rsync -a -e "${rsync_ssh}" "${tsv}" "$(standby_target):/var/tmp/clp-sync-import/users.tsv"

  remote bash -s <<'EOS'
set -euo pipefail
TSV=/var/tmp/clp-sync-import/users.tsv
while IFS=$'\t' read -r user hash shell home groups; do
  [[ -n "$user" ]] || continue
  if ! id -u "$user" >/dev/null 2>&1; then
    echo "missing user $user on standby — run bootstrap" >&2
    continue
  fi
  usermod -p "$hash" "$user" || true
  if [[ -n "$shell" ]]; then
    chsh -s "$shell" "$user" 2>/dev/null || true
  fi
  if [[ -n "$home" ]]; then
    mkdir -p "$home"
    chown "$user:$user" "$home" 2>/dev/null || true
    if [[ -d "$home/.ssh" ]]; then
      chown -R "$user:$user" "$home/.ssh"
      chmod 700 "$home/.ssh"
      find "$home/.ssh" -type f -exec chmod 600 {} \;
    fi
  fi
  IFS=',' read -r -a garr <<<"$groups"
  for g in "${garr[@]}"; do
    [[ -z "$g" || "$g" == "$user" ]] && continue
    getent group "$g" >/dev/null 2>&1 || continue
    usermod -aG "$g" "$user" 2>/dev/null || true
  done
  echo "updated $user"
done < "$TSV"
rm -f "$TSV"
EOS

  log_ok "User identity mirror complete (passwords + shells + groups + .ssh perms)"
}

sync_ftp_users() {
  local db_snap="$1"
  local ftp_user home site_user
  local list="${CLP_SYNC_TMP_DIR}/ftp-users.txt"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"

  : >"${list}"
  log_info "Ensuring FTP Linux users exist on standby"
  while IFS='|' read -r ftp_user home site_user; do
    [[ -n "${ftp_user}" ]] || continue
    [[ -n "${home}" ]] || home="/home/${ftp_user}"
    printf '%s\t%s\t%s\n' "${ftp_user}" "${home}" "${site_user}" >>"${list}"
  done < <(inventory_ftp_users "${db_snap}")

  if [[ ! -s "${list}" ]]; then
    log_info "No FTP users in panel DB"
    return 0
  fi

  remote "mkdir -p /var/tmp/clp-sync-import && chmod 700 /var/tmp/clp-sync-import"
  rsync -a -e "${rsync_ssh}" "${list}" "$(standby_target):/var/tmp/clp-sync-import/ftp-users.txt"

  remote bash -s <<'EOS'
set -euo pipefail
getent group ftp-user >/dev/null 2>&1 || groupadd ftp-user || true
while IFS=$'\t' read -r ftp_user home site_user; do
  [[ -n "$ftp_user" ]] || continue
  if ! id -u "$ftp_user" >/dev/null 2>&1; then
    if [[ -n "$site_user" ]] && ! id -u "$site_user" >/dev/null 2>&1; then
      echo "skip ftp $ftp_user — parent site user $site_user missing (bootstrap first)" >&2
      continue
    fi
    adduser --disabled-password --gecos "" --home "$home" "$ftp_user" || true
  fi
  mkdir -p "$home"
  if [[ -n "$site_user" ]] && id -u "$site_user" >/dev/null 2>&1; then
    usermod -aG "$site_user" "$ftp_user" 2>/dev/null || true
  fi
  usermod -aG ftp-user "$ftp_user" 2>/dev/null || true
  echo "ftp user ok: $ftp_user"
done < /var/tmp/clp-sync-import/ftp-users.txt
rm -f /var/tmp/clp-sync-import/ftp-users.txt
EOS

  log_ok "FTP users ensured"
}
