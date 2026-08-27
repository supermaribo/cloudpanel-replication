# Architecture

How CloudPanel hot-standby sync is designed.

---

## Overview

```
┌─────────────────────────┐         Tailscale          ┌─────────────────────────┐
│         MASTER          │         (encrypted)        │        STANDBY          │
│   Live CloudPanel       │ ───── SSH / rsync ───────► │   Mirror CloudPanel     │
│                         │                            │                         │
│  • clp-sync timer       │   read-only on master      │  • receives all writes  │
│  • mysqldump (read)     │                            │  • no sync timer        │
│  • rsync (read)         │                            │  • pairing listener     │
└─────────────────────────┘                            └─────────────────────────┘
```

- **One-way sync:** master → standby only
- **Schedule:** systemd timer every 15 minutes on master
- **Transport:** SSH over Tailscale (100.x or MagicDNS)
- **Idempotent:** overlapping runs blocked with `flock`

---

## What runs where

| Component | Master | Standby |
|-----------|:------:|:-------:|
| `./bin/install.sh` | ✓ | ✓ |
| `clp-pair-listen` (during setup) | | ✓ |
| `clp-sync` / systemd timer | ✓ | |
| `clp-bootstrap` | ✓ | |
| `clp-check` | ✓ | ✓ (local only) |
| CloudPanel sites served | ✓ (live) | ✓ (mirror, don't edit) |

---

## Sync pipeline (each run)

1. **Lock** — prevent concurrent runs
2. **Snapshot** — CloudPanel SQLite via `.backup` (consistent read)
3. **Bootstrap** — create missing sites/DBs on standby via `clpctl`
4. **FTP users** — ensure Linux accounts exist on standby
5. **Files** — rsync `/home/<siteUser>/` to standby
6. **User identities** — copy shadow hashes, shells, groups, fix `.ssh` perms
7. **MySQL** — dump on master; import on standby if dump changed
8. **Nginx / SSL / PHP-FPM / crons** — rsync configs, reload services
9. **Panel DB** — apply primary `db.sq3` on standby
10. **Status** — write `/var/lib/clp-sync/last-status`

---

## Read-only guarantee on master

The sync **never writes to**:

- `/home/*/htdocs/` (site files)
- MySQL databases (only `mysqldump` reads)
- `/etc/nginx/` live configs (only read for rsync source)
- CloudPanel live `db.sq3` (only `.backup` snapshot)

The sync **may write on master**:

- `/opt/clp-sync` — toolkit
- `/etc/clp-sync/` — config
- `/var/lib/clp-sync/` — checksums, last-status
- `/var/tmp/clp-sync/` — temp dumps
- `/var/log/clp-sync/` — logs

---

## Pairing (first-time link)

1. Standby installer generates a **one-time token**
2. Standby runs `clp-pair-listen` on Tailscale IP:18765
3. Master sends token + SSH public key over TCP
4. Standby validates token, appends key to `/root/.ssh/authorized_keys`
5. Master uses `/root/.ssh/clp_sync_ed25519` for all future sync

---

## Failover model

- **Hot standby:** standby has identical data, ready to serve
- **Manual cutover:** you change DNS or floating IP
- **Not automatic:** no DNS/API integration in v1
- **After cutover:** stop syncing from old master; promote standby as new master

See [Failover guide](failover.md).

---

## State files

| Path | Server | Purpose |
|------|--------|---------|
| `/etc/clp-sync/config.env` | both | Role, peer host, SSH key |
| `/etc/clp-sync/role` | both | `master` or `standby` |
| `/var/lib/clp-sync/last-status` | master | Last sync result + timestamp |
| `/var/lib/clp-sync/db-checksums/` | master | Per-DB dump SHA256 |
| `/var/log/clp-sync/` | master | Daily sync logs |
