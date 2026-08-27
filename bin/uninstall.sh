#!/usr/bin/env bash
# Remove clp-sync from this server (master or standby).
# Does NOT remove CloudPanel, sites, databases, or mirrored data on the standby.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DEST="/opt/clp-sync"
FORCE=0
KEEP_SSH_KEY=0
KEEP_SRC=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [options]

Remove the clp-sync agent, timer, config, and state from this server.

Options:
  -y, --yes     Skip confirmation prompts
  --keep-key    Keep /root/.ssh/clp_sync_ed25519 on master
  --keep-src    Keep the git clone directory you ran this from
  -h, --help    Show help

CloudPanel, nginx, MySQL, and site files are never removed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) FORCE=1 ;;
    --keep-key) KEEP_SSH_KEY=1 ;;
    --keep-src) KEEP_SRC=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo ./bin/uninstall.sh" >&2
  exit 1
fi

ROLE="unknown"
if [[ -f /etc/clp-sync/role ]]; then
  ROLE="$(tr -d '[:space:]' </etc/clp-sync/role)"
elif [[ -f /etc/clp-sync/config.env ]]; then
  # shellcheck disable=SC1091
  source /etc/clp-sync/config.env
  ROLE="${ROLE:-unknown}"
fi

echo
echo "============================================"
echo "  CloudPanel Hot-Standby Sync Uninstaller"
echo "============================================"
echo
echo "  Detected role : ${ROLE}"
echo "  Install path  : ${INSTALL_DEST}"
echo
echo "This removes the sync agent only — NOT CloudPanel or your sites."
echo

confirm() {
  local prompt="$1"
  [[ "${FORCE}" -eq 1 ]] && return 0
  local ans
  read -r -p "${prompt} [y/N]: " ans || true
  [[ "${ans}" =~ ^[Yy]$ ]]
}

confirm "Proceed with uninstall?" || { echo "Cancelled."; exit 0; }

echo
echo "==> Stopping sync timer and service..."
systemctl stop clp-sync.timer 2>/dev/null || true
systemctl stop clp-sync.service 2>/dev/null || true
systemctl disable clp-sync.timer 2>/dev/null || true
systemctl disable clp-sync.service 2>/dev/null || true

echo "==> Removing systemd units..."
rm -f /etc/systemd/system/clp-sync.service /etc/systemd/system/clp-sync.timer
systemctl daemon-reload

echo "==> Removing install and state..."
rm -rf "${INSTALL_DEST}"
rm -rf /etc/clp-sync
rm -rf /var/lib/clp-sync
rm -rf /var/log/clp-sync
rm -rf /var/tmp/clp-sync

if [[ "${ROLE}" == "standby" || "${ROLE}" == "master" ]]; then
  :
fi

# Standby: remove master sync key from authorized_keys
if [[ "${ROLE}" == "standby" && -f /root/.ssh/authorized_keys ]]; then
  if grep -q 'clp-sync-master' /root/.ssh/authorized_keys 2>/dev/null; then
    echo "==> Removing clp-sync-master key from /root/.ssh/authorized_keys..."
    grep -v 'clp-sync-master' /root/.ssh/authorized_keys > /root/.ssh/authorized_keys.tmp || true
    mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  fi
fi

# Master: optional SSH key removal
if [[ "${ROLE}" == "master" && "${KEEP_SSH_KEY}" -eq 0 ]]; then
  if [[ -f /root/.ssh/clp_sync_ed25519 ]]; then
    if confirm "Remove master sync SSH key /root/.ssh/clp_sync_ed25519?"; then
      rm -f /root/.ssh/clp_sync_ed25519 /root/.ssh/clp_sync_ed25519.pub
      echo "    Removed sync SSH key"
    fi
  fi
fi

# Optional: remove git clone source dir
if [[ "${KEEP_SRC}" -eq 0 && -d "${ROOT}" && "${ROOT}" != "${INSTALL_DEST}" ]]; then
  if confirm "Remove source directory ${ROOT}?"; then
    rm -rf "${ROOT}"
    echo "    Removed ${ROOT}"
  fi
fi

echo
echo "============================================"
echo "  Uninstall complete"
echo "============================================"
echo
if [[ "${ROLE}" == "master" ]]; then
  echo "  Master: sync stopped. CloudPanel and sites unchanged."
elif [[ "${ROLE}" == "standby" ]]; then
  echo "  Standby: receiver config removed. Mirrored sites/data remain."
else
  echo "  clp-sync removed from this host."
fi
echo
