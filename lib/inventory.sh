#!/usr/bin/env bash
# Inventory helpers — read CloudPanel SQLite (safe .backup snapshot).

# Snapshot live CLP DB to a consistent file under CLP_SYNC_TMP_DIR.
inventory_snapshot() {
  local dest="${CLP_SYNC_TMP_DIR}/db.sq3"
  require_cmds sqlite3
  [[ -f "${CLP_DB_PATH}" ]] || die "CloudPanel DB not found: ${CLP_DB_PATH}"

  rm -f "${dest}"
  sqlite3 "${CLP_DB_PATH}" ".backup '${dest}'"
  chmod 600 "${dest}"
  echo "${dest}"
}

# Print tab-separated sites (never pipe-separated: vhost blobs contain newlines).
# id, domain_name, user, type, php_version, vhost_template
inventory_sites() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  python3 - "${db}" <<'PY'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.row_factory = sqlite3.Row

def cols(table):
    return {r[1] for r in con.execute(f"PRAGMA table_info({table})")}

sc = cols("site")
php_table = "php_settings" if "php_settings" in {
    r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")
} else None

def pick(row, *names, default=""):
    for n in names:
        if n in row.keys() and row[n] is not None:
            return str(row[n]).replace("\r", "").replace("\n", " ").replace("\t", " ")
    return default

type_map = {
    "php": "php", "wordpress": "php", "woocommerce": "php",
    "nodejs": "nodejs", "node": "nodejs", "node.js": "nodejs",
    "python": "python",
    "static": "static", "html": "static",
    "reverse-proxy": "reverse-proxy", "reverse_proxy": "reverse-proxy",
    "reverseproxy": "reverse-proxy",
}

php_by_site = {}
if php_table:
    try:
        for r in con.execute("SELECT site_id, php_version FROM php_settings"):
            if r[0] is not None and r[0] not in php_by_site:
                php_by_site[r[0]] = r[1] or ""
    except sqlite3.Error:
        pass

for row in con.execute("SELECT * FROM site ORDER BY id"):
    sid = row["id"]
    domain = pick(row, "domain_name", "domain")
    user = pick(row, "user", "site_user", "username")
    raw_type = pick(row, "type", "site_type").strip().lower()
    site_type = type_map.get(raw_type, "php")
    php_ver = str(php_by_site.get(sid, "") or "8.3")
    # Never emit stored nginx; rsync copies real vhosts.
    print("\t".join([str(sid), domain, user, site_type, php_ver, "Generic"]))
PY
}

# ftp_user|home_directory|site_user
inventory_ftp_users() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  sqlite3 -separator '|' "${db}" "
SELECT
  f.user_name,
  COALESCE(f.home_directory, ''),
  COALESCE(s.user, '')
FROM ftp_user f
LEFT JOIN site s ON s.id = f.site_id
ORDER BY f.user_name;
" 2>/dev/null || true
}

inventory_ftp_usernames() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  sqlite3 "${db}" "SELECT DISTINCT user_name FROM ftp_user WHERE user_name IS NOT NULL AND user_name != '';" 2>/dev/null || true
}

inventory_databases() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  python3 - "${db}" <<'PY'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
db_table = "database" if "database" in tables else ("databases" if "databases" in tables else None)
if not db_table:
    sys.exit(0)
q = f'''
SELECT s.id, s.domain_name, s.user, d.name, COALESCE(du.user_name, '')
FROM site s
JOIN "{db_table}" d ON d.site_id = s.id
LEFT JOIN database_user du ON du.database_id = d.id
ORDER BY d.name
'''
try:
    for row in con.execute(q):
        vals = [("" if x is None else str(x).replace("\t"," ").replace("\n"," ")) for x in row]
        print("\t".join(vals))
except sqlite3.Error:
    # database_user table may be named differently
    q2 = f'''
    SELECT s.id, s.domain_name, s.user, d.name, d.name
    FROM site s
    JOIN "{db_table}" d ON d.site_id = s.id
    ORDER BY d.name
    '''
    for row in con.execute(q2):
        vals = [("" if x is None else str(x).replace("\t"," ").replace("\n"," ")) for x in row]
        print("\t".join(vals))
PY
}

# Print pipe-separated cron rows:
# site_user|minute|hour|day|month|weekday|command
inventory_crons() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  sqlite3 -separator '|' "${db}" "
SELECT
  s.user,
  c.minute,
  c.hour,
  c.day,
  c.month,
  c.weekday,
  c.command
FROM cron_job c
JOIN site s ON s.id = c.site_id
ORDER BY s.user, c.id;
"
}

# Unique site users (one home dir each)
inventory_site_users() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  sqlite3 "${db}" "SELECT DISTINCT user FROM site WHERE user IS NOT NULL AND user != '' ORDER BY user;"
}

# Best-effort extract DB password from common app configs on primary.
# Args: site_user domain db_name
guess_db_password() {
  local site_user="$1" domain="$2" db_name="$3"
  local root="/home/${site_user}/htdocs/${domain}"
  local f pass
  local search_root="/home/${site_user}/htdocs"

  local env_files=()
  [[ -d "${root}" ]] && env_files+=("${root}/.env" "${root}/.env.local" "${root}/app/.env")
  while IFS= read -r f; do
    [[ -n "${f}" ]] && env_files+=("${f}")
  done < <(find "${search_root}" -maxdepth 4 \( -name '.env' -o -name 'wp-config.php' \) 2>/dev/null | head -40)

  for f in "${env_files[@]}"; do
    [[ -f "${f}" ]] || continue
    if [[ "${f}" == *wp-config.php ]]; then
      pass="$(grep -E "define\(\s*['\"]DB_PASSWORD['\"]" "${f}" 2>/dev/null \
        | head -1 \
        | sed -E "s/.*DB_PASSWORD['\"],\s*['\"]([^'\"]*)['\"].*/\1/")" || true
    else
      pass="$(grep -E '^DB_PASSWORD=' "${f}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'\''\r')" || true
    fi
    if [[ -n "${pass}" ]]; then
      printf '%s' "${pass}"
      return 0
    fi
  done
  return 1
}
