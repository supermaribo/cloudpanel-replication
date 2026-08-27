#!/usr/bin/env bash
# CloudPanel Hot Standby — full installer
#
# Clones (or updates) this repo and runs the interactive setup on THIS server.
#
# One-liner (standby OR master):
#   curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo bash
#
# Or download and run:
#   curl -fsSL -o install-full.sh https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh
#   chmod +x install-full.sh && sudo ./install-full.sh
#
# Install order: STANDBY first, then MASTER.
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

info "CloudPanel Hot Standby — full install"
echo "  Repo : ${REPO_URL}"
echo "  Path : ${INSTALL_DIR}"
echo

# --- Prerequisites ----------------------------------------------------------
info "Checking prerequisites..."

export DEBIAN_FRONTEND=noninteractive
need_pkg=()
for pkg in git curl ca-certificates; do
  dpkg -s "${pkg}" >/dev/null 2>&1 || need_pkg+=("${pkg}")
done
if ((${#need_pkg[@]})); then
  info "Installing: ${need_pkg[*]}"
  apt-get update -y
  apt-get install -y "${need_pkg[@]}"
fi
ok "git, curl available"

if ! command -v tailscale >/dev/null 2>&1; then
  err "Tailscale is not installed."
  echo "  Install: curl -fsSL https://tailscale.com/install.sh | sh && tailscale up"
  exit 1
fi
if ! tailscale ip -4 >/dev/null 2>&1; then
  err "Tailscale is not connected. Run: tailscale up"
  exit 1
fi
ok "Tailscale connected: $(tailscale ip -4 | head -1)"

if ! command -v clpctl >/dev/null 2>&1; then
  err "CloudPanel not found (clpctl missing)."
  echo "  Install CloudPanel first: https://www.cloudpanel.io/docs/v2/getting-started/"
  exit 1
fi
ok "CloudPanel detected"

# --- Clone or update --------------------------------------------------------
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  info "Updating existing clone at ${INSTALL_DIR}"
  git -C "${INSTALL_DIR}" fetch origin "${BRANCH}"
  git -C "${INSTALL_DIR}" checkout "${BRANCH}"
  git -C "${INSTALL_DIR}" pull origin "${BRANCH}" || true
else
  info "Cloning repository → ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"
  git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
fi
ok "Source ready at ${INSTALL_DIR}"

chmod +x "${INSTALL_DIR}/install-full.sh" "${INSTALL_DIR}/bin/"* 2>/dev/null || true

# --- Interactive setup --------------------------------------------------------
echo
info "Starting interactive installer..."
echo
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  STANDBY server  →  choose 2  (run this FIRST)          │"
echo "  │  MASTER server   →  choose 1  (run AFTER standby)         │"
echo "  └─────────────────────────────────────────────────────────┘"
echo

exec "${INSTALL_DIR}/bin/install.sh"
