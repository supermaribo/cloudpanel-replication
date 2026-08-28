# Operations

Day-to-day management of CloudPanel hot-standby sync.

The **replica pulls**. Live only answers a restricted SSH key. PHP-FPM/OPcache caps (`clp-tune`) are **manual** and never run as part of sync.

---

## Installed paths

| Path | Description |
|------|-------------|
| `/opt/clp-sync/` | Sync toolkit |
| `/etc/clp-sync/config.env` | Configuration (chmod 600) |
| `/etc/clp-sync/role` | `master` or `standby` |
| `/var/lib/clp-sync/` | State, checksums, last-status |
| `/var/log/clp-sync/` | Logs |

---

## Common commands (replica)

```bash
# Probe live SSH
sudo /opt/clp-sync/bin/clp-sync --connect-only

# Sync now (same as CloudPanel “Sync now”)
sudo /opt/clp-sync/bin/clp-sync --manual

# RAM / PHP-FPM snapshot (live or replica; no writes)
sudo /opt/clp-sync/bin/clp-sync --resources

# Pause / resume / interval
sudo /opt/clp-sync/bin/clp-sync-control off
sudo /opt/clp-sync/bin/clp-sync-control on
sudo /opt/clp-sync/bin/clp-sync-control interval 12h
sudo /opt/clp-sync/bin/clp-sync-control status
```

## Failover (replica → live)

```bash
# After DNS is pointed here
sudo /opt/clp-sync/bin/clp-promote
```

Or use **Make live** in the replica CloudPanel UI (type `LIVE`). See [Failover](failover.md).

---

## Sync timer

The timer runs on the **replica**, not on live.

```bash
systemctl list-timers clp-sync.timer
systemctl enable --now clp-sync.timer
systemctl disable --now clp-sync.timer
journalctl -u clp-sync.service -f
journalctl -u clp-sync.service -n 100 --no-pager
```

Default unit interval: **1 hour** after the last run (5 min after boot). The replica CloudPanel badge can set **1h / 2h / 4h / 6h / 12h / 24h / off**.

---

## Updating the toolkit

Code lives in `/opt/clp-sync`. Config stays in `/etc/clp-sync/config.env` (never overwrite that).

From **live**, pull the toolkit from the replica:

```bash
sudo rsync -a --exclude config.env --exclude '.git/' \
  root@<replica-tailscale>:/opt/clp-sync/ /opt/clp-sync/
sudo chmod 755 /opt/clp-sync/bin/*
```

---

## Skip options (advanced)

```bash
sudo /opt/clp-sync/bin/clp-sync --manual --skip-files
sudo /opt/clp-sync/bin/clp-sync --manual --skip-mysql
sudo /opt/clp-sync/bin/clp-sync --manual --skip-nginx
sudo /opt/clp-sync/bin/clp-sync --connect-only
```

---

## Configuration

Edit `/etc/clp-sync/config.env` on the replica:

```bash
ROLE=standby
MASTER_HOST=live-tailscale-name
MASTER_SSH_KEY=/root/.ssh/clp_sync_ed25519
APPLY_PANEL_DB=1
MYSQL_SKIP_UNCHANGED=1
SYNC_INTERVAL=1h
FAIL_NOTIFY_CMD=    # optional webhook, e.g. curl to ntfy
```

After changes, no restart needed — next timer or Sync now picks up config.

---

## Excludes

Edit `/opt/clp-sync/excludes/rsync-excludes.txt` to skip logs and temp files.

Site homes copy **everything else** (including Laravel `bootstrap/cache` and web caches). Logs and `tmp/` are not copied; empty log files are created on the replica so nginx/PHP can write locally.

Ownership is rewritten to the site user (`rsync --chown=user:user`); file **modes** stay as on live. Do not `chmod -R` a site home (that would break `.ssh`).

**Note:** `.ssh/` is **included** (mirrored) so site SSH access matches master.

---

## How long a sync takes

Most of the time is **MySQL import on the replica** when a database actually changed. Unchanged databases skip the load. The replica:

- Dumps from live over Tailscale as the site DB user (read-only)
- Relaxes InnoDB flush and turns **redo logging off for that import only**, then turns it back on
- Skips rsync of `php*-fpm` versions that no site uses (for example 7.1–8.4 when sites are on 8.5)

Files + nginx are typically tens of seconds. A full run with two changed databases used to take ~400s on a 2 GiB LXC because every InnoDB commit fsynced; import speedup is replica-only and does not change live MySQL.

---

## RAM, PHP-FPM, and high demand

The replica **mirrors live** PHP-FPM / nginx settings so failover is not a surprise. Do not detune the replica. Change pools in **CloudPanel on live**; the next pull copies them.

Read-only snapshot (safe on live or replica, no config writes):

```bash
sudo /opt/clp-sync/bin/clp-sync --resources
```

To **apply** caps on LIVE (does not touch MySQL). This is **manual only** — `clp-sync` never runs it. Pull the toolkit from the replica first, dry-run, then apply:

```bash
sudo rsync -a --exclude config.env --exclude '.git/' \
  root@<replica-tailscale>:/opt/clp-sync/ /opt/clp-sync/
sudo chmod 755 /opt/clp-sync/bin/*
sudo /opt/clp-sync/bin/clp-tune
sudo /opt/clp-sync/bin/clp-tune --apply
```

Then Sync now on the replica so it matches. If you later save a vhost in the CloudPanel UI, keep these OPcache values.

`clp-tune` sets `pm=ondemand`, `pm.max_children=100`, idle timeout 5s, `pm.max_requests=300`, OPcache 256M / JIT 32M / 100000 files, and stops `php*-fpm` versions with no sites (never `clp-php-fpm`). MySQL is left alone.

The replica already stops unused `php*-fpm`, leaves Varnish off when live is off, and disables CloudPanel backup cron while it is standby.

---

## Notifications on failure

Set in `config.env`:

```bash
FAIL_NOTIFY_CMD='curl -fsS -d "clp-sync failed on $(hostname)" https://ntfy.sh/your-topic'
```

---

## Rules of operation

1. **One-way only** — never edit live site content on the standby while it is the replica
2. **Master is source of truth** — all changes happen on live; the replica pulls
3. **`clp-sync` runs on the replica** — live only allows the restricted pull key
4. **Keep CloudPanel versions matched** between master and standby
5. **`clp-tune` is opt-in** — run it when you want FPM/OPcache caps, not on every sync

---

## Reversing roles

Use **Make live** on the replica (or `clp-promote`) after DNS. Pairing (`clp-pair-peer`) lets the old live become the new replica.

See [Failover](failover.md).
