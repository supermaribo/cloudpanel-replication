#!/usr/bin/env bash
# Incremental site file sync via rsync over Tailscale SSH.

sync_site_files() {
  local db_snap="$1"
  local user
  local excludes="${RSYNC_EXCLUDES_FILE}"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"

  [[ -f "${excludes}" ]] || die "Rsync excludes file missing: ${excludes}"

  log_info "Syncing site home directories to standby"
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    local src="/home/${user}/"
    if [[ ! -d "${src}" ]]; then
      log_warn "Missing home dir on primary: ${src}"
      continue
    fi
    log_info "rsync ${src} -> standby (includes .ssh keys, SSL under etc/ssl, all site data)"
    # Ownership maps by username (not numeric UID) so standby UIDs may differ safely.
    rsync -aHAX --delete \
      --exclude-from="${excludes}" \
      -e "${rsync_ssh}" \
      "${src}" \
      "$(standby_target):${src}"
  done < <(inventory_site_users "${db_snap}")

  # Panel system user home extras (SSH keys for clp, etc.) — exclude app code churn
  if [[ -d /home/clp ]]; then
    log_info "rsync /home/clp/.ssh and SSL-related panel paths"
    if [[ -d /home/clp/.ssh ]]; then
      remote "mkdir -p /home/clp/.ssh && chown clp:clp /home/clp/.ssh"
      rsync -a -e "${rsync_ssh}" /home/clp/.ssh/ "$(standby_target):/home/clp/.ssh/"
      remote "chown -R clp:clp /home/clp/.ssh && chmod 700 /home/clp/.ssh && chmod 600 /home/clp/.ssh/* 2>/dev/null || true"
    fi
  fi

  log_ok "Site file sync complete"
}
