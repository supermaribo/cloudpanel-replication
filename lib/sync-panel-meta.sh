#!/usr/bin/env bash
# Apply CloudPanel SQLite so panel UI users, sites, FTP, SSL metadata match primary.

CLP_APP_ENV="${CLP_APP_ENV:-}"

# Print "source_path<TAB>secret". Never log the secret.
_harvest_app_secret() {
  CLP_APP_ENV="${CLP_APP_ENV:-}" python3 - <<'PY'
import os, pathlib, re, sys

def from_env_text(text):
    m = re.search(r"(?m)^APP_SECRET=(.*)$", text)
    return m.group(1).strip().strip("\"'") if m else ""

def from_php_return(text):
    m = re.search(r"['\"]APP_SECRET['\"]\s*=>\s*['\"]([^'\"]+)['\"]", text)
    return m.group(1) if m else ""

def from_fpm(text):
    m = re.search(r"(?m)^\s*env\[APP_SECRET\]\s*=\s*(.*)$", text)
    return m.group(1).strip().strip("\"'") if m else ""

candidates = []
if os.environ.get("CLP_APP_ENV"):
    candidates.append(pathlib.Path(os.environ["CLP_APP_ENV"]))
for p in (
    "/home/clp/htdocs/app/.env",
    "/home/clp/htdocs/app/.env.local",
    "/home/clp/htdocs/app/.env.prod.local",
    "/home/clp/htdocs/app/.env.local.php",
    "/home/clp/htdocs/app/files/.env",
    "/home/clp/htdocs/app/files/.env.local",
    "/home/clp/htdocs/app/files/.env.local.php",
    "/home/clp/.env",
):
    candidates.append(pathlib.Path(p))
root = pathlib.Path("/home/clp/htdocs/app")
if root.is_dir():
    candidates.extend(p for p in root.glob("**/.env*") if p.is_file())
php = pathlib.Path("/etc/php")
if php.is_dir():
    candidates.extend(php.glob("*/fpm/pool.d/*.conf"))

seen = set()
for path in candidates:
    try:
        path = path.resolve()
    except OSError:
        continue
    if path in seen or not path.is_file():
        continue
    seen.add(path)
    try:
        text = path.read_text(errors="replace")
    except OSError:
        continue
    secret = from_env_text(text) or from_php_return(text) or from_fpm(text)
    if secret:
        print(f"{path}\t{secret}")
        sys.exit(0)
sys.exit(1)
PY
}

_apply_app_secret_standby() {
  remote bash -s -- "$1" <<'EOS'
set -euo pipefail
python3 - "$1" <<'PY'
import os, pathlib, pwd, re, sys
secret = sys.argv[1]
line = "APP_SECRET=" + secret
written = []

def write_env(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        text = path.read_text(errors="replace")
        if re.search(r"^APP_SECRET=", text, re.M):
            text = re.sub(r"^APP_SECRET=.*$", lambda _m: line, text, count=1, flags=re.M)
        else:
            if text and not text.endswith("\n"):
                text += "\n"
            text += line + "\n"
        path.write_text(text)
    else:
        path.write_text("APP_ENV=prod\n" + line + "\n")
    try:
        clp = pwd.getpwnam("clp")
        os.chown(path, clp.pw_uid, clp.pw_gid)
        os.chmod(path, 0o640)
    except Exception:
        pass
    written.append(str(path))

for path in (
    pathlib.Path("/home/clp/htdocs/app/.env"),
    pathlib.Path("/home/clp/htdocs/app/files/.env"),
):
    write_env(path)

app = pathlib.Path("/home/clp/htdocs/app")
if app.is_dir():
    for path in app.glob("**/.env*"):
        if not path.is_file():
            continue
        if path.suffix == ".php" or path.name.endswith(".php"):
            text = path.read_text(errors="replace")
            if re.search(r"['\"]APP_SECRET['\"]\s*=>", text):
                text = re.sub(
                    r"(['\"]APP_SECRET['\"]\s*=>\s*['\"])[^'\"]*(['\"])",
                    lambda m: m.group(1) + secret + m.group(2),
                    text,
                    count=1,
                )
                path.write_text(text)
                written.append(str(path))
            continue
        if str(path) in written:
            continue
        write_env(path)

php = pathlib.Path("/etc/php")
if php.is_dir():
    for path in php.glob("*/fpm/pool.d/*.conf"):
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        if "APP_SECRET" not in text:
            continue
        new = re.sub(r"(?m)^(\s*env\[APP_SECRET\]\s*=\s*).*$", r"\1" + secret, text)
        if new != text:
            path.write_text(new)
            written.append(str(path))

print(" ".join(sorted(set(written))))
PY
EOS
}

_repair_standby_panel_runtime() {
  log_info "Clearing CloudPanel cache and reloading PHP-FPM on standby"
  remote bash -s <<'EOS'
set +e
rm -rf /home/clp/htdocs/app/var/cache/* 2>/dev/null
mkdir -p /home/clp/htdocs/app/var/cache /home/clp/htdocs/app/var/log
chown -R clp:clp /home/clp/htdocs/app/var /home/clp/htdocs/app/data /home/clp/htdocs/app/.env /home/clp/htdocs/app/files/.env 2>/dev/null
chmod 660 /home/clp/htdocs/app/data/db.sq3 2>/dev/null
for s in php*-fpm; do
  systemctl reload "$s" 2>/dev/null || systemctl restart "$s" 2>/dev/null
done
echo "==== panel error log ===="
ls -lt /home/clp/htdocs/app/var/log 2>/dev/null | head -10
tail -n 40 /home/clp/htdocs/app/var/log/prod.log 2>/dev/null
tail -n 20 /home/clp/logs/nginx/error.log 2>/dev/null
true
EOS
}

# Standby must use the same APP_SECRET as master or the copied panel sqlite
# (encrypted passwords/settings) throws a Symfony 500.
sync_panel_app_secret() {
  local harvested source_path secret rsync_ssh
  rsync_ssh="$(rsync_ssh_cmd)"

  log_info "Aligning CloudPanel APP_SECRET on standby with master"
  remote "mkdir -p /home/clp/htdocs/app /home/clp/htdocs/app/files"
  for f in \
    /home/clp/htdocs/app/.env \
    /home/clp/htdocs/app/.env.local \
    /home/clp/htdocs/app/.env.local.php \
    /home/clp/htdocs/app/.env.prod.local \
    /home/clp/htdocs/app/files/.env \
    /home/clp/htdocs/app/files/.env.local \
    /home/clp/htdocs/app/files/.env.local.php
  do
    if [[ -f "${f}" ]]; then
      rsync -a -e "${rsync_ssh}" "${f}" "$(standby_target):${f}"
      log_info "Copied ${f} to standby"
    fi
  done

  harvested="$(_harvest_app_secret 2>/dev/null || true)"
  if [[ -z "${harvested}" ]]; then
    log_error "Could not find APP_SECRET on master (checked .env, files/.env, php-fpm pools)"
    return 1
  fi
  source_path="${harvested%%$'\t'*}"
  secret="${harvested#*$'\t'}"
  if [[ -z "${secret}" ]]; then
    log_error "APP_SECRET harvest was empty"
    return 1
  fi
  log_info "APP_SECRET found in ${source_path}"
  _apply_app_secret_standby "${secret}" >/dev/null
  log_ok "Standby APP_SECRET matches master"
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
  _repair_standby_panel_runtime
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
