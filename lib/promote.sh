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

enable_standby_backups() {
  log_info "Re-enabling CloudPanel backup jobs (promotion)"
  python3 - <<'PY'
import pathlib, re, subprocess
prefix = re.compile(r"^# clp-sync-disabled:\s*")
for p in (
    pathlib.Path("/etc/cron.d/clp"),
    pathlib.Path("/etc/cron.d/clp-rclone"),
    pathlib.Path("/etc/cron.d/clp-remote-backup"),
    pathlib.Path("/etc/cron.d/clp-aws"),
    pathlib.Path("/etc/cron.d/clp-do"),
    pathlib.Path("/etc/cron.d/clp-gce"),
    pathlib.Path("/etc/cron.d/clp-hetzner"),
    pathlib.Path("/etc/cron.d/clp-vultr"),
):
    if not p.is_file():
        continue
    lines = []
    for line in p.read_text(errors="replace").splitlines():
        if "clp-sync: backups disabled on standby" in line:
            continue
        if "clp-sync: cloud images/snapshots disabled" in line:
            continue
        lines.append(prefix.sub("", line))
    p.write_text("\n".join(lines) + ("\n" if lines else ""))
    print("restored", p)
for user in ("clp", "clp-admin"):
    try:
        current = subprocess.check_output(["crontab", "-u", user, "-l"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        continue
    lines = []
    for line in current.splitlines():
        if "clp-sync: backups disabled on standby" in line:
            continue
        if "clp-sync: cloud images/snapshots disabled" in line:
            continue
        lines.append(prefix.sub("", line))
    body = "\n".join(lines) + "\n"
    subprocess.run(["crontab", "-u", user, "-"], input=body, text=True, check=True)
    print("restored crontab for", user)
PY
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
      echo "Automatic sync enabled (timer started)"
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

set_sync_interval() {
  local interval="$1"
  local drop=/etc/systemd/system/clp-sync.timer.d
  case "${interval}" in
    1h|2h|4h|6h|12h|24h)
      mkdir -p "${drop}"
      # Empty assignments reset the unit file values so we do not fire on both intervals.
      cat >"${drop}/interval.conf" <<EOF
[Timer]
OnBootSec=
OnUnitActiveSec=
OnBootSec=5min
OnUnitActiveSec=${interval}
EOF
      chmod 644 "${drop}/interval.conf"
      config_set_kv "SYNC_INTERVAL" "${interval}"
      toggle_sync on
      systemctl daemon-reload
      systemctl restart clp-sync.timer
      echo "Replication interval set to ${interval}"
      ;;
    off|manual)
      config_set_kv "SYNC_INTERVAL" "off"
      toggle_sync off
      echo "Replication timer off (manual only)"
      ;;
    *)
      die "Interval must be 1h, 2h, 4h, 6h, 12h, 24h, or off"
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

install_sync_units() {
  install_master_systemd
}

peer_host() {
  echo "${PEER_HOST:-${MASTER_HOST:-${STANDBY_HOST:-}}}"
}

ensure_peer_pull_key() {
  local key="${MASTER_SSH_KEY:-/root/.ssh/clp_sync_ed25519}"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f "${key}" ]]; then
    ssh-keygen -t ed25519 -f "${key}" -N '' -C "clp-sync-peer"
  fi
  chmod 600 "${key}" "${key}.pub" 2>/dev/null || true
}

pair_this_host_with() {
  local peer="$1"
  [[ "${peer}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "invalid peer host"
  ensure_peer_pull_key
  config_set_kv "PEER_HOST" "${peer}"
  config_set_kv "MASTER_SSH_KEY" "/root/.ssh/clp_sync_ed25519"
  if [[ "${ROLE:-}" == "standby" ]]; then
    config_set_kv "MASTER_HOST" "${peer}"
    config_set_kv "PRIMARY_HOST" "${peer}"
  else
    config_set_kv "STANDBY_HOST" "${peer}"
    install_sync_units
    systemctl disable --now clp-sync.timer 2>/dev/null || true
    ensure_live_badge || true
  fi
  echo "OK PEER_HOST=${peer}"
  cat /root/.ssh/clp_sync_ed25519.pub
}

become_standby() {
  local peer
  peer="$(peer_host)"
  [[ -n "${peer}" ]] || die "PEER_HOST is not set — run clp-pair-peer <peer>"
  if [[ "${ROLE:-}" == "standby" ]]; then
    echo "OK already standby MASTER_HOST=${MASTER_HOST:-${peer}}"
    return 0
  fi
  [[ "${ROLE:-}" == "master" ]] || die "ROLE=${ROLE:-?} — become-standby expects master"
  log_info "Becoming standby; will pull from ${peer} after resume"
  ensure_peer_pull_key
  install_sync_units
  config_set_kv "ROLE" "standby"
  config_set_kv "MASTER_HOST" "${peer}"
  config_set_kv "PRIMARY_HOST" "${peer}"
  config_set_kv "PEER_HOST" "${peer}"
  config_set_kv "SYNC_ENABLED" "1"
  config_set_kv "SYNC_AUTO" "0"
  config_set_kv "PROMOTED" "0"
  set_role "standby"
  ROLE=standby
  MASTER_HOST="${peer}"
  PEER_HOST="${peer}"
  toggle_sync off
  disable_local_backup_jobs || true
  ensure_replicated_badge || true
  echo "OK become-standby peer=${peer}"
}

resume_pull() {
  local peer
  peer="$(peer_host)"
  [[ "${ROLE:-}" == "standby" ]] || die "resume-pull expects ROLE=standby"
  [[ -n "${peer}" ]] || die "PEER_HOST / MASTER_HOST not set"
  config_set_kv "MASTER_HOST" "${peer}"
  config_set_kv "PEER_HOST" "${peer}"
  config_set_kv "SYNC_ENABLED" "1"
  install_sync_units
  local interval="${SYNC_INTERVAL:-1h}"
  case "${interval}" in
    1h|2h|4h|6h|12h|24h) set_sync_interval "${interval}" ;;
    *) toggle_sync on ;;
  esac
  echo "OK resume-pull from ${peer}"
}

