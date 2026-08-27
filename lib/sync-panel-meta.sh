#!/usr/bin/env bash
# Apply CloudPanel SQLite so panel UI users, sites, FTP, SSL metadata match primary.

CLP_APP_ENV="${CLP_APP_ENV:-}"

_find_app_env_file() {
  local f
  if [[ -n "${CLP_APP_ENV}" && -f "${CLP_APP_ENV}" ]]; then
    echo "${CLP_APP_ENV}"
    return 0
  fi
  for f in \
    /home/clp/htdocs/app/.env \
    /home/clp/htdocs/app/.env.local \
    /home/clp/htdocs/app/.env.prod.local \
    /home/clp/.env
  do
    if [[ -f "${f}" ]] && grep -q '^APP_SECRET=' "${f}"; then
      echo "${f}"
      return 0
    fi
  done
  while IFS= read -r f; do
    if grep -q '^APP_SECRET=' "${f}"; then
      echo "${f}"
      return 0
    fi
  done < <(find /home/clp/htdocs/app -maxdepth 3 -name '.env*' -type f 2>/dev/null | head -20)
  return 1
}

# Standby must use the same APP_SECRET as master or copied panel passwords
# (admin login, encrypted DB users) will not decrypt.
sync_panel_app_secret() {
  local env_file secret
  env_file="$(_find_app_env_file || true)"
  if [[ -z "${env_file}" ]]; then
    log_warn "No APP_SECRET file found under /home/clp — admin login may need a password reset after failover"
    return 0
  fi
  secret="$(python3 - "${env_file}" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
m = re.search(r"^APP_SECRET=(.*)$", text, re.M)
if not m:
    sys.exit(0)
print(m.group(1).strip().strip("\"'"))
PY
)"
  if [[ -z "${secret}" ]]; then
    log_warn "No APP_SECRET in master ${env_file}"
    return 0
  fi
  remote bash -s -- "${env_file}" "${secret}" <<'EOS'
set -euo pipefail
written="$(python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
wanted = pathlib.Path(sys.argv[1])
secret = sys.argv[2]
candidates = [wanted] + [
    pathlib.Path(p) for p in (
        "/home/clp/htdocs/app/.env",
        "/home/clp/htdocs/app/.env.local",
        "/home/clp/htdocs/app/.env.prod.local",
        "/home/clp/.env",
    )
]
path = next((p for p in candidates if p.is_file()), None)
if path is None:
    sys.exit("standby .env missing")
text = path.read_text(errors="replace")
line = "APP_SECRET=" + secret
if re.search(r"^APP_SECRET=", text, re.M):
    text = re.sub(r"^APP_SECRET=.*$", lambda _m: line, text, count=1, flags=re.M)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += line + "\n"
path.write_text(text)
print(str(path))
PY
)"
chown clp:clp "${written}" 2>/dev/null || true
chmod 640 "${written}" 2>/dev/null || true
EOS
  log_ok "Standby CloudPanel APP_SECRET matches master (${env_file})"
}

_standby_panel_user_summary() {
  remote bash -s -- "${CLP_DB_PATH}" <<'EOS'
python3 - "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
table = "user" if "user" in tables else ("users" if "users" in tables else None)
if not table:
    print("0")
    sys.exit(0)
cols = {r[1] for r in con.execute(f'PRAGMA table_info("{table}")')}
name_col = "user_name" if "user_name" in cols else ("username" if "username" in cols else None)
role_col = "role" if "role" in cols else None
rows = list(con.execute(f'SELECT * FROM "{table}"'))
print(len(rows))
for row in rows:
    m = dict(zip([r[1] for r in con.execute(f'PRAGMA table_info("{table}")')], row))
    name = m.get(name_col) or m.get("email") or "?"
    role = m.get(role_col) or ""
    print(f"{name}\t{role}")
PY
EOS
}

