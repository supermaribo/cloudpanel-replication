#!/usr/bin/env bash
# Incremental site file sync via rsync over Tailscale SSH.

sync_site_files() {
  local db_snap="$1"
  local user
  local excludes="${RSYNC_EXCLUDES_FILE}"

  [[ -f "${excludes}" ]] || die "Rsync excludes file missing: ${excludes}"

  log_info "Syncing site home directories (changed files only)"
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    local src="/home/${user}/"
    if [[ ! -d "${src}" ]]; then
      log_warn "Missing home dir on primary: ${src}"
      continue
    fi
    # Ownership maps by username (not numeric UID) so standby UIDs may differ safely.
    rsync_to_standby "${src}" "${src}" --exclude-from="${excludes}"
  done < <(inventory_site_users "${db_snap}")

  if [[ -d /home/clp/.ssh ]]; then
    remote "mkdir -p /home/clp/.ssh && chown clp:clp /home/clp/.ssh"
    rsync_to_standby /home/clp/.ssh/ /home/clp/.ssh/
    if [[ "${RSYNC_CHANGED}" -eq 1 ]]; then
      remote "chown -R clp:clp /home/clp/.ssh && chmod 700 /home/clp/.ssh && chmod 600 /home/clp/.ssh/* 2>/dev/null || true"
    fi
  fi

  log_ok "Site file sync complete"
}
