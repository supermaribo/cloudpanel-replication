# Quick start

Five-minute install guide. **Standby first, then master.**

---

## Prerequisites

- Two Ubuntu servers with **CloudPanel** (same version)
- **Tailscale** on both, same tailnet
- Master = live sites · Standby = empty CloudPanel

---

## 1 — Standby (new server)

SSH into the **standby** and run:

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo bash
```

| Prompt | Answer |
|--------|--------|
| Role | `2` (Standby) |
| Start pairing listener? | `Y` |

**Save the pairing token** and leave the terminal open.

---

## 2 — Master (live server)

SSH into the **master** and run:

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh | sudo bash
```

| Prompt | Answer |
|--------|--------|
| Role | `1` (Master) |
| Standby host | Tailscale name or IP from step 1 |
| Pairing token | Paste from step 1 |
| Run bootstrap? | `Y` |
| Enable 15-min timer? | `Y` |

---

## 3 — Verify (master)

```bash
/opt/clp-sync/bin/clp-check all
/opt/clp-sync/bin/clp-failover-check 30
journalctl -u clp-sync.service -n 20 --no-pager
```

---

## Master lost?

On the **standby**:

```bash
/opt/clp-sync/bin/clp-promote
```

Then point DNS at the standby. Details: [Failover](failover.md).

---

## Pause sync

On the **master**:

```bash
/opt/clp-sync/bin/clp-sync-control off
/opt/clp-sync/bin/clp-sync-control on
```

---

## Remove

```bash
curl -fsSL https://raw.githubusercontent.com/supermaribo/cloudpanel-replication/main/install-full.sh -o /tmp/clp-install.sh
# or if already cloned:
cd /root/clp-sync-src && sudo ./bin/uninstall.sh
```

See [Uninstall](uninstall.md).

---

## Next

- [Full installation guide](installation.md)
- [All commands](commands.md)
- [Troubleshooting](troubleshooting.md)