sync_panel_meta() {
  local db_snap="$1"
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local remote_dir="/var/lib/clp-sync"
  local remote_copy="${remote_dir}/primary-db.sq3"
  local apply="${APPLY_PANEL_DB:-1}"
  local summary n

  log_info "Publishing CloudPanel SQLite snapshot to standby"
  remote "mkdir -p '${remote_dir}' && chmod 700 '${remote_dir}'"
  rsync -a -e "${rsync_ssh}" "${db_snap}" "$(standby_target):${remote_copy}"

  remote "cp -a '${remote_copy}' '${remote_dir}/primary-db-$(date -u +%Y%m%dT%H%M%SZ).sq3' &&
    ls -1t '${remote_dir}'/primary-db-*.sq3 2>/dev/null | tail -n +8 | xargs -r rm -f"

  if [[ "${apply}" != "1" ]]; then
    log_info "APPLY_PANEL_DB=0 — left live panel DB untouched"
    return 0
  fi

  log_info "Applying master CloudPanel DB on standby (admin users, sites, settings)"
  remote bash -s -- "${CLP_DB_PATH}" "${remote_copy}" <<'EOS'
set -euo pipefail
CLP_DB="$1"
SRC="$2"
install -d -m 755 -o clp -g clp "$(dirname "$CLP_DB")"
# Drop WAL/SHM first — replaying an old WAL onto a replaced db.sq3 corrupts it
# and can leave the user table empty (Admin User Creation wizard).
rm -f "${CLP_DB}-wal" "${CLP_DB}-shm" "${CLP_DB}.new"
cp -a "$SRC" "${CLP_DB}.new"
chown clp:clp "${CLP_DB}.new"
chmod 660 "${CLP_DB}.new"
mv -f "${CLP_DB}.new" "$CLP_DB"
rm -f "${CLP_DB}-wal" "${CLP_DB}-shm"
rm -rf /home/clp/htdocs/app/var/cache/* 2>/dev/null || true
for s in php*-fpm; do systemctl reload "$s" 2>/dev/null || true; done
true
EOS

  summary="$(_standby_panel_user_summary || true)"
  n="$(printf '%s\n' "${summary}" | head -1)"
  if [[ -z "${n}" || "${n}" == "0" ]]; then
    log_error "Standby panel user table is still empty — Admin User Creation will remain"
    return 1
  fi
  log_ok "Standby panel has ${n} user(s) — Admin User Creation should be gone"
  printf '%s\n' "${summary}" | tail -n +2 | while IFS=$'\t' read -r name role; do
    [[ -n "${name}" ]] && log_info "  panel user: ${name} ${role}"
  done
}

# Sync panel data files beyond sqlite (custom branding, etc.)
sync_panel_data_files() {
  local rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"
  local data_dir
  data_dir="$(dirname "${CLP_DB_PATH}")"

  if [[ ! -d "${data_dir}" ]]; then
    return 0
  fi

  log_info "Syncing CloudPanel data directory ${data_dir}"
  remote "install -d -m 755 -o clp -g clp '${data_dir}'"
  rsync -a -e "${rsync_ssh}" \
    --exclude 'db.sq3' \
    --exclude 'db.sq3-journal' \
    --exclude 'db.sq3-wal' \
    --exclude 'db.sq3-shm' \
    "${data_dir}/" \
    "$(standby_target):${data_dir}/"
  remote "chown -R clp:clp '${data_dir}'"
  log_ok "Panel data directory mirrored"
}

sync_panel_accounts() {
  log_info "Step 1b: CloudPanel accounts and settings"
  sync_panel_app_secret
  sync_panel_data_files
  sync_panel_meta "$1"
  disable_standby_backups
}

# Keep backup destinations/credentials in the panel DB and rclone configs.
# Only stop the jobs from running on the standby (master already backs up).
disable_standby_backups() {
  log_info "Disabling CloudPanel backup jobs on standby (credentials kept)"
  remote bash -s <<'EOS'
set -euo pipefail
python3 - <<'PY'
import pathlib, re

MARKER = "# clp-sync: backups disabled on standby — credentials/settings kept; re-enable on promote\n"
JOB_RE = re.compile(r"db:backup|remote-backup|\brclone\b", re.I)

def disable(path: pathlib.Path) -> bool:
    if not path.is_file():
        return False
    text = path.read_text(errors="replace")
    lines = text.splitlines(True)
    out = []
    if not any("clp-sync: backups disabled on standby" in ln for ln in lines):
        out.append(MARKER)
    changed = False
    for line in lines:
        raw = line.rstrip("\n")
        if "clp-sync: backups disabled on standby" in raw:
            continue
        stripped = raw.lstrip()
        if stripped.startswith("#") or not stripped:
            out.append(line if line.endswith("\n") else line + "\n")
            continue
        if JOB_RE.search(stripped):
            out.append("# clp-sync-disabled: " + stripped + "\n")
            changed = True
        else:
            out.append(line if line.endswith("\n") else line + "\n")
    new = "".join(out)
    if new != text:
        path.write_text(new)
        return True
    return changed

changed = False
for p in (
    pathlib.Path("/etc/cron.d/clp"),
    pathlib.Path("/etc/cron.d/clp-rclone"),
    pathlib.Path("/etc/cron.d/clp-remote-backup"),
):
    try:
        if disable(p):
            print("disabled jobs in", p)
            changed = True
    except OSError as e:
        print("skip", p, e)

# crontab of clp / clp-admin if they have backup lines
import os, subprocess, tempfile
for user in ("clp", "clp-admin"):
    try:
        current = subprocess.check_output(["crontab", "-u", user, "-l"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        continue
    lines = current.splitlines()
    new_lines = []
    job_changed = False
    for raw in lines:
        stripped = raw.lstrip()
        if stripped.startswith("#") or not stripped:
            new_lines.append(raw)
            continue
        if JOB_RE.search(stripped) and not raw.startswith("# clp-sync-disabled:"):
            new_lines.append("# clp-sync-disabled: " + stripped)
            job_changed = True
        else:
            new_lines.append(raw)
    if job_changed:
        body = "\n".join(new_lines) + "\n"
        if "clp-sync: backups disabled on standby" not in body:
            body = MARKER + body
        subprocess.run(["crontab", "-u", user, "-"], input=body, text=True, check=True)
        print("disabled backup crontab for", user)
        changed = True

if not changed:
    print("no active backup jobs to disable")
PY
EOS
  log_ok "Standby backup jobs disabled (S3/local credentials unchanged)"
}

enable_standby_backups() {
  log_info "Re-enabling CloudPanel backup jobs (promotion)"
  python3 - <<'PY'
import pathlib, re, subprocess
prefix = re.compile(r"^# clp-sync-disabled:\s*")
for p in (
    pathlib.Path("/etc/cron.d/clp"),
    pathlib.Path("/etc/cron.d/clp-rclone"),
    pathlib.Path("/etc/cron.d/clp-remote-backup"),
):
    if not p.is_file():
        continue
    lines = []
    for line in p.read_text(errors="replace").splitlines():
        if "clp-sync: backups disabled on standby" in line:
            continue
        lines.append(prefix.sub("", line))
    p.write_text("\n".join(lines) + ("\n" if lines else ""))
    print("restored", p)
for user in ("clp", "clp-admin"):
    try:
        current = subprocess.check_output(["crontab", "-u", user, "-l"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        continue
    lines = []
    for line in current.splitlines():
        if "clp-sync: backups disabled on standby" in line:
            continue
        lines.append(prefix.sub("", line))
    body = "\n".join(lines) + "\n"
    subprocess.run(["crontab", "-u", user, "-"], input=body, text=True, check=True)
    print("restored crontab for", user)
PY
}
