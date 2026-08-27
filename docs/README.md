# Documentation index

Complete guides for [CloudPanel Hot Standby Sync](../README.md).

---

## Getting started

| Guide | When to read |
|-------|----------------|
| [Quick start](quickstart.md) | Fast copy-paste install (5 min read) |
| [Installation](installation.md) | Full step-by-step from scratch |
| [Architecture](architecture.md) | How it works under the hood |

---

## Day-to-day

| Guide | When to read |
|-------|----------------|
| [Command reference](commands.md) | Every script and flag |
| [Operations](operations.md) | Logs, timer, manual sync |
| [Compatibility checks](compatibility-checks.md) | Preflight validation |

---

## Failover & maintenance

| Guide | When to read |
|-------|----------------|
| [Failover](failover.md) | Master lost → `clp-promote` |
| [Uninstall](uninstall.md) | Remove sync tooling |
| [Troubleshooting](troubleshooting.md) | Common errors |

---

## Install methods

### One-liner (recommended)

On **each** server (standby first, then master):

```bash
# Standby first
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=standby bash

# Master second
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=master bash
```

### Git clone

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./install-full.sh
# or: sudo ./bin/install.sh
```

---

## Script map

```
install-full.sh          ← start here (clone + interactive setup)
bin/install.sh           Interactive installer (both roles)
bin/uninstall.sh         Remove sync agent
bin/clp-sync             Scheduled / manual sync (master)
bin/clp-bootstrap        First full clone (master)
bin/clp-check            Compatibility checks
bin/clp-promote          Standby → master failover
bin/clp-set-standby      Add new standby after promotion
bin/clp-sync-control     Pause/resume sync
bin/clp-failover-check   Pre-cutover validation
bin/clp-pair-listen      Standby pairing listener
```
