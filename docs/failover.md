# Failover runbook

When the master fails or you need to switch traffic to the standby.

---

## Before you need it

- [ ] Lower DNS TTL to 5 minutes a few days ahead
- [ ] Know your standby's public IP
- [ ] Test failover in maintenance window: `clp-failover-check 30`
- [ ] Document which domains point to the master

---

## Step 1 — Assess

On a machine with access to the **master** config (or the master itself if still up):

```bash
/opt/clp-sync/bin/clp-failover-check 30
```

This checks:

- Last sync completed successfully
- Last sync younger than 30 minutes (adjust argument as needed)
- Standby SSH + nginx + MySQL up
- Site counts match

**Do not fail over if checks fail** unless you accept data loss since last sync.

---

## Step 2 — Freeze the master (if still reachable)

```bash
systemctl stop clp-sync.timer
```

Optional — stop writes at the app layer:

- Put sites in maintenance mode
- Stop nginx on master: `systemctl stop nginx`

---

## Step 3 — Switch traffic

Point DNS A/AAAA records (or floating IP) to the **standby's public IP**.

Wait for TTL to propagate. Test with:

```bash
curl -I https://yourdomain.com
dig +short yourdomain.com
```

Or temporarily override on your machine:

```bash
# /etc/hosts
STANDBY_PUBLIC_IP  yourdomain.com
```

---

## Step 4 — Verify on standby

- Sites load over HTTP/HTTPS
- CloudPanel admin login works (panel DB was mirrored)
- SSL certificates should already be present (synced from master)

If SSL issues:

```bash
clpctl lets-encrypt:install:certificate --domainName=example.com
```

**Important:** LE renewals must come from the server DNS now points to.

---

## Step 5 — Promote standby

1. **Stop treating it as replica** — do not run sync from old master to this box
2. **Disable sync on old master** if it comes back:
   ```bash
   systemctl disable --now clp-sync.timer
   ```
3. Operate the standby as your **new master**
4. Rebuild or repair the old server as a **new standby** when ready

---

## Step 6 — Re-establish replication (later)

When old master is rebuilt:

1. Fresh CloudPanel on old server
2. Install clp-sync on **both** with roles reversed
3. Bootstrap from new master → old server as standby

---

## Expected RPO / RTO

| Metric | Typical |
|--------|---------|
| **RPO** (max data loss) | Up to 15 minutes (last sync interval) |
| **RTO** (time to switch) | DNS TTL + verification (~5–30 min) |

For near-zero RPO, reduce timer interval in `systemd/clp-sync.timer` (e.g. `OnUnitActiveSec=5min`).

---

## Rollback

If failover was a mistake and master is still good:

1. Point DNS back to master
2. Re-enable sync timer on master
3. Run manual sync to refresh standby:
   ```bash
   /opt/clp-sync/bin/clp-sync
   ```

**Warning:** Any writes on standby during failover may be overwritten by next sync from master.
