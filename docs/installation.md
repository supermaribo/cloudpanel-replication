# Installation guide

Install from scratch on a **live CloudPanel master** and a **new CloudPanel standby**, linked over Tailscale.

---

## Before you start

### Server roles

| | Master | Standby |
|---|--------|---------|
| **Purpose** | Your live production CloudPanel | Empty mirror target |
| **CloudPanel** | Already in use with sites | Fresh install, **no sites created** |
| **clp-sync timer** | Yes (runs every 15 min) | No |
| **Gets written to** | Only sync state/logs locally | Full mirror of master |

### Prerequisites checklist

- [ ] Ubuntu with CloudPanel on **both** servers (same major version)
- [ ] Tailscale installed and both nodes on the **same tailnet**
- [ ] You can reach both servers as `root` (or use `sudo`)
- [ ] Standby has enough disk on `/home` for all master site data (+ ~10% buffer)

---

## Step 1 — Prepare the standby

1. Install Ubuntu (22.04 or 24.04 recommended).
2. Install CloudPanel: https://www.cloudpanel.io/docs/v2/getting-started/
3. Install Tailscale and join your tailnet:

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   tailscale up
   tailscale status
   ```

4. **Do not** create sites in the CloudPanel UI on the standby — the master installer will provision them.

---

## Step 2 — Install on the standby **first**

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./bin/install.sh
```

### Prompts

1. **Role:** choose `2` (Standby)
2. **Compatibility checks** run automatically on this server
3. **Pairing token** is displayed — **write it down**
4. **Start pairing listener?** → **Y** (leave this terminal open)

You will see something like:

```
Tailscale name : cloudpanel-standby
Tailscale IP   : 100.x.x.x
Pairing token  : a1b2c3d4e5f6...
Pair port      : 18765
```

---

## Step 3 — Install on the master

On your **live** CloudPanel server:

```bash
git clone https://github.com/supermaribo/cloudpanel-replication.git /root/clp-sync-src
cd /root/clp-sync-src
sudo ./bin/install.sh
```

### Prompts

1. **Role:** choose `1` (Master)
2. **Standby host:** pick from the Tailscale peer list or type the standby name/IP
3. **Pairing token:** paste the token from step 2
4. **Pairing port:** press Enter for default `18765`
5. Installer pairs SSH, runs **cross-host compatibility checks**
6. **Run first full clone?** → **Y** (`clp-bootstrap`)
7. **Enable 15-minute timer?** → **Y**

### What the master installer does

| Action | Touches master sites? |
|--------|----------------------|
| Installs `/opt/clp-sync` | No |
| Generates SSH key for standby | No |
| Reads sites, DBs, files for sync | Read-only |
| Writes sync state under `/var/lib/clp-sync` | Sync tooling only |

Your live CloudPanel sites, databases, and nginx configs are **never modified** by sync.

---

## Step 4 — Verify

On the **master**:

```bash
/opt/clp-sync/bin/clp-check all
/opt/clp-sync/bin/clp-failover-check 30
systemctl list-timers clp-sync.timer
journalctl -u clp-sync.service -n 50 --no-pager
```

On the **standby**, confirm sites appear in CloudPanel and files exist under `/home/*/htdocs/`.

---

## Updating clp-sync

On either server after pulling new code:

```bash
cd /root/clp-sync-src
git pull
sudo ./bin/install.sh   # re-installs files to /opt/clp-sync
```

On the master, the timer picks up changes automatically. Re-run `./bin/install.sh` only if you need to reconfigure.

---

## Troubleshooting install

| Problem | Fix |
|---------|-----|
| Tailscale not connected | `tailscale up` on both servers |
| Pairing fails | Ensure standby listener is running; check token and port |
| SSH fails after pair | `ssh -i /root/.ssh/clp_sync_ed25519 root@STANDBY` from master |
| PHP version mismatch | Install missing PHP versions on standby via CloudPanel |
| Disk too small | Expand standby `/home` or reduce master data |
| Checks fail | Run `/opt/clp-sync/bin/clp-check all` for details |

See also: [Compatibility checks](compatibility-checks.md) · [Troubleshooting](troubleshooting.md)
