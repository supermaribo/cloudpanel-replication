# CloudPanel Hot Standby Sync

One-way **identical mirror** from a live CloudPanel **master** to a **standby** over **Tailscale**. Interactive installer on **both** machines; they pair with a one-time token. Sync is **read-only on the master** (only the standby is written).

## Install (both servers)

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./bin/install.sh
```

### 1) Standby first

- Choose **2) Standby**
- Note the **Tailscale name/IP** and **pairing token**
- Leave the pairing listener running (or start it when prompted)

### 2) Master second

- Choose **1) Master**
- Enter the standby host + token from step 1
- Installer pairs SSH, then can bootstrap + enable the 15‑minute timer
- Confirms: **no CloudPanel site changes on the master**

## What is mirrored

| Layer | How |
|-------|-----|
| Site files | rsync (includes SSH keys, SSL under homes) |
| Linux / FTP / `clp` users | password hashes, shells, groups |
| SSL / Let's Encrypt | nginx certs + related ACME paths |
| PHP-FPM pools, nginx, crons | mirrored |
| MySQL | dump/import; skip unchanged |
| CloudPanel panel DB | applied on standby |

**Not mirrored:** SSH host keys, Tailscale identity, public IP/hostname, root `authorized_keys` (except the sync key added at pair time).

**RPO:** ~15 minutes. **Failover:** point DNS/IP at standby.

## Checks

```bash
# on master
/opt/clp-sync/bin/clp-failover-check 30
journalctl -u clp-sync.service -f
```

## Uninstall (master)

```bash
systemctl disable --now clp-sync.timer
rm -f /etc/systemd/system/clp-sync.service /etc/systemd/system/clp-sync.timer
systemctl daemon-reload
```
