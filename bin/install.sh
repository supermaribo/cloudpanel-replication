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

require_root_install

echo
echo "============================================"
echo "  CloudPanel Hot-Standby Sync Installer"
echo "============================================"
echo
echo "Install this on BOTH servers. They link over Tailscale."
echo "  • Master  = your live CloudPanel (source; sync is read-only here)"
echo "  • Standby = empty/new CloudPanel (receives the mirror)"
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

echo
echo "What is this server?"
echo "  1) Master  — live site (clone FROM here; no site changes)"
echo "  2) Standby — mirror target (clone TO here)"
echo
ask "Choose 1 or 2" "1"
ROLE_CHOICE="${REPLY}"

case "${ROLE_CHOICE}" in
  1|m|M|master|Master) ROLE=master ;;
  2|s|S|standby|Standby|slave|Slave) ROLE=standby ;;
  *) c_err "Invalid choice"; exit 1 ;;
esac

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
# STANDBY
# --------------------------------------------------------------------------
if [[ "${ROLE}" == "standby" ]]; then
  ensure_packages_standby
  write_config standby "" ""

  TOKEN="$(generate_pair_token)"
  echo "${TOKEN}" >/etc/clp-sync/pair.token
  chmod 600 /etc/clp-sync/pair.token

  # Do not enable sync timer on standby
  systemctl disable --now clp-sync.timer 2>/dev/null || true
  rm -f /etc/systemd/system/clp-sync.timer /etc/systemd/system/clp-sync.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  echo
  echo "============================================"
  echo "  STANDBY READY — pair from the master"
  echo "============================================"
  echo
  echo "  Tailscale name : ${TS_NAME:-'(use IP)'}"
  echo "  Tailscale IP   : ${TS_IP}"
  echo "  Pairing token  : ${TOKEN}"
  echo "  Pair port      : ${PAIR_PORT}"
  echo
  echo "On the MASTER, run the same installer, choose Master,"
  echo "and enter this host + token when asked."
  echo
  if ask_yn "Start pairing listener now (waits for master)?" "y"; then
    echo
    c_info "Waiting for master to pair (up to 30 minutes)..."
    "${INSTALL_DEST}/bin/clp-pair-listen" --port "${PAIR_PORT}" --bind "${TS_IP}" --token "${TOKEN}"
    c_ok "Standby paired. Leave this server alone until sync finishes on the master."
  else
    echo
    echo "Start the listener later with:"
    echo "  /opt/clp-sync/bin/clp-pair-listen --bind ${TS_IP}"
  fi
  exit 0
fi

# --------------------------------------------------------------------------
# MASTER
# --------------------------------------------------------------------------
ensure_packages_master

c_info "Master mode: CloudPanel data is only READ — sites/DBs/users are not modified."
echo "  (Local sync state under /var/lib/clp-sync and temp dumps only.)"
echo

echo "Online Tailscale peers:"
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
  c_warn "No online peers listed — enter standby name/IP manually."
fi

echo
ask "Standby Tailscale name, 100.x IP, or peer number from list" ""
STANDBY_HOST="${REPLY}"
[[ -n "${STANDBY_HOST}" ]] || { c_err "Standby host required"; exit 1; }

if [[ "${STANDBY_HOST}" =~ ^[0-9]+$ ]] && ((${#PEERS[@]})) && [[ "${STANDBY_HOST}" -ge 1 && "${STANDBY_HOST}" -le ${#PEERS[@]} ]]; then
  line="${PEERS[$((STANDBY_HOST - 1))]}"
  name="${line%%$'\t'*}"
  ip="${line#*$'\t'}"
  STANDBY_HOST="${name:-${ip}}"
  c_ok "Selected peer: ${STANDBY_HOST}"
fi

ask "Pairing token (from standby installer)" ""
PAIR_TOKEN="${REPLY}"
[[ -n "${PAIR_TOKEN}" ]] || { c_err "Token required"; exit 1; }

ask "Pairing port" "${PAIR_PORT}"
PAIR_PORT="${REPLY}"

SSH_KEY=/root/.ssh/clp_sync_ed25519
if [[ ! -f "${SSH_KEY}" ]]; then
  c_info "Generating SSH key ${SSH_KEY}"
  ssh-keygen -t ed25519 -f "${SSH_KEY}" -N '' -C "clp-sync-master"
fi
PUBKEY="$(cat "${SSH_KEY}.pub")"

c_info "Pairing with standby ${STANDBY_HOST}:${PAIR_PORT} ..."
# Resolve bind: try host as-is
PAIR_TARGET="${STANDBY_HOST}"
python3 - <<PY
import socket, sys
host = "${PAIR_TARGET}"
port = int("${PAIR_PORT}")
token = """${PAIR_TOKEN}"""
pubkey = """${PUBKEY}""".strip()
payload = f"TOKEN={token}\nPUBKEY={pubkey}\n.\n".encode()
s = socket.create_connection((host, port), timeout=20)
s.sendall(payload)
resp = s.recv(1024).decode("utf-8", "replace")
s.close()
print(resp.strip())
if not resp.startswith("OK"):
    sys.exit(1)
PY
c_ok "SSH key installed on standby"

write_config master "${STANDBY_HOST}" "${SSH_KEY}"

# Install systemd units on master only
install -m 644 "${INSTALL_DEST}/systemd/clp-sync.service" /etc/systemd/system/clp-sync.service
install -m 644 "${INSTALL_DEST}/systemd/clp-sync.timer" /etc/systemd/system/clp-sync.timer
systemctl daemon-reload
c_ok "systemd units installed"

c_info "Testing SSH to standby..."
if ! ssh -i "${SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
  "root@${STANDBY_HOST}" "echo ok && command -v clpctl"; then
  c_err "SSH or clpctl check failed on standby"
  exit 1
fi
c_ok "Standby reachable"

c_info "Cross-host compatibility checks..."
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# Populate remote() using config we just wrote
load_config
checks_reset
if ! run_peer_compatibility master; then
  c_err "Master ↔ standby compatibility checks failed."
  if ! ask_yn "Continue with bootstrap anyway (not recommended)?" "n"; then
    exit 1
  fi
fi

echo
if ask_yn "Run first full clone (bootstrap) now? This only writes to the standby." "y"; then
  /opt/clp-sync/bin/clp-bootstrap
fi

echo
if ask_yn "Enable 15-minute sync timer on this master?" "y"; then
  systemctl enable --now clp-sync.timer
  c_ok "Timer enabled"
  systemctl list-timers clp-sync.timer --no-pager || true
fi

echo
echo "============================================"
echo "  MASTER SETUP COMPLETE"
echo "============================================"
echo
echo "  Sync is read-only on this server."
echo "  Status:  /opt/clp-sync/bin/clp-failover-check 30"
echo "  Logs:    journalctl -u clp-sync.service -f"
echo "  Manual:  /opt/clp-sync/bin/clp-sync"
echo "  Remove:  /opt/clp-sync/bin/uninstall.sh"
echo
