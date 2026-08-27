# Installation guide

Complete install from scratch for a **live CloudPanel master** and a **new standby**, linked over Tailscale.

---

## Overview

```
  STANDBY (step 2)              MASTER (step 3)
  ─────────────────              ────────────────
  install-full.sh                install-full.sh
  choose: 2                        choose: 1
  pairing token ───────────────► enter token
  listener running               bootstrap + timer
                                 read-only on master
```

---

## Before you start

### Server roles

| | Master | Standby |
|---|--------|---------|
| **Purpose** | Live production CloudPanel | Empty mirror target |
| **CloudPanel** | In use with sites | Fresh install, **no sites** |
| **Sync timer** | Yes (15 min) | No |
| **Written to** | Sync logs/state only | Full mirror |

### Prerequisites

- [ ] Ubuntu 22.04 or 24.04 (recommended)
- [ ] CloudPanel on **both** (same major version)
- [ ] Tailscale on **both**, same tailnet
- [ ] Root access to both servers
- [ ] Standby `/home` disk ≥ master data + 10%

### Install CloudPanel & Tailscale (both servers)

**CloudPanel:**

```bash
# See official docs for your Ubuntu version:
# https://www.cloudpanel.io/docs/v2/getting-started/
```

**Tailscale:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
tailscale status
```

---

## Method A — One-liner (recommended)

### Step 1 — Standby **first**

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo bash
```

What `install-full.sh` does:

1. Checks root, Tailscale, CloudPanel
2. Installs `git` / `curl` if missing
3. Clones repo to `/root/clp-sync-src`
4. Runs interactive `bin/install.sh`

**Prompts:**

| Prompt | Answer |
|--------|--------|
| Role | `2` (Standby) |
| Compatibility checks | Automatic |
| Start pairing listener? | `Y` |

**Save:**

- Tailscale name / IP
- **Pairing token**
- Port (default `18765`)

Leave the terminal open while the listener runs.

---

### Step 2 — Master **second**

On your **live** CloudPanel server:

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo bash
```

**Prompts:**

| Prompt | Answer |
|--------|--------|
| Role | `1` (Master) |
| Standby host | Name/IP from step 1 (or peer number) |
| Pairing token | Paste from step 1 |
| Pairing port | Enter (default 18765) |
| Run bootstrap? | `Y` |
| Enable timer? | `Y` |

---

### Step 3 — Verify

On **master**:

```bash
/opt/clp-sync/bin/clp-check all
/opt/clp-sync/bin/clp-failover-check 30
systemctl list-timers clp-sync.timer
journalctl -u clp-sync.service -n 50 --no-pager
```

On **standby**: sites appear in CloudPanel UI; files under `/home/*/htdocs/`.

---

## Method B — Git clone

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./install-full.sh
```

Or run the interactive installer directly:

```bash
sudo ./bin/install.sh
```

Same prompts as Method A.

---

## What gets installed

| Path | Master | Standby |
|------|:------:|:-------:|
| `/opt/clp-sync/` | ✓ | ✓ |
| `/etc/clp-sync/config.env` | ✓ | ✓ |
| systemd `clp-sync.timer` | ✓ | — |
| `/root/.ssh/clp_sync_ed25519` | ✓ | — |

---

## Master is read-only

| Action | Modifies live sites? |
|--------|---------------------|
| Read files, DBs, configs | No (read only) |
| mysqldump | No (read only) |
| Write `/var/lib/clp-sync` | Sync state only |
| Write to standby | Yes (standby only) |

---

## After install

| Task | Command |
|------|---------|
| Manual sync | `clp-sync` |
| Check health | `clp-check all` |
| Pause sync | `clp-sync-control off` |
| Master lost | `clp-promote` (on standby) |
| Uninstall | `uninstall.sh` |

See [Command reference](commands.md) · [Failover](failover.md)

---

## Updating

```bash
cd /root/clp-sync-src
git pull
sudo ./install-full.sh   # updates /opt/clp-sync
```

Or copy only:

```bash
git pull
sudo rsync -a --exclude config.env ./ /opt/clp-sync/
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Tailscale not connected` | `tailscale up` |
| `CloudPanel not found` | Install CloudPanel first |
| Pairing fails | Standby listener running? Token correct? |
| SSH fails | `ssh -i /root/.ssh/clp_sync_ed25519 root@STANDBY` |
| PHP mismatch | Install PHP versions on standby (CloudPanel UI) |
| Disk too small | Expand standby volume |
| Checks fail | `clp-check all` for details |

→ [Troubleshooting guide](troubleshooting.md) · [Compatibility checks](compatibility-checks.md)

---

## Environment variables (`install-full.sh`)

```bash
CLP_SYNC_REPO=https://github.com/supermaribo/cloudpanel-replication.git
CLP_SYNC_INSTALL_DIR=/root/clp-sync-src
CLP_SYNC_BRANCH=main

curl -fsSL .../install-full.sh | sudo -E bash
```
