# Failover runbook

When the master fails, promote the standby and switch traffic.

---

## Quick failover (master lost)

Run **on the standby**:

```bash
/opt/clp-sync/bin/clp-promote
```

Type `PROMOTE` when asked. This:

1. Verifies nginx, MySQL, and mirrored sites are ready
2. Sets `ROLE=master` and `PROMOTED=1`
3. **Blocks** inbound sync from the old master (removes sync SSH key)
4. **Disables** outbound sync until you add a new standby
5. Writes `/var/lib/clp-sync/promotion.json`

Then point DNS / floating IP at the standby.

---

## Step-by-step

### 1 — Promote standby (on the standby server)

```bash
# Optional: check mirror freshness first
/opt/clp-sync/bin/clp-failover-check 30   # only if master still has last-status

# Promote
/opt/clp-sync/bin/clp-promote

# Force (emergency, skip checks):
# /opt/clp-sync/bin/clp-promote --force
```

### 2 — Switch traffic

Point DNS A/AAAA (or floating IP) to the **standby's public IP**.

```bash
curl -I https://yourdomain.com
dig +short yourdomain.com
```

### 3 — Verify services

```bash
systemctl status nginx mysql
clpctl --version
```

Renew SSL if needed (DNS must point here):

```bash
clpctl lets-encrypt:install:certificate --domainName=example.com
```

### 4 — Old master

If the old master comes back:

- **Do not** re-enable `clp-sync.timer` pointing at the promoted server
- Run `./bin/uninstall.sh` on the old master, or leave it offline
- Rebuild it later as a **new standby**

---

## After promotion: new standby

When you have a rebuilt server:

**On the new standby:** `./bin/install.sh` → Standby → pair

**On the promoted master:**

```bash
/opt/clp-sync/bin/clp-set-standby
# Enter new standby Tailscale name after pairing
/opt/clp-sync/bin/clp-bootstrap
```

---

## Sync toggle (master)

Pause or resume replication without uninstalling:

```bash
/opt/clp-sync/bin/clp-sync-control off    # pause sync
/opt/clp-sync/bin/clp-sync-control on     # resume (needs STANDBY_HOST)
/opt/clp-sync/bin/clp-sync-control status
```

---

## Expected RPO / RTO

| Metric | Typical |
|--------|---------|
| **RPO** (max data loss) | Up to the replica timer interval (default 1h) |
| **RTO** (time to switch) | DNS TTL + `clp-promote` (~5–30 min) |

---

## Rollback

If failover was a mistake and the original master is still good:

1. Point DNS back to original master
2. On promoted server: `./bin/uninstall.sh` or re-run install as standby
3. Re-bootstrap from original master

**Warning:** Writes on the promoted server during failover may be lost when re-syncing from the original master.
