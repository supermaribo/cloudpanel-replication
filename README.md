# CloudPanel Hot Standby Sync

One-way **identical mirror** from a live CloudPanel **master** to a **hot standby** over **Tailscale**. Install on **both** servers with one command; they pair automatically. Sync is **read-only on the master**.

**Repository:** https://github.com/supermaribo/cloudpanel-replication

---

## Install in one command

**Standby first**, then **master**:

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo bash
```

| Server | Choose at prompt |
|--------|------------------|
| Standby (new CloudPanel) | `2` — save pairing token, leave listener running |
| Master (live CloudPanel) | `1` — enter standby host + token, bootstrap + timer |

Alternative:

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src && sudo ./install-full.sh
```

**Prerequisites:** Ubuntu, CloudPanel on both servers, Tailscale on same tailnet.

→ [Quick start](docs/quickstart.md) · [Full install guide](docs/installation.md)

---

## Documentation

| Guide | Description |
|-------|-------------|
| [Quick start](docs/quickstart.md) | Copy-paste install (5 min) |
| [Installation](docs/installation.md) | Complete step-by-step |
| [Command reference](docs/commands.md) | Every script and flag |
| [Architecture](docs/architecture.md) | How sync works |
| [Compatibility checks](docs/compatibility-checks.md) | Preflight validation |
| [Operations](docs/operations.md) | Logs, timer, daily use |
| [Failover](docs/failover.md) | `clp-promote` when master is lost |
| [Uninstall](docs/uninstall.md) | Remove sync tooling |
| [Troubleshooting](docs/troubleshooting.md) | Common fixes |
| [Docs index](docs/README.md) | All guides |

---

## What is mirrored

| Layer | Method |
|-------|--------|
| Site files (`/home/<user>/`) | rsync (`.ssh`, SSL, app data) |
| Linux / FTP / `clp` users | Password hashes, shells, groups |
| SSL / Let's Encrypt | nginx + ACME paths |
| Nginx + PHP-FPM pools | Config sync + reload |
| MySQL databases | Dump/import; skip unchanged |
| Cron jobs | `/etc/cron.d/<siteUser>` |
| CloudPanel panel DB | Live `db.sq3` on standby |

**Not mirrored:** SSH host keys, Tailscale identity, public IP/hostname.

**RPO:** ~15 min · **Failover:** `clp-promote` + DNS

---

## Common commands

```bash
# Verify (master)
/opt/clp-sync/bin/clp-check all
/opt/clp-sync/bin/clp-failover-check 30

# Manual sync (master)
/opt/clp-sync/bin/clp-sync

# Master lost — run on STANDBY
/opt/clp-sync/bin/clp-promote

# Pause sync (master)
/opt/clp-sync/bin/clp-sync-control off

# Uninstall
sudo /opt/clp-sync/bin/uninstall.sh
```

Full reference: [docs/commands.md](docs/commands.md)

---

## Project layout

```
install-full.sh          One-liner entry point (clone + install.sh)
bin/
  install.sh             Interactive installer (both roles)
  uninstall.sh           Remove sync agent
  clp-sync               Sync orchestrator (master, every 15 min)
  clp-bootstrap          First full clone
  clp-check              Compatibility checks
  clp-promote            Standby → master failover
  clp-set-standby        New standby after promotion
  clp-sync-control       Pause/resume sync
  clp-failover-check     Pre-cutover check
  clp-pair-listen        Standby pairing listener
docs/                    Full documentation
```

Installed to `/opt/clp-sync`. Config: `/etc/clp-sync/config.env`

---

## License

Use at your own risk. Test on non-production systems first.
