# CloudPanel Hot Standby Sync

One-way, **identical mirror** replication from a **primary** CloudPanel server to a **hot standby** over **Tailscale**. Runs every **15 minutes**. Transfers only deltas (rsync + MySQL dump checksums).

## What is mirrored

| Layer | How |
|-------|-----|
| Site files (`/home/<siteUser>/`) | `rsync -aHAX --delete` including **SSH keys** (`.ssh/`), site SSL under `etc/ssl/`, all app data |
| Linux users | Same site/FTP/`clp` users; **password hashes** from `/etc/shadow`, shells, groups |
| SSH access | Site-user and `clp` `authorized_keys` / key files synced; permissions fixed after rsync |
| Let's Encrypt / SSL | `/etc/nginx/ssl-certificates`, nginx site configs, optional `/etc/letsencrypt`, panel ACME dirs |
| PHP-FPM pools | `/etc/php/*/fpm/pool.d` so nginx upstream ports match |
| MySQL databases + app DB passwords | Dump/import; passwords aligned from `wp-config.php` / `.env` |
| Cron jobs | `/etc/cron.d/<siteUser>` |
| FTP users | Created on standby; hashes mirrored with other users |
| CloudPanel panel | Live `db.sq3` **applied** on standby (admin users, sites, SSL metadata, FTP rows) + data dir |

**Not mirrored (by design):** SSH **host** keys, Tailscale identity, public NIC / hostname, root’s `authorized_keys` (so the sync key is not wiped). Email/Postfix is out of scope unless you add it later.

**RPO:** up to ~15 minutes. **Failover:** manual DNS or floating IP.

## Requirements

- Two Ubuntu hosts with **matching CloudPanel major version**
- Both on the same **Tailscale** tailnet
- Root SSH from primary → standby over Tailscale (key auth)
- Packages on primary: `rsync`, `sqlite3`, `mysql-client` / `mariadb-client`, `openssl`
- Standby: working `clpctl`, nginx, MySQL/MariaDB

## Install (on primary)

```bash
cd /path/to/CloudPanel-Replication
sudo ./bin/install.sh
sudo nano /etc/clp-sync/config.env   # STANDBY_HOST = Tailscale name/IP
```

### SSH over Tailscale

```bash
ssh-keygen -t ed25519 -f /root/.ssh/clp_sync_ed25519 -N ''
ssh-copy-id -i /root/.ssh/clp_sync_ed25519.pub root@cloudpanel-standby
```

```bash
STANDBY_HOST=cloudpanel-standby
STANDBY_SSH_KEY=/root/.ssh/clp_sync_ed25519
APPLY_PANEL_DB=1
```

### First sync

```bash
sudo /opt/clp-sync/bin/clp-sync --connect-only
sudo /opt/clp-sync/bin/clp-bootstrap
sudo systemctl enable --now clp-sync.timer
journalctl -u clp-sync.service -n 100 --no-pager
```

## Failover runbook

1. `sudo /opt/clp-sync/bin/clp-failover-check 30`
2. `sudo systemctl stop clp-sync.timer` on primary (if still up)
3. Point DNS / floating IP at standby
4. On standby: sites should already have the same LE certs; renew only if needed:
   `clpctl lets-encrypt:install:certificate --domainName=example.com`
5. Promote standby to primary; rebuild the old node as the new standby later

## Notes

- **One-way.** Do not edit live content on the standby while it is the replica.
- After failover, issue LE renewals from the **new** primary (DNS must point here).
- `APPLY_PANEL_DB=1` makes panel logins/users identical; keep CloudPanel versions matched.
- Set `FAIL_NOTIFY_CMD` for failure alerts.

## Uninstall

```bash
sudo systemctl disable --now clp-sync.timer
sudo rm -f /etc/systemd/system/clp-sync.service /etc/systemd/system/clp-sync.timer
sudo systemctl daemon-reload
```
