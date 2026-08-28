# Architecture

How CloudPanel hot-standby sync is designed.

---

## Overview

```
┌─────────────────────────┐         Tailscale          ┌─────────────────────────┐
│         MASTER          │         (encrypted)        │        STANDBY          │
│   Live CloudPanel       │ ◄──── SSH pull (rsync,     │   Mirror CloudPanel     │
│                         │       mysqldump stdout)    │                         │
│  • restricted SSH key   │   read-only on master      │  • clp-sync timer       │
│  • no dump files        │                            │  • Sync now / Make live │
│  • no sync timer        │                            │  • MySQL import         │
└─────────────────────────┘                            └─────────────────────────┘
```

- **One-way sync:** replica pulls from live
- **Schedule:** systemd timer on the **replica** (default 1h; CloudPanel UI 1h–24h or off)
- **Transport:** SSH over Tailscale (100.x or MagicDNS)
- **Idempotent:** overlapping runs blocked with `flock`
- **PHP-FPM tune:** `clp-tune` is separate and **manual** (never invoked by `clp-sync`)

---

## What runs where

| Component | Master (live) | Standby (replica) |
|-----------|:-------------:|:-----------------:|
| `./bin/install.sh` | ✓ | ✓ |
| `clp-master-read-only` (forced SSH) | ✓ | |
| `clp-allow-pull` | ✓ | |
| `clp-sync` / systemd timer | | ✓ |
| `clp-sync --resources` | ✓ | ✓ |
| `clp-tune` (manual) | ✓ (apply here) | copies result on next pull |
| CloudPanel Sync now / Make live | live badge only | ✓ |
| CloudPanel sites served | ✓ (live) | ✓ (mirror, don't edit) |

---

## Sync pipeline (each run)

1. **Lock** — prevent concurrent runs
2. **Probe** — restricted SSH (`clp-sync-probe`)
3. **Snapshot** — CloudPanel SQLite via `.backup` on live, applied locally
4. **Users** — Linux / FTP / `clp` hashes from live
5. **Files** — rsync `/home/<siteUser>/` (logs/`tmp` skipped)
6. **Nginx / PHP-FPM** — rsync configs for PHP versions **sites actually use**; reload
7. **Certs / cron / varnish** — rsync; site user crontabs
8. **MySQL** — dump from live:3306 as the site user; skip import if dump hash unchanged; on replica, import with redo log disabled for that load only
9. **Panel DB** — apply `db.sq3` locally (`cloud=''` so the replica does not hit IMDS)
10. **Services** — match varnish/redis/`php*-fpm` to live (never stop `clp-php-fpm`)
11. **Status** — write `/var/lib/clp-sync/last-status`

---

## Read-only guarantee on master

The sync **never writes to**:

- `/home/*/htdocs/` (site files)
- MySQL databases (only `mysqldump` reads as the site user)
- `/etc/nginx/` live configs (only read for rsync source)
- CloudPanel live `db.sq3` (only `.backup` snapshot)

The sync **may write on master**:

- `/opt/clp-sync` — toolkit (when you rsync it there)
- `/etc/clp-sync/` — config
- `/root/.ssh/authorized_keys` — restricted `command=` for the pull key

Temp dumps and MySQL import happen **only on the replica**.

---

## Pairing (first-time link)

1. Standby installer generates a pull key
2. Master `clp-allow-pull` installs `command=/opt/clp-sync/bin/clp-master-read-only`
3. Standby `clp-sync --connect-only` then `--manual`
4. Optional: `clp-pair-peer` so roles can swap later (Make live)

---

## Failover model

- **Hot standby:** replica has identical data, ready to serve
- **Manual cutover:** you change DNS, then Make live / `clp-promote`
- **Not automatic:** no DNS/API integration
- **After cutover:** old live becomes the new replica if pairing is in place

See [Failover guide](failover.md).

---

## State files

| Path | Server | Purpose |
|------|--------|---------|
| `/etc/clp-sync/config.env` | both | Role, peer host, SSH key |
| `/etc/clp-sync/role` | both | `master` or `standby` |
| `/var/lib/clp-sync/last-status` | replica | Last sync result + timestamp |
| `/var/lib/clp-sync/mysql-*.sha256` | replica | Per-DB dump hash (skip unchanged import) |
| `/var/log/clp-sync/` | replica | Daily sync logs |
