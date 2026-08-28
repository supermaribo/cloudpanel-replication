#!/usr/bin/env bash
# Shared helpers for the interactive installer.
# shellcheck disable=SC2034

set -euo pipefail

INSTALL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DEST="${DEST:-/opt/clp-sync}"
PAIR_PORT="${PAIR_PORT:-18765}"

# CloudPanel uses Percona/MariaDB — this project NEVER runs apt-get on any CloudPanel host.
has_mysqldump() {
  command -v mysqldump >/dev/null 2>&1 && return 0
  [[ -x /usr/bin/mysqldump ]] && return 0
  return 1
}

c_info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[1;32mOK\033[0m  %s\n' "$*"; }
c_warn()  { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
c_err()   { printf '\033[1;31mERR\033[0m  %s\n' "$*" >&2; }

# curl | bash leaves stdin at EOF. Always read prompts from the keyboard.
INSTALL_TTY=""
ensure_install_tty() {
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    INSTALL_TTY=/dev/tty
    return 0
  fi
  INSTALL_TTY=""
  return 1
}

_prompt_read_fail() {
  c_err "Cannot read from the keyboard (installer was run as curl | bash, or this is not a terminal)."
  echo "  Press Ctrl+C if you are stuck in a prompt loop."
  echo "  Then run one of:"
  echo "    sudo CLP_SYNC_ROLE=standby /root/clp-sync-src/bin/install.sh"
  echo "    sudo CLP_SYNC_ROLE=master  /root/clp-sync-src/bin/install.sh"
  echo "  Or download first so prompts work:"
  echo "    curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh -o /tmp/clp-install.sh"
  echo "    sudo bash /tmp/clp-install.sh"
  exit 1
}

_read_reply() {
  local prompt="$1"
  REPLY=""
  if [[ -n "${INSTALL_TTY}" ]]; then
    if ! read -r -p "${prompt}" REPLY <"${INSTALL_TTY}"; then
      _prompt_read_fail
    fi
  elif [[ -t 0 ]]; then
    if ! read -r -p "${prompt}" REPLY; then
      _prompt_read_fail
    fi
  else
    _prompt_read_fail
  fi
  REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
  REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
  REPLY="${REPLY//$'\r'/}"
}

ask() {
  # ask "Prompt" "default" → sets REPLY
  local prompt="$1" default="${2:-}"
  if [[ -n "${default}" ]]; then
    _read_reply "${prompt} [${default}]: "
    REPLY="${REPLY:-${default}}"
  else
    _read_reply "${prompt}: "
  fi
}

ask_yn() {
  # ask_yn "Prompt" "y|n" → returns 0 for yes
  local prompt="$1" default="${2:-y}" yn
  if [[ "${default}" == "y" ]]; then
    _read_reply "${prompt} [Y/n]: "
    yn="${REPLY:-y}"
  else
    _read_reply "${prompt} [y/N]: "
    yn="${REPLY:-n}"
  fi
  [[ "${yn}" =~ ^[Yy] ]]
}

normalize_install_role() {
  case "$1" in
    1|m|M|master|Master) printf '%s\n' master ;;
    2|s|S|standby|Standby|slave|Slave) printf '%s\n' standby ;;
    *) printf '%s\n' "" ;;
  esac
}

require_root_install() {
  if [[ "$(id -u)" -ne 0 ]]; then
    c_err "Run as root: sudo ./bin/install.sh"
    exit 1
  fi
}

tailscale_self_name() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status --self --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip(".") or d.get("Self",{}).get("HostName",""))' 2>/dev/null \
      || tailscale status --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip(".") or "")' 2>/dev/null \
      || true
  fi
}

tailscale_self_ip() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale ip -4 2>/dev/null | head -1 || true
  fi
}

tailscale_peers() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in (d.get("Peer") or {}).values():
    if p.get("Online") is False:
        continue
    name = (p.get("DNSName") or "").rstrip(".") or p.get("HostName") or ""
    ips = p.get("TailscaleIPs") or []
    ip = ips[0] if ips else ""
    if name or ip:
        print("%s\t%s" % (name or ip, ip))
' 2>/dev/null || true
}

check_cloudpanel() {
  if command -v clpctl >/dev/null 2>&1 && [[ -f /home/clp/htdocs/app/data/db.sq3 ]]; then
    return 0
  fi
  return 1
}

install_files() {
  c_info "Installing toolkit → ${INSTALL_DEST}"
  mkdir -p "${INSTALL_DEST}"
  rsync -a --delete \
    --exclude '.git/' \
    --exclude 'config.env' \
    "${INSTALL_SRC}/" "${INSTALL_DEST}/"
  chmod 755 "${INSTALL_DEST}/bin/"* 2>/dev/null || true
  mkdir -p /etc/clp-sync /var/lib/clp-sync /var/log/clp-sync /var/tmp/clp-sync
  chmod 700 /etc/clp-sync /var/lib/clp-sync /var/tmp/clp-sync
  c_ok "Files installed"
}

ensure_pull_key() {
  local key="${1:-/root/.ssh/clp_sync_ed25519}"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [[ ! -f "${key}" ]]; then
    ssh-keygen -t ed25519 -f "${key}" -N '' -C "clp-sync-peer"
  fi
  chmod 600 "${key}" "${key}.pub" 2>/dev/null || true
}

write_config() {
  local role="$1"
  local peer_host="${2:-}"
  local ssh_key="${3:-/root/.ssh/clp_sync_ed25519}"
  local cfg=/etc/clp-sync/config.env
  local master_host="" standby_host=""
  if [[ "${role}" == "standby" ]]; then
    master_host="${peer_host}"
  else
    standby_host="${peer_host}"
  fi

  cat >"${cfg}" <<EOF
# Generated by clp-sync installer — $(date -u +%Y-%m-%dT%H:%M:%SZ)
ROLE=${role}
PROMOTED=0
SYNC_ENABLED=$([[ "${role}" == "standby" ]] && echo 1 || echo 0)
SYNC_AUTO=0
SYNC_INTERVAL=1h

MASTER_HOST=${master_host}
PRIMARY_HOST=${master_host}
STANDBY_HOST=${standby_host}
PEER_HOST=${peer_host}
MASTER_SSH_USER=root
MASTER_SSH_PORT=22
MASTER_SSH_KEY=${ssh_key}
STANDBY_SSH_USER=root
STANDBY_SSH_PORT=22
STANDBY_SSH_KEY=${ssh_key}

CLP_DB_PATH=/home/clp/htdocs/app/data/db.sq3
CLP_SYNC_STATE_DIR=/var/lib/clp-sync
CLP_SYNC_TMP_DIR=/var/tmp/clp-sync
CLP_SYNC_LOG_DIR=/var/log/clp-sync
RSYNC_EXCLUDES_FILE=/opt/clp-sync/excludes/rsync-excludes.txt
BOOTSTRAP_SITE_TYPES=php,nodejs,python,static,reverse-proxy
MYSQL_SKIP_UNCHANGED=1
MYSQL_SKIP_DATABASES=information_schema,performance_schema,sys,mysql
RELOAD_NGINX_ON_STANDBY=1
APPLY_PANEL_DB=1
SYNC_EXTRA_USERS=clp
FAIL_NOTIFY_CMD=
EOF
  chmod 600 "${cfg}"
  echo "${role}" >/etc/clp-sync/role
  chmod 644 /etc/clp-sync/role
  c_ok "Wrote ${cfg} (ROLE=${role})"
}

generate_pair_token() {
  openssl rand -hex 16
}
