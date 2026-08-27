# CloudPanel Hot Standby Sync

One-way **identical mirror** from a live CloudPanel **master** to a **standby** over **Tailscale**. Interactive installer on **both** machines; they pair with a one-time token. Sync is **read-only on the master** (only the standby is written).

---

## Install from scratch

### Before you start

| Requirement | Master | Standby |
|-------------|--------|---------|
| Ubuntu + CloudPanel (same major version) | Your live server | Fresh/empty install |
| Tailscale on same tailnet | Yes | Yes |
| Root SSH | Outbound to standby | Inbound from master |

---

### Step 1 — Prepare the standby (new server)

1. Install Ubuntu and **CloudPanel** (match the master’s CloudPanel version).
2. Confirm Tailscale is up: `tailscale status`
3. **Do not** create sites on the standby — the master will clone them.

---

### Step 2 — Install on the **standby first**

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./bin/install.sh
```

- Choose **2) Standby**
- Compatibility checks run on this server
- **Write down** the **Tailscale name/IP** and **pairing token**
- Say **Y** to start the pairing listener and **leave it running**

---

### Step 3 — Install on the **master** (live server)

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./bin/install.sh
```

- Choose **1) Master**
- Pick the standby from the Tailscale peer list (or type its name/IP)
- Enter the **pairing token** from step 2
- Installer pairs SSH, runs **cross-host compatibility checks**, then asks:
  - Run first full clone? → **Y**
  - Enable 15-minute sync timer? → **Y**

Master CloudPanel data is **read-only** — sites/DBs/users on the master are not modified.

---

### Step 4 — Verify

On the **master**:

```bash
/opt/clp-sync/bin/clp-check all
/opt/clp-sync/bin/clp-failover-check 30
journalctl -u clp-sync.service -n 50 --no-pager
systemctl list-timers clp-sync.timer
```

---

## What is mirrored

| Layer | How |
|-------|-----|
| Site files | rsync (includes SSH keys, SSL under homes) |
| Linux / FTP / `clp` users | password hashes, shells, groups |
| SSL / Let's Encrypt | nginx certs + related ACME paths |
| PHP-FPM pools, nginx, crons | mirrored |
| MySQL | dump/import; skip unchanged |
| CloudPanel panel DB | applied on standby |

**Not mirrored:** SSH host keys, Tailscale identity, public IP/hostname.

**RPO:** ~15 minutes. **Failover:** point DNS/IP at standby.

---

## Useful commands

```bash
# Manual sync (master)
/opt/clp-sync/bin/clp-sync

# Compatibility checks
/opt/clp-sync/bin/clp-check all
/opt/clp-sync/bin/clp-check sync

# Pre-failover
/opt/clp-sync/bin/clp-failover-check 30

# Logs
journalctl -u clp-sync.service -f
```

---

## Uninstall

Removes the sync agent only — **not** CloudPanel, sites, or databases.

### On the master

```bash
cd /root/clp-sync-src   # or wherever you cloned
sudo ./bin/uninstall.sh
```

### On the standby

```bash
cd /root/clp-sync-src
sudo ./bin/uninstall.sh
```

Non-interactive:

```bash
sudo ./bin/uninstall.sh -y
```

Options:

- `--keep-key` — keep `/root/.ssh/clp_sync_ed25519` on master
- `--keep-src` — keep the git clone directory

After uninstall on the **standby**, mirrored sites and data remain on disk — only the sync tooling is removed.
