#!/usr/bin/env bash
# Interactive installer — run on BOTH master and standby.
# Master: read-only toward CloudPanel; only installs sync agent + pushes to standby.
# Standby: prepares receiver, prints pairing info, waits for master to link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/install-common.sh
source "${ROOT}/lib/install-common.sh"
# shellcheck source=../lib/checks.sh
source "${ROOT}/lib/checks.sh"
# shellcheck source=../lib/master-readonly.sh
source "${ROOT}/lib/master-readonly.sh"

require_root_install
ensure_install_tty || true

# --role / CLP_SYNC_ROLE skips the 1-or-2 prompt (needed for curl | bash).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      CLP_SYNC_ROLE="${2:-}"
      shift 2
      ;;
    --role=*)
      CLP_SYNC_ROLE="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: install.sh [--role master|standby]"
      echo "  Or set CLP_SYNC_ROLE=standby|master (1 or 2 also accepted)."
      exit 0
      ;;
    *)
      c_err "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo
echo "============================================"
echo "  CloudPanel Hot-Standby Sync Installer"
echo "============================================"
echo
echo "Install on BOTH servers over Tailscale. Same code; role is in config."
echo "  • Master  = LIVE (restricted SSH so the replica can pull; no timer)"
echo "  • Standby = replica (pulls on a timer; Make live swaps roles)"
echo

if ! command -v tailscale >/dev/null 2>&1; then
  c_err "Tailscale not found. Install and join the same tailnet first."
  exit 1
fi

TS_NAME="$(tailscale_self_name)"
TS_IP="$(tailscale_self_ip)"
[[ -n "${TS_IP}" ]] || { c_err "No Tailscale IPv4 — is Tailscale up? (tailscale up)"; exit 1; }

c_ok "This host Tailscale: ${TS_NAME:-unknown} (${TS_IP})"

if ! check_cloudpanel; then
  c_warn "CloudPanel not detected (clpctl / db.sq3)."
  if ! ask_yn "Continue anyway?" "n"; then
    exit 1
  fi
else
  c_ok "CloudPanel detected"
fi

ROLE=""
if [[ -n "${CLP_SYNC_ROLE:-}" ]]; then
  ROLE="$(normalize_install_role "${CLP_SYNC_ROLE}")"
  if [[ -z "${ROLE}" ]]; then
    c_err "Invalid CLP_SYNC_ROLE=${CLP_SYNC_ROLE} (use 1/master or 2/standby)"
    exit 1
  fi
  c_ok "Role: ${ROLE} (from CLP_SYNC_ROLE / --role)"
else
  echo
  echo "What is this server?"
  echo "  1) Master  — live site (clone FROM here; no site changes)"
  echo "  2) Standby — mirror target (clone TO here)  ← new/empty CloudPanel"
  echo
  c_warn "New empty server? Type 2. Do not press Enter."
  echo "  Tip: skip this prompt next time with CLP_SYNC_ROLE=standby"
  attempts=0
  while [[ -z "${ROLE}" ]]; do
    attempts=$((attempts + 1))
    if ((attempts > 5)); then
      c_err "No valid role after 5 tries. Stop with Ctrl+C if this is looping."
      echo "  Then: sudo CLP_SYNC_ROLE=standby /root/clp-sync-src/bin/install.sh"
      exit 1
    fi
    ask "Choose 1 or 2 (required)" ""
    ROLE="$(normalize_install_role "${REPLY}")"
    if [[ -z "${ROLE}" ]]; then
      c_err "Type 1 (master) or 2 (standby) — empty input is not allowed"
    fi
  done
fi

install_files

c_info "Running compatibility checks on this ${ROLE}..."
checks_reset
if ! run_local_preflight "${ROLE}"; then
  c_err "Local compatibility checks failed."
  if ! ask_yn "Continue anyway (not recommended)?" "n"; then
    exit 1
  fi
fi

