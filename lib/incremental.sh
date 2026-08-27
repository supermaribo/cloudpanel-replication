#!/usr/bin/env bash
# Incremental helpers — skip dumps, imports, reloads, and applies when nothing changed.

INC_FILE_CHANGES=0
INC_MYSQL_SKIP=0
INC_MYSQL_IMPORT=0
INC_CFG_CHANGES=0
INC_SKIPPED=0

incremental_on() {
  [[ "${INCREMENTAL:-1}" == "1" ]]
}

checksum_dir() {
  printf '%s/checksums' "${CLP_SYNC_STATE_DIR}"
}

checksum_key_safe() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

checksum_path() {
  printf '%s/%s.sha256' "$(checksum_dir)" "$(checksum_key_safe "$1")"
}

save_checksum() {
  local name="$1" value="$2"
  mkdir -p "$(checksum_dir)"
  printf '%s\n' "${value}" >"$(checksum_path "${name}")"
  chmod 600 "$(checksum_path "${name}")"
}

load_checksum() {
  local f
  f="$(checksum_path "$1")"
  [[ -f "${f}" ]] && cat "${f}" || true
}

# 0 if stored checksum matches value (safe to skip).
checksum_eq() {
  local name="$1" value="$2"
  local old
  incremental_on || return 1
  [[ -n "${value}" ]] || return 1
  old="$(load_checksum "${name}")"
  [[ -n "${old}" && "${old}" == "${value}" ]]
}

str_digest() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# Cheap per-database change detector (no dump). Uses table status + routines.
mysql_db_fingerprint() {
  local db="$1"
  local ident
  ident="$(printf '%s' "${db}" | sed 's/`/``/g')"
  {
    mysql_cli --batch --raw --skip-column-names -e "SHOW TABLE STATUS FROM \`${ident}\`;" 2>/dev/null || return 1
    mysql_cli --batch --raw --skip-column-names -e "
      SELECT ROUTINE_NAME, ROUTINE_TYPE, LAST_ALTERED
      FROM information_schema.ROUTINES
      WHERE ROUTINE_SCHEMA='$(sql_escape "${db}")'
      ORDER BY ROUTINE_NAME;" 2>/dev/null || true
  } | sha256sum | awk '{print $1}'
}

# rsync local src → standby dest_path. Extra args are passed to rsync.
# Sets RSYNC_CHANGED=1 if content/attrs changed, 0 if unchanged.
# Dies on rsync failure.
rsync_to_standby() {
  local src="$1"
  local dest_path="$2"
  shift 2
  local rsync_ssh item_log n rc=0
  rsync_ssh="$(rsync_ssh_cmd)"
  item_log="${CLP_SYNC_TMP_DIR}/rsync-item.$$"
  mkdir -p "${CLP_SYNC_TMP_DIR}"
  RSYNC_CHANGED=0

  rsync -aHAX --delete --omit-dir-times \
    --out-format='%i %n%L' \
    -e "${rsync_ssh}" \
    "$@" \
    "${src}" "$(standby_target):${dest_path}" >"${item_log}" || rc=$?

  if [[ "${rc}" -ne 0 ]]; then
    rm -f "${item_log}"
    die "rsync failed (rc=${rc}): ${src} → ${dest_path}"
  fi

  n="$(grep -cE '^[<>c*h]|^\.[fL]' "${item_log}" 2>/dev/null || true)"
  n="${n:-0}"
  rm -f "${item_log}"

  if [[ "${n}" -gt 0 ]]; then
    INC_FILE_CHANGES=$((INC_FILE_CHANGES + n))
    RSYNC_CHANGED=1
    log_info "rsync ${src} → ${dest_path} (${n} change(s))"
    return 0
  fi

  INC_SKIPPED=$((INC_SKIPPED + 1))
  log_info "rsync ${src}: unchanged"
  return 0
}

log_incremental_summary() {
  log_info "Incremental summary: files=${INC_FILE_CHANGES} mysql_import=${INC_MYSQL_IMPORT} mysql_skip=${INC_MYSQL_SKIP} config=${INC_CFG_CHANGES} skipped_steps=${INC_SKIPPED}"
}
