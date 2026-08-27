# Troubleshooting

Common issues and fixes.

---

## URGENT: apt removed MariaDB / reinstalled MySQL

**What happened:** An older installer ran `apt-get install mysql-client` if `mysqldump` was missing. CloudPanel uses **MariaDB** — installing Oracle MySQL client/server packages can **remove and replace** MariaDB. This must never run on a live master.

**Stop sync now (master):**

```bash
systemctl stop clp-sync.timer clp-sync.service
```

**Check damage:**

```bash
systemctl status mariadb mysql
dpkg -l | grep -E 'maria|mysql'
```

**Recovery:** Restore from backup/snapshot if databases are down. Reinstall MariaDB via CloudPanel docs/support. Do not run `apt install mysql-server` blindly.

**Fixed in latest repo:** installer never auto-installs mysql-client. Use:

```bash
CLP_SYNC_SKIP_APT=1 ./bin/install.sh
```

---

## Install / pairing

### `mysqldump: Access denied for user 'root'@'localhost' (using password: NO)`

CloudPanel MySQL root is usually `root@127.0.0.1` with a password from `clpctl db:show:master-credentials`. Socket `root@localhost` has no password and is denied.

The sync now authenticates with those credentials, or falls back to read-only `clpctl db:export`.

Update `/opt/clp-sync` and re-run:

```bash
curl -fsSL https://github.com/supermaribo/cloudpanel-replication/archive/refs/heads/main.tar.gz | sudo tar xz -C /opt/clp-sync --strip-components=1
sudo /opt/clp-sync/bin/clp-bootstrap
```

### Vhost template “does not exist” / only one site bootstrapped

CloudPanel stores the **full nginx vhost** in SQLite. That used to break the site list (newlines) so later sites were skipped. Bootstrap now uses template `Generic`, then rsync copies the real vhost from `/etc/nginx`.

---

### `syntax error near unexpected token '('` during bootstrap

SSH was sending `clpctl site:add:php` unquoted. A vhost template with a space or `(` (for example `Laravel 11`) was parsed as shell on the standby.

**Master CloudPanel is unchanged.** Update the agent and re-run bootstrap (writes to standby only):

```bash
curl -fsSL https://github.com/supermaribo/cloudpanel-replication/archive/refs/heads/main.tar.gz | sudo tar xz -C /opt/clp-sync --strip-components=1
sudo /opt/clp-sync/bin/clp-bootstrap
```

---

### Stuck looping on “Choose 1 or 2”

`curl | sudo bash` feeds the script on stdin, so the installer could not read the keyboard and treated every empty Enter as “try again”.

**Stop:** Ctrl+C

**Standby — use this instead:**

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=standby bash
```

Or, if `/root/clp-sync-src` already exists:

```bash
sudo CLP_SYNC_ROLE=standby /root/clp-sync-src/bin/install.sh
```

### `Tailscale not connected`

```bash
tailscale up
tailscale status
tailscale ip -4
```

Both servers must show as online on the same tailnet.

### Pairing fails / `ERR bad token`

- Standby listener must be running: `/opt/clp-sync/bin/clp-pair-listen --bind $(tailscale ip -4)`
- Token is one-time — re-run standby installer for a new token if expired
- Check firewall allows port **18765** on Tailscale interface (usually open by default)

### `SSH or clpctl check failed on standby`

From master:

```bash
ssh -i /root/.ssh/clp_sync_ed25519 root@STANDBY_HOST
```

Fix SSH first. Ensure CloudPanel is installed on standby (`clpctl --version`).

---

## Sync failures

### `Another clp-sync run holds lock`

Previous run stuck or killed. Wait or remove stale lock:

```bash
# Only if no sync process running:
rm -f /var/lib/clp-sync/clp-sync.lock
```

### `Preflight checks failed`

```bash
/opt/clp-sync/bin/clp-check all
```

Fix reported FAIL items. Emergency override: `clp-sync --skip-checks`.

### MySQL import failed

- Check standby MySQL running: `systemctl status mysql`
- Ensure database exists on standby (bootstrap should create it)
- Check disk space on standby
- Review log: `journalctl -u clp-sync.service -n 200`

### rsync permission errors

- Sync runs as root — usually group/ownership on standby
- Re-run bootstrap: `/opt/clp-sync/bin/clp-bootstrap`

### nginx reload failed on standby

```bash
ssh root@STANDBY nginx -t
```

Fix config syntax on master (bad config synced to standby).

---

## Compatibility

### PHP version missing on standby

Install via CloudPanel → Settings → PHP on standby server.

### Disk full on standby

```bash
df -h /home
du -sh /home/*
```

Expand volume or clean unused data before sync.

### Site counts differ

```bash
/opt/clp-sync/bin/clp-bootstrap
/opt/clp-sync/bin/clp-sync
```

---

## Failover

### Sites don't load after DNS switch

- Confirm DNS points to standby public IP: `dig +short domain.com`
- Check nginx on standby: `systemctl status nginx`
- Check site configs exist: `ls /etc/nginx/sites-enabled/`

### SSL certificate errors

Certs should have synced. If not:

```bash
clpctl lets-encrypt:install:certificate --domainName=example.com
```

DNS must point to standby for LE validation.

### CloudPanel login fails on standby

Ensure `APPLY_PANEL_DB=1` in config and last sync succeeded. Re-run:

```bash
/opt/clp-sync/bin/clp-sync
```

---

## Logs

```bash
# Sync service
journalctl -u clp-sync.service -f

# Daily log files
ls -la /var/log/clp-sync/
tail -f /var/log/clp-sync/sync-$(date -u +%Y%m%d).log

# Last status
cat /var/lib/clp-sync/last-status
```

---

## Getting help

When reporting issues, include:

```bash
/opt/clp-sync/bin/clp-check all
cat /var/lib/clp-sync/last-status
journalctl -u clp-sync.service -n 100 --no-pager
uname -a
clpctl --version 2>/dev/null || true
```

Redact passwords and domain names if posting publicly.
