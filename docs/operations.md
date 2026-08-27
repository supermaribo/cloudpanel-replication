# Operations

Day-to-day management of CloudPanel hot-standby sync.

---

## Installed paths

| Path | Description |
|------|-------------|
| `/opt/clp-sync/` | Sync toolkit |
| `/etc/clp-sync/config.env` | Configuration (chmod 600) |
| `/etc/clp-sync/role` | `master` or `standby` |
| `/var/lib/clp-sync/` | State, checksums, last-status |
| `/var/log/clp-sync/` | Logs |

---

## Common commands (master)

```bash
# Manual full sync
/opt/clp-sync/bin/clp-sync

# First-time or re-provision missing sites on standby
/opt/clp-sync/bin/clp-bootstrap

# Test SSH to standby only
/opt/clp-sync/bin/clp-sync --connect-only

# Full compatibility report
/opt/clp-sync/bin/clp-check all

# Pre-failover readiness (on master)
/opt/clp-sync/bin/clp-failover-check 30

# Pause / resume sync
/opt/clp-sync/bin/clp-sync-control off
/opt/clp-sync/bin/clp-sync-control on
/opt/clp-sync/bin/clp-sync-control status
```

## Failover commands (standby → master)

```bash
# On STANDBY when master is lost
/opt/clp-sync/bin/clp-promote

# After promotion — add a new standby
/opt/clp-sync/bin/clp-set-standby
/opt/clp-sync/bin/clp-bootstrap
```

See [Failover guide](failover.md).

---

## Sync timer

```bash
# Status
systemctl list-timers clp-sync.timer

# Enable
systemctl enable --now clp-sync.timer

# Disable (e.g. before maintenance)
systemctl disable --now clp-sync.timer

# Logs
journalctl -u clp-sync.service -f
journalctl -u clp-sync.service -n 100 --no-pager
```

Default interval: **every 15 minutes** after boot (5 min initial delay).

---

## Skip options (advanced)

```bash
/opt/clp-sync/bin/clp-sync --skip-bootstrap
/opt/clp-sync/bin/clp-sync --skip-files
/opt/clp-sync/bin/clp-sync --skip-mysql
/opt/clp-sync/bin/clp-sync --skip-nginx
/opt/clp-sync/bin/clp-sync --skip-users
/opt/clp-sync/bin/clp-sync --skip-checks
```

---

## Configuration

Edit `/etc/clp-sync/config.env`:

```bash
STANDBY_HOST=standby-tailscale-name
STANDBY_SSH_KEY=/root/.ssh/clp_sync_ed25519
APPLY_PANEL_DB=1
MYSQL_SKIP_UNCHANGED=1
FAIL_NOTIFY_CMD=    # optional webhook, e.g. curl to ntfy
```

After changes, no restart needed — next timer run picks up config.

---

## Excludes

Edit `/opt/clp-sync/excludes/rsync-excludes.txt` to skip caches, logs, etc.

**Note:** `.ssh/` is **included** (mirrored) so site SSH access matches master.

---

## Notifications on failure

Set in `config.env`:

```bash
FAIL_NOTIFY_CMD='curl -fsS -d "clp-sync failed on $(hostname)" https://ntfy.sh/your-topic'
```

---

## Rules of operation

1. **One-way only** — never edit live site content on the standby while it is the replica
2. **Master is source of truth** — all changes happen on master, sync propagates
3. **Don't run sync on standby** — `ROLE=standby` blocks `clp-sync`
4. **Keep CloudPanel versions matched** between master and standby

---

## Reversing roles

After failover, to sync in the opposite direction:

1. Uninstall clp-sync on both (or at least reconfigure roles)
2. Install on the **new** master pointing at the rebuilt standby
3. Bootstrap + enable timer

See [Failover](failover.md).