become_live() {
  local orphan="${1:-0}"
  local peer
  peer="$(peer_host)"
  [[ "${ROLE:-}" == "standby" ]] || die "become-live expects ROLE=standby"

  block_inbound_sync

  config_set_kv "ROLE" "master"
  config_set_kv "PROMOTED" "1"
  config_set_kv "PROMOTED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  config_set_kv "FORMER_PRIMARY_HOST" "${peer:-unknown}"
  config_set_kv "SYNC_ENABLED" "0"
  config_set_kv "SYNC_AUTO" "0"
  [[ -n "${peer}" ]] && config_set_kv "PEER_HOST" "${peer}"
  [[ -n "${peer}" ]] && config_set_kv "STANDBY_HOST" "${peer}"
  set_role "master"
  ROLE=master

  enable_standby_backups || true
  ensure_live_badge || true
  install_sync_units
  systemctl disable --now clp-sync.timer 2>/dev/null || true
  systemctl stop clp-sync.service 2>/dev/null || true

  mkdir -p /var/lib/clp-sync
  cat > /var/lib/clp-sync/promotion.json <<EOF
{
  "promoted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "former_primary": "${peer:-unknown}",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "orphan": ${orphan},
  "sync_enabled": false
}
EOF
  chmod 600 /var/lib/clp-sync/promotion.json
}

switch_live_with_peer() {
  local age peer_ok=0
  local lock="${CLP_SYNC_STATE_DIR}/clp-sync.lock"

  [[ "${ROLE:-}" == "standby" ]] || die "Already live or not a replica"

  mkdir -p "${CLP_SYNC_STATE_DIR}"
  exec 9>"${lock}"
  if ! flock -n 9; then
    die "Sync is running — wait, then try Make live again"
  fi

  systemctl stop clp-sync.timer 2>/dev/null || true
  systemctl stop clp-sync.service 2>/dev/null || true

  age="$(last_sync_age_minutes)"
  log_info "Last successful sync age: ${age} minute(s)"

  if master_ssh clp-sync-probe >/dev/null 2>&1; then
    if master_ssh clp-sync-become-standby; then
      peer_ok=1
    else
      die "Peer is reachable but could not switch it to replica. Update /opt/clp-sync on the live box (rsync from this replica), run clp-pair-peer, then retry Make live."
    fi
  else
    log_warn "Peer unreachable — this box will go LIVE alone"
  fi

  become_live "$([[ "${peer_ok}" -eq 1 ]] && echo 0 || echo 1)"

  if [[ "${peer_ok}" -eq 1 ]]; then
    if ! master_ssh clp-sync-resume-pull; then
      log_warn "Peer is standby but timer did not start — on the peer run: /opt/clp-sync/bin/clp-role resume-pull"
    fi
    echo "OK swapped: this host is LIVE, peer is replica"
  else
    echo "OK this host is LIVE (peer was not switched)"
  fi
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
    echo "WARNING: Emergency promote (peer is not switched)."
    echo "  • This box becomes LIVE"
    echo "  • Point DNS / traffic at THIS server"
    echo "  • Use Make live in the panel to swap both when the peer is up"
    echo
    read -r -p "Type PROMOTE to confirm: " confirm || true
    [[ "${confirm}" == "PROMOTE" ]] || die "Aborted"
  fi

  become_live 1

  echo
  echo "============================================"
  echo "  THIS HOST IS LIVE"
  echo "============================================"
  echo
  echo "  1. Point DNS / floating IP to this server"
  echo "  2. If the other box is up, pair it as replica:"
  echo "       /opt/clp-sync/bin/clp-pair-peer <this-host>"
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
  config_set_kv "PEER_HOST" "${new_host}"
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
