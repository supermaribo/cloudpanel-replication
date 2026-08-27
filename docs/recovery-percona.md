# Recovery: Percona removed by clp-sync installer

If the installer ran as **Master (1)** on a standby server, an older version may have run:

```bash
apt-get install default-mysql-client
```

That **removed** CloudPanel's `percona-server-server` and `percona-server-client`. This document explains recovery.

---

## Fastest fix (Proxmox LXC)

If this is an LXC container (e.g. `pct enter 100`), **restore from a Proxmox snapshot/backup** taken before running the installer. That is the safest option for an empty standby.

On the Proxmox host:

```bash
pct stop 100
pct rollback 100 <snapname>
# or restore from vzdump backup
pct start 100
```

---

## Manual fix on the server (lottie / standby)

### 1. Stop clp-sync and do not re-run install as Master

```bash
systemctl stop clp-sync.timer clp-sync.service 2>/dev/null || true
```

### 2. Remove wrong MariaDB client packages (optional, if reinstall fails)

```bash
apt-get remove -y default-mysql-client mariadb-client mariadb-client-core 2>/dev/null || true
```

### 3. Reinstall CloudPanel Percona packages

CloudPanel on Debian bookworm uses Percona from the CloudPanel repo:

```bash
apt-get update
apt-get install -y percona-server-common percona-server-client percona-server-server
dpkg --configure -a
apt-get install -f -y
```

### 4. Fix broken CloudPanel package

If you see:

```
cp: cannot stat '/tmp/cloudpanel/data/clp/services/nginx/systemd/clp-nginx.service'
```

Try:

```bash
apt-get install --reinstall cloudpanel
dpkg --configure -a
```

If still broken, CloudPanel support or re-run their official installer on a **fresh** container may be required.

### 5. Start MySQL

```bash
systemctl start mysql
systemctl status mysql
```

### 6. Verify CloudPanel

```bash
clpctl --version
systemctl status nginx cloudpanel-nginx clp-nginx 2>/dev/null || systemctl status nginx
```

---

## After recovery — install clp-sync CORRECTLY on standby

**Only after MySQL is running again:**

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo CLP_SYNC_ROLE=standby bash
```

---

## What went wrong

| Mistake | Result |
|---------|--------|
| Chose **1 (Master)** on empty standby | Ran master installer path |
| Old `apt-get install default-mysql-client` | Removed **Percona** |
| CloudPanel already broken (`dpkg`) | Each apt trigger made it worse |

Current GitHub version **never** installs mysql/mariadb packages. Always use `CLP_SYNC_SKIP_APT=1`.

---

## If recovery fails

For an **empty standby**, rebuilding the LXC container and reinstalling CloudPanel from scratch is often faster than fighting a broken `dpkg` state. Then run clp-sync install with role **2** only.
