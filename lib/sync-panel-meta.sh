#!/usr/bin/env bash
# Apply CloudPanel SQLite so panel UI users, sites, FTP, SSL metadata match primary.

CLP_APP_ENV="${CLP_APP_ENV:-/home/clp/htdocs/app/.env}"

# Standby must use the same APP_SECRET as master or copied panel passwords
# (admin login, encrypted DB users) will not decrypt and the UI stays on
# "Admin User Creation" if the sqlite copy never lands.
sync_panel_app_secret() {
  local env_file="${CLP_APP_ENV}"
  local secret
  if [[ ! -f "${env_file}" ]]; then
    log_warn "Master ${env_file} missing — cannot align APP_SECRET"
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
python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
secret = sys.argv[2]
if not path.is_file():
    sys.exit("standby .env missing: " + str(path))
text = path.read_text(errors="replace")
line = "APP_SECRET=" + secret
if re.search(r"^APP_SECRET=", text, re.M):
    text = re.sub(r"^APP_SECRET=.*$", lambda _m: line, text, count=1, flags=re.M)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += line + "\n"
path.write_text(text)
PY
chown clp:clp "$1" 2>/dev/null || true
chmod 640 "$1" 2>/dev/null || true
EOS
  log_ok "Standby CloudPanel APP_SECRET matches master"
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
}
