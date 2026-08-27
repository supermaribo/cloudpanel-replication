#!/usr/bin/env bash
# CloudPanel Hot Standby — full installer
#
# NEVER runs apt-get. Safe on production CloudPanel master.
#
# One-liner (standby first, then master). Set the role so curl|bash cannot loop on 1/2:
#   curl -fsSL .../install-full.sh | sudo CLP_SYNC_ROLE=standby bash
#   curl -fsSL .../install-full.sh | sudo CLP_SYNC_ROLE=master bash
#
# Safer (real terminal stdin):
#   curl -fsSL .../install-full.sh -o /tmp/clp-install.sh && sudo bash /tmp/clp-install.sh
set -euo pipefail

REPO_URL="${CLP_SYNC_REPO:-https://github.com/supermaribo/cloudpanel-replication.git}"
INSTALL_DIR="${CLP_SYNC_INSTALL_DIR:-/root/clp-sync-src}"
BRANCH="${CLP_SYNC_BRANCH:-main}"

RED='\033[1;31m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
NC='\033[0m'

info()  { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}OK${NC}  %s\n" "$*"; }
err()   { printf "${RED}ERR${NC} %s\n" "$*" >&2; }

if [[ "$(id -u)" -ne 0 ]]; then
  err "Run as root: curl ... | sudo bash"
  exit 1
fi

info "CloudPanel Hot Standby — full install (NO apt-get on CloudPanel)"
echo "  Repo : ${REPO_URL}"
echo "  Path : ${INSTALL_DIR}"
echo

# --- Prerequisites (verify only — never apt) --------------------------------
info "Checking prerequisites (read-only — will not modify CloudPanel packages)..."

if ! command -v curl >/dev/null 2>&1; then
  err "curl is required. Install curl manually before running this script."
  exit 1
fi
ok "curl available"

if ! command -v tailscale >/dev/null 2>&1; then
  err "Tailscale not installed."
  echo "  Install: curl -fsSL https://tailscale.com/install.sh | sh && tailscale up"
  exit 1
fi
if ! tailscale ip -4 >/dev/null 2>&1; then
  err "Tailscale not connected. Run: tailscale up"
  exit 1
fi
ok "Tailscale connected: $(tailscale ip -4 | head -1)"

if ! command -v clpctl >/dev/null 2>&1; then
  err "CloudPanel not found (clpctl missing)."
  exit 1
fi
ok "CloudPanel detected"

# --- Fetch source (git or tarball — no apt) ---------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${ROOT}/lib/install-common.sh" ]]; then
  # shellcheck source=lib/install-common.sh
  source "${ROOT}/lib/install-common.sh"
  # shellcheck source=lib/master-readonly.sh
  source "${ROOT}/lib/master-readonly.sh"
  fetch_repo_no_apt "${REPO_URL}" "${INSTALL_DIR}" "${BRANCH}"
else
  # Running from curl pipe — bootstrap into INSTALL_DIR via tarball
  info "Downloading source to ${INSTALL_DIR}"
  command -v tar >/dev/null 2>&1 || { err "tar required"; exit 1; }
  tmp="$(mktemp /var/tmp/clp-sync-dl.XXXXXX.tgz)"
  curl -fsSL "https://github.com/supermaribo/cloudpanel-replication/archive/refs/heads/${BRANCH}.tar.gz" -o "${tmp}"
  rm -rf "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  tar xzf "${tmp}" -C "${INSTALL_DIR}" --strip-components=1
  rm -f "${tmp}"
fi
ok "Source ready at ${INSTALL_DIR}"

chmod +x "${INSTALL_DIR}/install-full.sh" "${INSTALL_DIR}/bin/"* 2>/dev/null || true

echo
info "Starting interactive installer..."
echo
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  STANDBY (new server)  →  CLP_SYNC_ROLE=standby (or 2)  │"
echo "  │  MASTER (live sites)   →  CLP_SYNC_ROLE=master  (or 1)  │"
echo "  │  Master: NO apt, NO CloudPanel changes — read-only sync  │"
echo "  └─────────────────────────────────────────────────────────┘"
echo

# Re-open the keyboard. curl | bash leaves stdin at EOF, which used to loop on 1/2.
if [[ -r /dev/tty ]]; then
  exec "${INSTALL_DIR}/bin/install.sh" "$@" </dev/tty
else
  exec "${INSTALL_DIR}/bin/install.sh" "$@"
fi
