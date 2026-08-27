# Command reference

All scripts installed to `/opt/clp-sync/bin/` (or run from git clone at `./bin/`).

---

## Installation & removal

### `install-full.sh` (repo root)

Clone/update repo and start interactive installer.

```bash
# Standby first
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=standby bash

# Master second
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=master bash

# From clone
sudo CLP_SYNC_ROLE=standby ./install-full.sh
```

Environment overrides:

| Variable | Default |
|----------|---------|
| `CLP_SYNC_REPO` | `https://github.com/supermaribo/cloudpanel-replication.git` |
| `CLP_SYNC_INSTALL_DIR` | `/root/clp-sync-src` |
| `CLP_SYNC_BRANCH` | `main` |
| `CLP_SYNC_ROLE` | *(prompt 1 or 2)* — set `standby` or `master` |

---

### `install.sh`

Interactive installer — run on **both** master and standby.

```bash
sudo ./bin/install.sh
```

| Choice | Role |
|--------|------|
| `1` | Master — live CloudPanel, pushes mirror |
| `2` | Standby — receives mirror, run **first** |

Runs compatibility checks, pairs over Tailscale, optional bootstrap + timer.

---

### `uninstall.sh`

Remove sync agent only (keeps CloudPanel and sites).

```bash
sudo ./bin/uninstall.sh          # interactive
sudo ./bin/uninstall.sh -y       # no prompts
sudo ./bin/uninstall.sh --keep-key --keep-src
```

| Flag | Effect |
|------|--------|
| `-y` | Skip confirmations |
| `--keep-key` | Keep `/root/.ssh/clp_sync_ed25519` on master |
| `--keep-src` | Keep git clone directory |

---

## Sync (master only)

### `clp-sync`

Main replication run. Read-only on master.

```bash
/opt/clp-sync/bin/clp-sync
/opt/clp-sync/bin/clp-sync --connect-only
```

| Flag | Effect |
|------|--------|
| `--skip-bootstrap` | Don't create missing sites on standby |
| `--skip-files` | Skip file rsync |
| `--skip-mysql` | Skip database dump/import |
| `--skip-nginx` | Skip nginx/SSL/PHP-FPM/crons |
| `--skip-users` | Skip user password / FTP sync |
| `--skip-checks` | Skip preflight (emergency) |
| `--connect-only` | Test SSH only |

Runs automatically every **15 minutes** via `clp-sync.timer` on master.

---

### `clp-bootstrap`

First full clone — create sites/DBs on standby, then sync everything.

```bash
/opt/clp-sync/bin/clp-bootstrap
```

Runs full compatibility checks (must pass).

---

### `clp-sync-control`

Pause or resume scheduled sync.

```bash
/opt/clp-sync/bin/clp-sync-control status
/opt/clp-sync/bin/clp-sync-control off
/opt/clp-sync/bin/clp-sync-control on
```

---

## Checks

### `clp-check`

Compatibility and preflight validation.

```bash
/opt/clp-sync/bin/clp-check all              # master: local + standby
/opt/clp-sync/bin/clp-check local master
/opt/clp-sync/bin/clp-check local standby
/opt/clp-sync/bin/clp-check peer
/opt/clp-sync/bin/clp-check sync
```

---

### `clp-failover-check`

Pre-cutover validation (sync freshness + standby health).

```bash
/opt/clp-sync/bin/clp-failover-check 30   # max 30 min since last sync
```

---

## Failover

### `clp-promote`

**Run on standby** when master is lost. Promotes standby → master.

```bash
/opt/clp-sync/bin/clp-promote
/opt/clp-sync/bin/clp-promote -y
/opt/clp-sync/bin/clp-promote --force
/opt/clp-sync/bin/clp-promote --max-age 60
```

| Flag | Effect |
|------|--------|
| `-y` | Skip typed confirmation |
| `--force` | Skip readiness checks |
| `--max-age N` | Max acceptable snapshot age (minutes) |

Type `PROMOTE` to confirm (unless `-y`/`--force`).

After promotion:
- Blocks old master from syncing in
- Disables outbound sync until new standby configured
- Point DNS at this server

---

### `clp-set-standby`

**Run on master** (especially after promotion) to configure a new standby.

```bash
/opt/clp-sync/bin/clp-set-standby
/opt/clp-sync/bin/clp-set-standby standby-hostname
```

Pair new standby with `install.sh` first, then run bootstrap.

---

## Standby pairing

### `clp-pair-listen`

Accept master SSH key during initial setup (usually started by installer).

```bash
/opt/clp-sync/bin/clp-pair-listen --bind $(tailscale ip -4)
/opt/clp-sync/bin/clp-pair-listen --port 18765 --token YOUR_TOKEN
```

---

## Systemd (master)

```bash
systemctl enable --now clp-sync.timer
systemctl disable --now clp-sync.timer
systemctl list-timers clp-sync.timer
journalctl -u clp-sync.service -f
```

---

## Config files

| File | Purpose |
|------|---------|
| `/etc/clp-sync/config.env` | Main config (chmod 600) |
| `/etc/clp-sync/role` | `master` or `standby` |
| `/var/lib/clp-sync/last-status` | Last sync result |
| `/var/lib/clp-sync/promotion.json` | Written after `clp-promote` |

Key config keys:

```bash
ROLE=master|standby
STANDBY_HOST=tailscale-name-or-ip
SYNC_ENABLED=1|0
PROMOTED=0|1
STANDBY_SSH_KEY=/root/.ssh/clp_sync_ed25519
APPLY_PANEL_DB=1
```

---

## Typical workflows

### Fresh install

1. Standby: `install-full.sh` → role 2 → save token
2. Master: `install-full.sh` → role 1 → bootstrap + timer
3. Master: `clp-check all`

### Master failure

1. Standby: `clp-promote`
2. DNS → standby
3. Later: new standby + `clp-set-standby` + `clp-bootstrap`

### Maintenance pause

1. Master: `clp-sync-control off`
2. Work on master
3. Master: `clp-sync-control on`

### Full removal

1. Master: `uninstall.sh -y`
2. Standby: `uninstall.sh -y`
