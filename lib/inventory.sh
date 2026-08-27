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

# Print pipe-separated sites:
# id|domain_name|user|type|php_version|vhost_template|user_password
# vhost_template in SQLite is often the FULL nginx config (newlines). Never emit that —
# it would split this loop and skip remaining sites. Custom vhosts are copied via rsync.
inventory_sites() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  sqlite3 -separator '|' "${db}" "
SELECT
  s.id,
  replace(replace(s.domain_name, char(10), ''), char(13), ''),
  replace(replace(s.user, char(10), ''), char(13), ''),
  replace(replace(s.type, char(10), ''), char(13), ''),
  COALESCE(p.php_version, ''),
  CASE
    WHEN s.vhost_template IS NULL OR trim(s.vhost_template) = '' THEN 'Generic'
    WHEN instr(s.vhost_template, char(10)) > 0 THEN 'Generic'
    WHEN s.vhost_template LIKE '#%' THEN 'Generic'
    WHEN s.vhost_template LIKE '%server {%' THEN 'Generic'
    WHEN s.vhost_template LIKE '%listen %' THEN 'Generic'
    WHEN length(s.vhost_template) > 80 THEN 'Generic'
    ELSE trim(s.vhost_template)
  END,
  ''
FROM site s
LEFT JOIN php_settings p ON p.site_id = s.id
ORDER BY s.domain_name;
"
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

# Print pipe-separated databases:
# site_id|domain_name|site_user|db_name|db_user
inventory_databases() {
  local db="${1:-${CLP_SYNC_TMP_DIR}/db.sq3}"
  sqlite3 -separator '|' "${db}" "
SELECT
  s.id,
  s.domain_name,
  s.user,
  d.name,
  COALESCE(du.user_name, '')
FROM site s
JOIN database d ON d.site_id = s.id
LEFT JOIN database_user du ON du.database_id = d.id
ORDER BY d.name;
"
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

  for f in "${root}/.env" "${root}/.env.local" "${root}/app/.env" "${root}/htdocs/.env" \
           "${root}/public/../.env" \
           "${root}/wp-config.php" "${root}/public/wp-config.php"; do
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