# --------------------------------------------------------------------------
# STANDBY — generates pull key, timer off until first successful sync
# --------------------------------------------------------------------------
if [[ "${ROLE}" == "standby" ]]; then
  verify_standby_tools || exit 1

  SSH_KEY=/root/.ssh/clp_sync_ed25519
  if [[ ! -f "${SSH_KEY}" ]]; then
    c_info "Generating pull key ${SSH_KEY}"
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N '' -C "clp-sync-standby"
  fi
  chmod 600 "${SSH_KEY}" "${SSH_KEY}.pub"

  echo
  echo "Online Tailscale peers (pick the live master):"
  mapfile -t PEERS < <(tailscale_peers)
  if ((${#PEERS[@]})); then
    i=1
    for line in "${PEERS[@]}"; do
      name="${line%%$'\t'*}"
      ip="${line#*$'\t'}"
      printf "  %d) %s  (%s)\n" "${i}" "${name}" "${ip}"
      i=$((i + 1))
    done
  else
    c_warn "No online peers — enter master name/IP manually."
  fi
  ask "Master Tailscale name, 100.x IP, or peer number" ""
  MASTER_HOST="${REPLY}"
  [[ -n "${MASTER_HOST}" ]] || { c_err "Master host required"; exit 1; }
  if [[ "${MASTER_HOST}" =~ ^[0-9]+$ ]] && ((${#PEERS[@]})) && [[ "${MASTER_HOST}" -ge 1 && "${MASTER_HOST}" -le ${#PEERS[@]} ]]; then
    line="${PEERS[$((MASTER_HOST - 1))]}"
    name="${line%%$'\t'*}"
    ip="${line#*$'\t'}"
    MASTER_HOST="${name:-${ip}}"
  fi
  c_ok "Master: ${MASTER_HOST}"

  write_config standby "${MASTER_HOST}" "${SSH_KEY}"

  install -m 644 "${INSTALL_DEST}/systemd/clp-sync.service" /etc/systemd/system/clp-sync.service
  install -m 644 "${INSTALL_DEST}/systemd/clp-sync.timer" /etc/systemd/system/clp-sync.timer
  systemctl daemon-reload
  systemctl disable --now clp-sync.timer 2>/dev/null || true

  echo
  echo "============================================"
  echo "  STANDBY PULL KEY — authorize on the master"
  echo "============================================"
  echo
  echo "  Public key:"
  echo
  cat "${SSH_KEY}.pub"
  echo
  echo "On the MASTER run:"
  echo "  sudo /opt/clp-sync/bin/clp-allow-pull '$(cat "${SSH_KEY}.pub")'"
  echo "  sudo /opt/clp-sync/bin/clp-pair-peer $(tailscale_self_name 2>/dev/null || hostname)"
  echo
  echo "Then on THIS standby:"
  echo "  sudo /opt/clp-sync/bin/clp-sync --connect-only"
  echo "  sudo /opt/clp-sync/bin/clp-sync"
  echo
  echo "Timer stays off until: sudo /opt/clp-sync/bin/clp-sync-control on"
  echo
  exit 0
fi

# --------------------------------------------------------------------------
# MASTER — restricted SSH wrapper (timer installed, left off)
# --------------------------------------------------------------------------
verify_master_tools || exit 1

c_info "Master install: CloudPanel is READ-ONLY for sync"
echo "  Adds: /opt/clp-sync wrapper + pull key (for later role swap). No dumps on disk."

SSH_KEY=/root/.ssh/clp_sync_ed25519
ensure_pull_key "${SSH_KEY}"

echo
echo "Online Tailscale peers (pick the replica):"
mapfile -t PEERS < <(tailscale_peers)
if ((${#PEERS[@]})); then
  i=1
  for line in "${PEERS[@]}"; do
    name="${line%%$'\t'*}"
    ip="${line#*$'\t'}"
    printf "  %d) %s  (%s)\n" "${i}" "${name}" "${ip}"
    i=$((i + 1))
  done
else
  c_warn "No online peers — enter replica name/IP manually (or leave blank)."
fi
ask "Replica Tailscale name, 100.x IP, peer number, or empty" ""
PEER_HOST="${REPLY}"
if [[ "${PEER_HOST}" =~ ^[0-9]+$ ]] && ((${#PEERS[@]})) && [[ "${PEER_HOST}" -ge 1 && "${PEER_HOST}" -le ${#PEERS[@]} ]]; then
  line="${PEERS[$((PEER_HOST - 1))]}"
  name="${line%%$'\t'*}"
  ip="${line#*$'\t'}"
  PEER_HOST="${name:-${ip}}"
fi

write_config master "${PEER_HOST}" "${SSH_KEY}"

install -m 644 "${INSTALL_DEST}/systemd/clp-sync.service" /etc/systemd/system/clp-sync.service
install -m 644 "${INSTALL_DEST}/systemd/clp-sync.timer" /etc/systemd/system/clp-sync.timer
systemctl daemon-reload
systemctl disable --now clp-sync.timer 2>/dev/null || true

chmod 755 "${INSTALL_DEST}/bin/"*

echo
if ask_yn "Paste the replica public key now (clp-allow-pull)?" "n"; then
  ask "Replica public key line" ""
  [[ -n "${REPLY}" ]] && "${INSTALL_DEST}/bin/clp-allow-pull" "${REPLY}"
fi

"${INSTALL_DEST}/bin/clp-role" stamp-live 2>/dev/null || true

echo
echo "============================================"
echo "  MASTER SOURCE READY (LIVE)"
echo "============================================"
echo
echo "  This host does not pull. The replica pulls over SSH."
echo "  Authorize a key:  sudo /opt/clp-sync/bin/clp-allow-pull 'ssh-ed25519 AAAA…'"
echo "  This host public key (authorize ON the replica for role swap):"
echo "  $(cat "${SSH_KEY}.pub")"
if [[ -n "${PEER_HOST}" ]]; then
  echo
  echo "  On the replica run:"
  echo "    sudo /opt/clp-sync/bin/clp-allow-pull '$(cat "${SSH_KEY}.pub")'"
  echo "    sudo /opt/clp-sync/bin/clp-pair-peer $(tailscale_self_name 2>/dev/null || hostname)"
fi
echo "  Remove:           sudo /opt/clp-sync/bin/uninstall.sh -y"
echo
exit 0
