#!/usr/bin/env bash
# Promotion and sync enable/disable toggles.

config_set_kv() {
  local key="$1" value="$2"
  local cfg="${CLP_SYNC_CONFIG:-/etc/clp-sync/config.env}"
  [[ -f "${cfg}" ]] || die "Config not found: ${cfg}"
  if grep -q "^${key}=" "${cfg}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${cfg}"
  else
    echo "${key}=${value}" >>"${cfg}"
  fi
  chmod 600 "${cfg}"
}

set_role() {
  local role="$1"
  config_set_kv "ROLE" "${role}"
  echo "${role}" >/etc/clp-sync/role
  chmod 644 /etc/clp-sync/role
}

sync_enabled() {
  local cfg="${CLP_SYNC_CONFIG:-/etc/clp-sync/config.env}"
  [[ -f "${cfg}" ]] || return 1
  # shellcheck disable=SC1090
  source "${cfg}"
  [[ "${SYNC_ENABLED:-1}" == "1" ]]
}

toggle_sync() {
  local on_off="$1"
  case "${on_off}" in
    on|enable|1)
      config_set_kv "SYNC_ENABLED" "1"
      config_set_kv "SYNC_AUTO" "1"
      if [[ -f /etc/systemd/system/clp-sync.timer ]]; then
        systemctl enable --now clp-sync.timer
      fi
      echo "Automatic sync enabled (15-minute timer started)"
      ;;
    off|disable|0)
      config_set_kv "SYNC_AUTO" "0"
      systemctl disable --now clp-sync.timer 2>/dev/null || true
      systemctl stop clp-sync.service 2>/dev/null || true
      echo "Automatic sync disabled (timer stopped). Manual clp-bootstrap / clp-sync still work."
      ;;
    *)
      die "Usage: toggle_sync on|off"
      ;;
  esac
}

check_promote_readiness() {
  local max_age_min="${1:-60}"
  local fail=0

  echo "=== Promotion readiness ==="

  if systemctl is-active nginx >/dev/null 2>&1 || systemctl is-active cloudpanel-nginx >/dev/null 2>&1; then
    echo "  PASS nginx running"
  else
    echo "  FAIL nginx not running"; fail=1
  fi

  if systemctl is-active mysql >/dev/null 2>&1 || systemctl is-active mariadb >/dev/null 2>&1; then
    echo "  PASS MySQL/MariaDB running"
  else
    echo "  FAIL MySQL/MariaDB not running"; fail=1
  fi

  if command -v clpctl >/dev/null 2>&1 && [[ -f /home/clp/htdocs/app/data/db.sq3 ]]; then
    local sites
    sites="$(sqlite3 /home/clp/htdocs/app/data/db.sq3 'SELECT COUNT(*) FROM site;' 2>/dev/null || echo 0)"
    if [[ "${sites}" -gt 0 ]]; then
      echo "  PASS CloudPanel has ${sites} site(s) mirrored"
    else
      echo "  WARN CloudPanel has no sites — has sync completed?"
      fail=1
    fi
  else
    echo "  FAIL CloudPanel not ready"; fail=1
  fi

  local snap="/var/lib/clp-sync/primary-db.sq3"
  if [[ -f "${snap}" ]]; then
    local mtime epoch now age
    mtime="$(stat -c %Y "${snap}" 2>/dev/null || stat -f %m "${snap}" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( (now - mtime) / 60 ))
    echo "  INFO Last master panel snapshot: ${age} minute(s) ago"
    if [[ "${age}" -gt "${max_age_min}" ]]; then
      echo "  WARN Snapshot older than ${max_age_min} minutes — data may be stale"
    else
      echo "  PASS Snapshot fresh enough"
    fi
  else
    echo "  WARN No primary-db.sq3 snapshot (bootstrap/sync may not have run yet)"
  fi

  [[ "${fail}" -eq 0 ]]
}

block_inbound_sync() {
  # Remove master push key so old primary cannot overwrite this server
  if [[ -f /root/.ssh/authorized_keys ]]; then
    if grep -q 'clp-sync-master' /root/.ssh/authorized_keys 2>/dev/null; then
      grep -v 'clp-sync-master' /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.tmp || true
      mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      echo "Removed clp-sync-master from authorized_keys (blocks old master pushes)"
    fi
  fi
  pkill -f 'clp-pair-listen' 2>/dev/null || true
}

