# Master read-only policy

The **master** is your live CloudPanel server. This project must **never modify** the CloudPanel stack on the master.

---

## Hard rules (enforced in code)

| Action | Master install | Master sync |
|--------|:--------------:|:-----------:|
| `apt-get` / `apt install` | **Never** | **Never** |
| `clpctl` | **Never** | **Never** |
| Modify `/home/*/htdocs` | **Never** | **Never** (read only) |
| Modify `/etc/nginx`, `/etc/php`, `/etc/mysql` | **Never** | **Never** (read only) |
| `mysqldump` | — | Read only |
| SQLite `.backup` of panel DB | — | Read only |
| Write to standby over SSH | — | Yes (standby only) |

---

## What the master installer adds

These paths are **outside** CloudPanel and are safe to remove with `uninstall.sh`:

```
/opt/clp-sync/              Sync scripts
/etc/clp-sync/              Config only
/var/lib/clp-sync/          Checksums, status
/var/log/clp-sync/          Logs
/var/tmp/clp-sync/          Temp dumps (not site data)
/etc/systemd/system/clp-sync.*   Timer (additive)
/root/.ssh/clp_sync_ed25519     SSH key for standby
/root/clp-sync-src/             Git clone (optional)
```

---

## What sync reads on the master (never writes)

- Site files under `/home/<user>/`
- MySQL databases via `mysqldump`
- `/etc/nginx/` configs (as rsync source), including `nginx.conf` / `php.ini`
- Site-user crontabs (`clp-sync-crontabs`)
- `/home/clp/htdocs/app/data/db.sq3` via SQLite `.backup`
- `/etc/php/*/fpm/php.ini` and `conf.d`
- `/etc/shadow` (password hashes exported to standby)

Temp files written locally: `/var/tmp/clp-sync/` dumps only.

---

## Standby vs master

| | Master | Standby |
|---|--------|---------|
| Install role | `1` | `2` |
| CloudPanel modified by sync | No | Yes (receives mirror) |
| `apt-get` in our scripts | **Never** | **Never** |
| `clpctl site:add` | Never | Yes (via SSH from master) |

---

## If Percona was removed

An **older version** of this installer incorrectly ran `apt-get install mysql-client` on the master path. That must **never** happen again. Current code has **zero** apt calls.

See [recovery-percona.md](recovery-percona.md).

---

## Verify before install

On the master:

```bash
command -v rsync sqlite3 mysqldump ssh flock python3 clpctl
```

All must exist (CloudPanel normally provides mysqldump). If missing, repair via CloudPanel support — **do not** `apt install mysql-client` or `default-mysql-client`.
