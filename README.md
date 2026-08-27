# CloudPanel Hot Standby Sync

One-way **identical mirror** from a live CloudPanel **master** to a **hot standby** over **Tailscale**. An interactive installer runs on **both** servers; they link with a one-time pairing token. Sync is **read-only on the master** — only the standby is written.

**Repository:** https://github.com/supermaribo/cloudpanel-replication

---

## Quick start

| Step | Server | Command |
|------|--------|---------|
| 1 | Standby (new CloudPanel) | `git clone … && sudo ./bin/install.sh` → choose **Standby** |
| 2 | Master (live CloudPanel) | `git clone … && sudo ./bin/install.sh` → choose **Master** |
| 3 | Master | Verify with `clp-check all` and `clp-failover-check 30` |

Full walkthrough: **[Installation guide](docs/installation.md)**

---

## Documentation

| Guide | Description |
|-------|-------------|
| [Installation](docs/installation.md) | Install from scratch (standby first, then master) |
| [Architecture](docs/architecture.md) | How sync works, what runs where |
| [Compatibility checks](docs/compatibility-checks.md) | Preflight and cross-host validation |
| [Operations](docs/operations.md) | Daily commands, logs, manual sync |
| [Failover](docs/failover.md) | Cutover runbook when the master fails |
| [Uninstall](docs/uninstall.md) | Remove sync tooling without touching sites |

---

## What is mirrored

| Layer | Method |
|-------|--------|
| Site files (`/home/<user>/`) | rsync (includes `.ssh`, SSL under homes) |
| Linux / FTP / `clp` users | Password hashes, shells, groups |
| SSL / Let's Encrypt | nginx certs, ACME-related paths |
| Nginx + PHP-FPM pools | Config sync + reload |
| MySQL databases | Dump/import; skip unchanged dumps |
| Cron jobs | `/etc/cron.d/<siteUser>` |
| CloudPanel panel DB | Live `db.sq3` applied on standby |

**Not mirrored:** SSH host keys, Tailscale identity, public IP/hostname, root `authorized_keys` (except the sync key added at pair time).

**RPO:** up to ~15 minutes · **Failover:** manual DNS or floating IP

---

## Requirements

- Two Ubuntu servers with **CloudPanel** (same major version)
- Both on the **same Tailscale tailnet**
- Root SSH from master → standby over Tailscale
- Master packages: `rsync`, `sqlite3`, `mysqldump`, `openssl`, `python3`
- Standby: `clpctl`, nginx, MySQL/MariaDB, `openssh-server`

---

## Project layout

```
bin/
  install.sh           Interactive installer (both roles)
  uninstall.sh         Remove sync agent
  clp-sync             Main sync orchestrator (master only)
  clp-bootstrap        First full clone (master only)
  clp-check            Compatibility checks
  clp-failover-check   Pre-failover gate
  clp-pair-listen      Standby pairing listener
lib/                   Sync modules + checks
systemd/               Timer (15 min, master only)
config.example.env     Template (real config → /etc/clp-sync/config.env)
```

Installed to `/opt/clp-sync` on both servers. Only the **master** runs the sync timer.

---

## License

Use at your own risk. Test on non-production systems first.
