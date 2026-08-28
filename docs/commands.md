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

## Sync (replica)

### `clp-sync`

Replica pull from live. Live only allows the restricted SSH key.

```bash
sudo /opt/clp-sync/bin/clp-sync --manual
sudo /opt/clp-sync/bin/clp-sync --connect-only
sudo /opt/clp-sync/bin/clp-sync --resources
```

`--resources` is read-only (RAM, running PHP-FPM, pool `pm.max_children`, InnoDB buffer pool). It works on **live or replica** and does not start a pull.

| Flag | Effect |
|------|--------|
| `--skip-files` | Skip file rsync |
| `--skip-mysql` | Skip database dump/import |
| `--skip-nginx` | Skip nginx/SSL/PHP-FPM/crons |
| `--connect-only` | Probe master SSH, then exit |
| `--resources` | Read-only RAM / PHP-FPM / MySQL snapshot (live or replica) |
| `--manual` | Run even if the timer is off (Sync now) |

Timer: `clp-sync.timer` on the **replica** (default 1h). CloudPanel **Sync now** runs `clp-sync --manual`. Does **not** run `clp-tune`.

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

### `clp-tune`

Apply agreed PHP-FPM / OPcache values (`ondemand`, `max_children=100`, idle 5s, OPcache 256 / JIT 32M / 100000 files). Stops unused `php*-fpm`. **Does not change MySQL.** **Manual only** — scheduled/manual `clp-sync` never runs this. Dry-run by default; pull the toolkit from the replica, run `--apply` on **live**, then Sync now on the replica.

```bash
sudo rsync -a --exclude config.env --exclude '.git/' \
  root@<replica-tailscale>:/opt/clp-sync/ /opt/clp-sync/
sudo chmod 755 /opt/clp-sync/bin/*
sudo /opt/clp-sync/bin/clp-tune
sudo /opt/clp-sync/bin/clp-tune --apply
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

### `clp-sync-ui`

Privileged helper for the replica CloudPanel badge (`share/clp-sync.php`). Not run by hand unless debugging.

```bash
sudo /opt/clp-sync/bin/clp-sync-ui <token> now
sudo /opt/clp-sync/bin/clp-sync-ui <token> frequency 12h
sudo /opt/clp-sync/bin/clp-sync-ui <token> live LIVE
```

---

### `clp-allow-pull`

**On live.** Authorize the replica’s SSH public key with `command=/opt/clp-sync/bin/clp-master-read-only`.

```bash
sudo /opt/clp-sync/bin/clp-allow-pull 'ssh-ed25519 AAAA… clp-sync-standby'
```

---

### `clp-master-read-only`

Forced SSH command on live. Not invoked directly. Allows rsync send, panel sqlite snapshot, site mysqldump, service list. Refuses shell and rsync receive.

---

### `clp-role` / `clp-pair-peer`

Role swap helpers used by Make live and pairing.

```bash
sudo /opt/clp-sync/bin/clp-pair-peer <peer-tailscale-host>
```

---

## Standby pairing

### `clp-pair-listen`

Accept master SSH key during initial setup (usually started by installer).

```bash
/opt/clp-sync/bin/clp-pair-listen --bind $(tailscale ip -4)
/opt/clp-sync/bin/clp-pair-listen --port 18765 --token YOUR_TOKEN
```

---

## Systemd (replica)

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
MASTER_HOST=live-tailscale-name
PEER_HOST=other-host
SYNC_ENABLED=1|0
SYNC_INTERVAL=1h
PROMOTED=0|1
MASTER_SSH_KEY=/root/.ssh/clp_sync_ed25519
APPLY_PANEL_DB=1
MYSQL_SKIP_UNCHANGED=1
```

---

## Typical workflows

### Fresh install

1. Master: `install-full.sh` → role master → `clp-allow-pull`
2. Standby: `install-full.sh` → role standby → `clp-sync --manual`
3. Replica: `clp-sync-control on` (timer)

### Master failure

1. Point DNS at the replica
2. Replica: Make live / `clp-promote`
3. Pair so the old live becomes the new replica

### Maintenance pause

1. Replica: `clp-sync-control off`
2. Work on live
3. Replica: `clp-sync-control on`

### Full removal

1. Master: `uninstall.sh -y`
2. Standby: `uninstall.sh -y`
