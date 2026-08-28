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

# Print tab-separated sites. Never SELECT vhost blobs (they contain newlines).
# id, domain_name, user, type, php_version, vhost_template
inventory_sites() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  local out
  out="$(sqlite3 -separator $'\t' "${db}" "
SELECT
  s.id,
  COALESCE(s.domain_name, ''),
  COALESCE(s.user, ''),
  COALESCE(s.type, 'php'),
  COALESCE((SELECT p.php_version FROM php_settings p WHERE p.site_id = s.id LIMIT 1), '8.3'),
  'Generic'
FROM site s
ORDER BY s.id;
" 2>/dev/null)" && { printf '%s\n' "${out}"; return 0; }
  python3 - "${db}" <<'PY'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
colset = {r[1] for r in con.execute("PRAGMA table_info(site)")}

def col(*names):
    for n in names:
        if n in colset:
            return n
    return None

idc, dc, uc, tc = col("id"), col("domain_name", "domain"), col("user", "site_user"), col("type", "site_type")
if not idc:
    sys.exit(0)
fields = [c for c in (idc, dc, uc, tc) if c]
q = "SELECT " + ", ".join(f'"{f}"' for f in fields) + " FROM site ORDER BY id"
type_map = {
    "php": "php", "wordpress": "php", "woocommerce": "php",
    "nodejs": "nodejs", "node": "nodejs", "node.js": "nodejs",
    "python": "python", "static": "static", "html": "static",
    "reverse-proxy": "reverse-proxy", "reverse_proxy": "reverse-proxy",
    "reverseproxy": "reverse-proxy",
}
php_by_site = {}
try:
    for r in con.execute("SELECT site_id, php_version FROM php_settings"):
        if r[0] is not None and r[0] not in php_by_site:
            php_by_site[r[0]] = r[1] or ""
except sqlite3.Error:
    pass
for row in con.execute(q):
    m = {fields[i]: row[i] for i in range(len(fields))}
    sid = m.get(idc)
    domain = "" if not dc else ("" if m.get(dc) is None else str(m[dc]).replace("\n", " ").replace("\t", " ").strip())
    user = "" if not uc else ("" if m.get(uc) is None else str(m[uc]).replace("\n", " ").replace("\t", " ").strip())
    raw_type = ("" if not tc or m.get(tc) is None else str(m[tc]).strip().lower())
    site_type = type_map.get(raw_type, "php")
    php_ver = str(php_by_site.get(sid, "") or "8.3").replace("\n", " ").strip() or "8.3"
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
import re, sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
con.row_factory = sqlite3.Row
tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
db_table = "database" if "database" in tables else ("databases" if "databases" in tables else None)
if not db_table:
    sys.exit(0)

def clean(v):
    if v is None:
        return ""
    return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()

def domain_of(site_id, fallback=""):
    row = con.execute("SELECT * FROM site WHERE id = ?", (site_id,)).fetchone()
    if not row:
        return fallback
    keys = {str(k).lower(): k for k in row.keys()}
    for n in ("domain_name", "domain", "domainName"):
        k = keys.get(n.lower())
        if k is not None:
            s = clean(row[k])
            if s:
                return s
    for n in ("vhost_template", "vhost", "nginx_vhost"):
        k = keys.get(n.lower())
        if k is None:
            continue
        m = re.search(r"(?i)vhost for ([A-Za-z0-9.-]+)", clean(row[k]))
        if m:
            return m.group(1)
    return fallback

du_join = ""
du_col = "d.name"
if "database_user" in tables:
    du_join = "LEFT JOIN database_user du ON du.database_id = d.id"
    du_col = "COALESCE(du.user_name, '')"

q = f'''
SELECT s.id AS site_id, s.user AS site_user, d.name AS db_name, {du_col} AS db_user
FROM site s
JOIN "{db_table}" d ON d.site_id = s.id
{du_join}
ORDER BY d.name
'''
seen = set()
for row in con.execute(q):
    db_name = clean(row["db_name"])
    if not db_name or db_name in seen:
        continue
    seen.add(db_name)
    domain = domain_of(row["site_id"])
    print("\t".join([
        clean(row["site_id"]),
        domain,
        clean(row["site_user"]),
        db_name,
        clean(row["db_user"]) or db_name,
    ]))
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

guess_db_username() {
  local site_user="$1" domain="$2"
  local root="/home/${site_user}/htdocs/${domain}"
  local f user
  local search_root="/home/${site_user}/htdocs"
  local env_files=()
  [[ -d "${root}" ]] && env_files+=("${root}/.env" "${root}/.env.local" "${root}/app/.env")
  while IFS= read -r f; do
    [[ -n "${f}" ]] && env_files+=("${f}")
  done < <(find "${search_root}" -maxdepth 4 -name '.env' 2>/dev/null | head -20)
  for f in "${env_files[@]}"; do
    [[ -f "${f}" ]] || continue
    user="$(grep -E '^DB_USERNAME=' "${f}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'\''\r')" || true
    [[ -z "${user}" ]] && user="$(grep -E '^DB_USER=' "${f}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'\''\r')" || true
    if [[ -n "${user}" ]]; then
      printf '%s' "${user}"
      return 0
    fi
  done
  return 1
}
