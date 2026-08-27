# Uninstall

Remove clp-sync from a server **without** removing CloudPanel, sites, databases, or nginx.

---

## What gets removed

| Removed | Kept |
|---------|------|
| `/opt/clp-sync/` | CloudPanel |
| `/etc/clp-sync/` | All site files under `/home/` |
| `/var/lib/clp-sync/` | MySQL databases |
| `/var/log/clp-sync/` | nginx configs |
| `/var/tmp/clp-sync/` | SSL certificates |
| systemd timer + service | Mirrored data on standby |

---

## Interactive uninstall

On **master** or **standby**:

```bash
cd /root/clp-sync-src    # or your clone path
sudo ./bin/uninstall.sh
```

Prompts:

- Confirm uninstall
- Remove sync SSH key on master? (optional)
- Remove git clone directory? (optional)
- On standby: removes `clp-sync-master` from `authorized_keys`

---

## Non-interactive

```bash
sudo ./bin/uninstall.sh -y
```

---

## Options

| Flag | Effect |
|------|--------|
| `-y`, `--yes` | Skip all confirmations |
| `--keep-key` | Keep `/root/.ssh/clp_sync_ed25519` on master |
| `--keep-src` | Keep the git clone directory |

---

## Uninstall both servers

**Recommended order:**

1. **Master first** — stops sync timer so nothing writes to standby
   ```bash
   sudo ./bin/uninstall.sh -y
   ```

2. **Standby second**
   ```bash
   sudo ./bin/uninstall.sh -y
   ```

---

## Manual cleanup (if script fails)

```bash
systemctl disable --now clp-sync.timer clp-sync.service
rm -f /etc/systemd/system/clp-sync.service /etc/systemd/system/clp-sync.timer
systemctl daemon-reload
rm -rf /opt/clp-sync /etc/clp-sync /var/lib/clp-sync /var/log/clp-sync /var/tmp/clp-sync
```

On standby, edit `/root/.ssh/authorized_keys` and remove the line containing `clp-sync-master`.

---

## Re-install later

Follow the [Installation guide](installation.md) from scratch. Previous mirror data on standby may cause conflicts — prefer a clean standby CloudPanel install for a fresh clone.
