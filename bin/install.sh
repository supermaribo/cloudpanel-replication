#!/usr/bin/env bash
# Install clp-sync onto this primary CloudPanel host.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DEST:-/opt/clp-sync}"

echo "Installing from ${SRC} → ${DEST}"
mkdir -p "${DEST}"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'config.env' \
  "${SRC}/" "${DEST}/"

chmod 755 "${DEST}/bin"/clp-*
chmod 644 "${DEST}/systemd"/* "${DEST}/excludes"/* "${DEST}/config.example.env"

mkdir -p /etc/clp-sync /var/lib/clp-sync /var/log/clp-sync /var/tmp/clp-sync
chmod 700 /var/lib/clp-sync /var/tmp/clp-sync

if [[ ! -f /etc/clp-sync/config.env ]]; then
  cp "${DEST}/config.example.env" /etc/clp-sync/config.env
  chmod 600 /etc/clp-sync/config.env
  echo "Wrote /etc/clp-sync/config.env — edit STANDBY_HOST before enabling the timer"
else
  echo "Keeping existing /etc/clp-sync/config.env"
fi

# Point excludes path at install location
if grep -q '^RSYNC_EXCLUDES_FILE=' /etc/clp-sync/config.env; then
  sed -i 's|^RSYNC_EXCLUDES_FILE=.*|RSYNC_EXCLUDES_FILE=/opt/clp-sync/excludes/rsync-excludes.txt|' /etc/clp-sync/config.env
fi

install -m 644 "${DEST}/systemd/clp-sync.service" /etc/systemd/system/clp-sync.service
install -m 644 "${DEST}/systemd/clp-sync.timer" /etc/systemd/system/clp-sync.timer
systemctl daemon-reload

echo
echo "Next steps:"
echo "  1. Edit /etc/clp-sync/config.env (STANDBY_HOST Tailscale name/IP)"
echo "  2. Install SSH key: ssh-copy-id -i ~/.ssh/clp_sync_ed25519.pub root@<standby>"
echo "  3. Test:  /opt/clp-sync/bin/clp-sync --connect-only"
echo "  4. Bootstrap: /opt/clp-sync/bin/clp-bootstrap"
echo "  5. Enable: systemctl enable --now clp-sync.timer"
echo "  6. Watch:  journalctl -u clp-sync.service -f"
