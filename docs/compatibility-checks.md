# Compatibility checks

Preflight validation ensures master and standby can sync safely.

---

## When checks run

| Trigger | Scope |
|---------|-------|
| `./bin/install.sh` | Local checks on each server |
| `./bin/install.sh` (master, after pair) | Full cross-host comparison |
| `clp-bootstrap` | Full checks (must pass) |
| `clp-sync` (every 15 min) | Quick pre-sync check |
| `clp-failover-check` | Sync freshness + compatibility |

Override in emergencies: `clp-sync --skip-checks` (not recommended).

---

## Manual commands

```bash
# Full check on master (local + standby comparison)
/opt/clp-sync/bin/clp-check all

# This server only
/opt/clp-sync/bin/clp-check local master
/opt/clp-sync/bin/clp-check local standby

# Quick pre-sync style check
/opt/clp-sync/bin/clp-check sync

# Compare with standby over SSH
/opt/clp-sync/bin/clp-check peer
```

---

## Local checks (each server)

| Check | Pass criteria |
|-------|---------------|
| OS | Ubuntu/Debian (warn on others) |
| Architecture | x86_64 or arm64 |
| Tailscale | Connected with IPv4 |
| CloudPanel | `clpctl` + `/home/clp/htdocs/app/data/db.sq3` |
| nginx | Running |
| MySQL/MariaDB | Running |
| Tools | rsync, sqlite3, openssl, python3, flock (+ mysqldump/ssh on master) |
| Disk | `/home` has adequate free space |
| Sync paths | Master: writable `/var/lib/clp-sync`, etc. |

---

## Cross-host checks (master → standby)

| Check | Pass criteria |
|-------|---------------|
| Distinct hosts | Different Tailscale IP |
| Architecture | Match (e.g. both amd64) |
| OS | Same or warn if different |
| CloudPanel version | Match or same major |
| PHP versions | Standby has every PHP version used on master sites |
| Disk | Standby `/home` free ≥ master data used + buffer |
| Standby services | nginx + MySQL active |
| Standby tools | rsync, sqlite3, python3, clpctl |

---

## Understanding results

```
  PASS  All good
  WARN  May work but investigate (e.g. OS differs slightly)
  FAIL  Do not sync until fixed
```

Install and bootstrap **stop on FAIL** unless you explicitly override.

---

## Common failures

### Standby missing PHP version

Master site uses PHP 8.2 but standby only has 8.1.

**Fix:** Install PHP 8.2 on standby via CloudPanel admin → Settings → PHP.

### Standby disk too small

**Fix:** Expand disk/partition or clean standby before first sync.

### CloudPanel version mismatch

**Fix:** Upgrade/downgrade so both servers run the same CloudPanel major version.

### Tailscale not connected

```bash
tailscale up
tailscale status
```

### Standby nginx/MySQL not running

```bash
systemctl start nginx mysql   # or mariadb
systemctl enable nginx mysql
```
