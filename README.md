# CloudPanel pull mirror

One-way **pull** from a live CloudPanel **master** to a **standby** over **Tailscale**. The standby does the work. The master only allows a **restricted SSH key** (rsync read + mysqldump stdout). No timer and no dump files on the live box.

**Repository:** https://github.com/supermaribo/cloudpanel-replication

---

## Install

**Master first** (restricted SSH wrapper only), then **standby** (puller).

```bash
# Master (live CloudPanel)
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=master bash

# Standby (mirror) — prints a public key
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=standby bash
```

On the **master**, authorize the standby key:

```bash
sudo /opt/clp-sync/bin/clp-allow-pull 'ssh-ed25519 AAAA… clp-sync-standby'
```

On the **standby**:

```bash
sudo /opt/clp-sync/bin/clp-sync --connect-only
sudo /opt/clp-sync/bin/clp-sync --manual
# later: sudo /opt/clp-sync/bin/clp-sync-control on
```

**Uninstall** (does not touch CloudPanel or sites):

```bash
sudo /opt/clp-sync/bin/uninstall.sh -y
```

If prompts still fail, download then run (uses a real terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh -o /tmp/clp-install.sh
sudo bash /tmp/clp-install.sh
```

| Server | Role |
|--------|------|
| Master (live) | Restricted SSH key only — `clp-allow-pull`. No timer. |
| Standby (replica) | Pulls files + site MySQL; timer + CloudPanel **Sync now** |

Update an existing install from the replica (does not replace `/etc/clp-sync/config.env`):

```bash
# On live, pull toolkit from the replica
sudo rsync -a --exclude config.env --exclude '.git/' \
  root@<replica-tailscale>:/opt/clp-sync/ /opt/clp-sync/
sudo chmod 755 /opt/clp-sync/bin/*
```

Alternative (git clone):

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src && sudo CLP_SYNC_ROLE=standby ./install-full.sh
```

**Prerequisites:** Debian 12 or Ubuntu, CloudPanel on both servers, Tailscale on the same tailnet.

→ [Quick start](docs/quickstart.md) · [Full install guide](docs/installation.md)

---

## Documentation

| Guide | Description |
|-------|-------------|
| [Quick start](docs/quickstart.md) | Copy-paste install |
| [Installation](docs/installation.md) | Complete step-by-step |
| [Command reference](docs/commands.md) | Every script and flag |
| [Architecture](docs/architecture.md) | How sync works |
| [Master read-only policy](docs/master-readonly.md) | **No CloudPanel changes on master** |
| [Compatibility checks](docs/compatibility-checks.md) | Preflight validation |
| [Operations](docs/operations.md) | Logs, timer, PHP-FPM tune, daily use |
| [Failover](docs/failover.md) | Make live / `clp-promote` when master is lost |
| [Uninstall](docs/uninstall.md) | Remove sync tooling |
| [Troubleshooting](docs/troubleshooting.md) | Common fixes |
| [Docs index](docs/README.md) | All guides |

---

## What is mirrored

| Layer | Method |
|-------|--------|
| Site files (`/home/<user>/`) | rsync (logs/`tmp` skipped; Laravel `bootstrap/cache` kept) |
| Linux / FTP / `clp` users | Password hashes, shells, groups |
| SSL / Let's Encrypt | nginx + ACME paths |
| Nginx + PHP-FPM pools | Config sync + reload (only PHP versions sites use) |
| MySQL databases | Dump over Tailscale as the site user; import on replica; skip unchanged |
| Cron jobs | `/etc/cron.d` + site user crontabs |
| CloudPanel panel DB | Live `db.sq3` snapshot on standby |

**Not mirrored:** SSH host keys, Tailscale identity, public IP/hostname.

**RPO:** replica timer (default **1h**; CloudPanel UI 1h–24h or off) · **Failover:** Make live / `clp-promote` + DNS

---

## Common commands

Run **on the replica** unless noted:

```bash
# Probe master SSH
sudo /opt/clp-sync/bin/clp-sync --connect-only

# Sync now (same as the CloudPanel “Sync now” button)
sudo /opt/clp-sync/bin/clp-sync --manual

# RAM / PHP-FPM snapshot (safe on live or replica; no writes)
sudo /opt/clp-sync/bin/clp-sync --resources

# Timer
sudo /opt/clp-sync/bin/clp-sync-control status
sudo /opt/clp-sync/bin/clp-sync-control on
sudo /opt/clp-sync/bin/clp-sync-control interval 12h

# PHP-FPM / OPcache caps — manual only, never part of sync. Apply on LIVE.
sudo /opt/clp-sync/bin/clp-tune
sudo /opt/clp-sync/bin/clp-tune --apply

# Make this replica live (after DNS)
sudo /opt/clp-sync/bin/clp-promote
```

Full reference: [docs/commands.md](docs/commands.md)

---

## Project layout

```
install-full.sh          One-liner entry point (clone + install.sh)
bin/
  install.sh             Interactive installer (both roles)
  uninstall.sh           Remove sync agent
  clp-sync               Replica pull (timer + Sync now)
  clp-tune               Manual PHP-FPM / OPcache caps (live)
  clp-sync-ui            CloudPanel badge helper (frequency / now / live)
  clp-master-read-only   Forced SSH command on live
  clp-allow-pull         Authorize the replica key on live
  clp-promote            Replica → live
  clp-sync-control       Pause/resume / interval
  clp-role / clp-pair-peer
docs/                    Full documentation
```

Installed to `/opt/clp-sync`. Config: `/etc/clp-sync/config.env`

---

## License

Use at your own risk. Test on non-production systems first.