install_master_systemd() {
  local dest="/opt/clp-sync"
  [[ -d "${dest}/systemd" ]] || dest="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  install -m 644 "${dest}/systemd/clp-sync.service" /etc/systemd/system/clp-sync.service
  install -m 644 "${dest}/systemd/clp-sync.timer" /etc/systemd/system/clp-sync.timer
  systemctl daemon-reload
}

promote_standby_to_master() {
  local force="${1:-0}"
  local max_age="${2:-60}"
  local cfg=/etc/clp-sync/config.env

  [[ -f "${cfg}" ]] || die "Not installed — run install.sh first"
  # shellcheck disable=SC1090
  source "${cfg}"

  if [[ "${ROLE:-standby}" != "standby" ]]; then
    if [[ "${PROMOTED:-0}" == "1" ]]; then
      die "Already promoted to master on $(grep ^PROMOTED_AT= "${cfg}" | cut -d= -f2-)"
    fi
    die "This host is ROLE=${ROLE:-?} — promotion only works on standby"
  fi

  if [[ "${force}" != "1" ]]; then
    check_promote_readiness "${max_age}" || true
    echo
    echo "WARNING: This promotes STANDBY → MASTER after primary loss."
    echo "  • Stops accepting sync from the old master"
    echo "  • You must point DNS / traffic at THIS server"
    echo "  • Outbound sync stays OFF until you configure a new standby"
    echo
    read -r -p "Type PROMOTE to confirm: " confirm || true
    [[ "${confirm}" == "PROMOTE" ]] || die "Aborted"
  fi

  local former_primary="${PRIMARY_HOST:-}"
  [[ -n "${former_primary}" ]] || former_primary="unknown"

  block_inbound_sync

  config_set_kv "ROLE" "master"
  config_set_kv "PROMOTED" "1"
  config_set_kv "PROMOTED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  config_set_kv "FORMER_PRIMARY_HOST" "${former_primary}"
  config_set_kv "SYNC_ENABLED" "0"
  config_set_kv "STANDBY_HOST" ""
  set_role "master"

  # shellcheck source=sync-panel-meta.sh
  source "${CLP_SYNC_ROOT}/lib/sync-panel-meta.sh"
  enable_standby_backups || true

  install_master_systemd
  systemctl disable --now clp-sync.timer 2>/dev/null || true

  cat > /var/lib/clp-sync/promotion.json <<EOF
{
  "promoted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "former_primary": "${former_primary}",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "sync_enabled": false
}
EOF
  chmod 600 /var/lib/clp-sync/promotion.json

  echo
  echo "============================================"
  echo "  STANDBY PROMOTED TO MASTER"
  echo "============================================"
  echo
  echo "  1. Point DNS / floating IP to this server"
  echo "  2. Verify sites: curl -I https://yourdomain.com"
  echo "  3. When you have a new standby server:"
  echo "       /opt/clp-sync/bin/clp-set-standby"
  echo
  echo "  Old master must NOT run clp-sync against this box anymore."
  echo "  Inbound sync from old master is blocked (SSH key removed)."
  echo
}

configure_new_standby() {
  local new_host="${1:-}"
  local cfg=/etc/clp-sync/config.env

  [[ -f "${cfg}" ]] || die "Not installed"
  # shellcheck disable=SC1090
  source "${cfg}"

  [[ "${ROLE:-}" == "master" ]] || die "Run on the active master only"

  if [[ -z "${new_host}" ]]; then
    read -r -p "New standby Tailscale name or IP: " new_host || true
  fi
  [[ -n "${new_host}" ]] || die "Standby host required"

  config_set_kv "STANDBY_HOST" "${new_host}"
  config_set_kv "SYNC_ENABLED" "1"

  local ssh_key="${STANDBY_SSH_KEY:-/root/.ssh/clp_sync_ed25519}"
  if [[ ! -f "${ssh_key}" ]]; then
    ssh-keygen -t ed25519 -f "${ssh_key}" -N '' -C "clp-sync-master"
    config_set_kv "STANDBY_SSH_KEY" "${ssh_key}"
  fi

  echo "Pair the new standby first (install.sh → Standby), then press Enter..."
  read -r _ || true

  # shellcheck source=common.sh - remote needs load_config vars
  if ! ssh -i "${ssh_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "root@${new_host}" "echo ok && command -v clpctl"; then
    die "Cannot SSH to new standby — complete pairing on standby first"
  fi

  install_master_systemd
  config_set_kv "SYNC_AUTO" "1"
  systemctl enable --now clp-sync.timer
  echo "New standby configured. Sync enabled."
  echo "Run: /opt/clp-sync/bin/clp-bootstrap"
}
