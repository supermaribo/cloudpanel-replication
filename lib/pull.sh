#!/usr/bin/env bash
# Standby-side pull: files, nginx/php, panel sqlite, MySQL SOURCE import.

local_mysql() {
  local sock m
  m=/usr/bin/mysql
  [[ -x "${m}" ]] || m="$(command -v mysql)"
  sock=/run/mysqld/mysqld.sock
  [[ -S "${sock}" ]] || sock=/var/run/mysqld/mysqld.sock
  [[ -S "${sock}" ]] || die "local mysqld socket missing"
  "${m}" --no-defaults -u root --protocol=SOCKET --socket="${sock}" \
    --skip-password --batch --force --binary-mode --max-allowed-packet=512M "$@"
}

pull_probe() {
  local out="${CLP_SYNC_STATE_DIR}/last-probe"
  log_info "Probing master ${MASTER_HOST}"
  mkdir -p "${CLP_SYNC_STATE_DIR}"
  if ! master_ssh clp-sync-probe >"${out}"; then
    rm -f "${out}"
    return 1
  fi
  head -8 "${out}"
}

pull_panel_sqlite() {
  local dest="${CLP_SYNC_TMP_DIR}/db.sq3"
  local kept="${CLP_SYNC_STATE_DIR}/primary-db.sq3"
  local stamp="${CLP_SYNC_STATE_DIR}/panel.stat"
  local cur=""
  mkdir -p "${CLP_SYNC_TMP_DIR}" "${CLP_SYNC_STATE_DIR}"
  cur="$(awk -F '\t' '$1=="panel" && NF>=3 { print $2 "\t" $3; exit }' "${CLP_SYNC_STATE_DIR}/last-probe" 2>/dev/null || true)"
  if [[ -n "${cur}" && -f "${stamp}" && -s "${kept}" && "$(cat "${stamp}")" == "${cur}" ]]; then
    log_info "Panel sqlite unchanged on master — skipping snapshot pull"
    cp -a "${kept}" "${dest}"
    INC_SKIPPED=$((INC_SKIPPED + 1))
    return 0
  fi
  log_info "Pulling CloudPanel sqlite snapshot"
  rm -f "${dest}"
  if ! master_ssh clp-panel-backup >"${dest}"; then
    die "panel snapshot ssh failed (update /opt/clp-sync on the MASTER too)"
  fi
  [[ -s "${dest}" ]] || die "empty panel snapshot"
  chmod 600 "${dest}"
  sqlite3 "${dest}" "PRAGMA integrity_check;" | grep -qx ok || die "panel snapshot failed integrity_check"
  cp -a "${dest}" "${kept}"
  chmod 600 "${kept}"
  if [[ -n "${cur}" ]]; then
    printf '%s\n' "${cur}" >"${stamp}"
    chmod 600 "${stamp}"
  fi
}

ensure_linux_users() {
  local db_snap="$1"
  local user
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    if ! id -u "${user}" >/dev/null 2>&1; then
      log_info "Creating Linux user ${user}"
      useradd --disabled-password --gecos "" --home "/home/${user}" --shell /bin/bash "${user}" || true
    fi
    mkdir -p "/home/${user}/htdocs" "/home/${user}/logs/nginx"
    chown "${user}:${user}" "/home/${user}" "/home/${user}/htdocs" \
      "/home/${user}/logs" "/home/${user}/logs/nginx" 2>/dev/null || true
  done < <(inventory_site_users "${db_snap}")
  local ftp_user home site_user
  while IFS='|' read -r ftp_user home site_user; do
    [[ -n "${ftp_user}" ]] || continue
    if ! id -u "${ftp_user}" >/dev/null 2>&1; then
      log_info "Creating FTP user ${ftp_user}"
      useradd --disabled-password --gecos "" --home "${home:-/home/${ftp_user}}" --shell /bin/bash "${ftp_user}" || true
    fi
  done < <(inventory_ftp_users "${db_snap}")
}

# Empty log files the replica actually writes to (we do not copy logs from live).
ensure_site_log_files() {
  local user="$1"
  local home="/home/${user}"
  mkdir -p "${home}/logs/nginx" "${home}/logs/php"
  touch "${home}/logs/nginx/access.log" "${home}/logs/nginx/error.log" \
    "${home}/logs/php/error.log" 2>/dev/null || true
  chown "${user}:${user}" "${home}/logs" "${home}/logs/nginx" "${home}/logs/php" \
    "${home}/logs/nginx/access.log" "${home}/logs/nginx/error.log" \
    "${home}/logs/php/error.log" 2>/dev/null || true
  chmod 755 "${home}/logs" "${home}/logs/nginx" "${home}/logs/php" 2>/dev/null || true
  chmod 644 "${home}/logs/nginx/access.log" "${home}/logs/nginx/error.log" \
    "${home}/logs/php/error.log" 2>/dev/null || true
}

# Live vhost logs only on :443 (Cloudflare). :8080 inherits "access_log off",
# so a successful replica hit never shows in CloudPanel site logs. Re-apply
# after each nginx pull — master vhosts overwrite this marker.
ensure_backend_access_logs() {
  python3 - <<'PY'
import pathlib, re
marker = "# clp-sync-backend-log"
root = pathlib.Path("/etc/nginx/sites-enabled")
changed = False
if not root.is_dir():
    raise SystemExit(0)
for path in sorted(root.glob("*.conf")):
    text = path.read_text(errors="replace")
    if marker in text:
        continue
    lines = text.splitlines(keepends=True)
    out = []
    depth = 0
    server_depth = None
    is_8080 = False
    inserted = False
    file_changed = False
    for line in lines:
        stripped = line.strip()
        if server_depth is None and re.match(r"server\s*\{", stripped):
            server_depth = depth
            is_8080 = False
            inserted = False
        if server_depth is not None and (
            "listen 127.0.0.1:8080" in stripped or "listen [::1]:8080" in stripped
        ):
            is_8080 = True
        m = re.search(r"root\s+/home/([^/\s]+)/", stripped)
        out.append(line)
        if is_8080 and not inserted and m:
            indent = re.match(r"^(\s*)", line).group(1)
            user = m.group(1)
            out.append(f"{indent}{marker}\n")
            out.append(f"{indent}access_log /home/{user}/logs/nginx/access.log cloudflare;\n")
            out.append(f"{indent}error_log /home/{user}/logs/nginx/error.log;\n")
            inserted = True
            file_changed = True
        depth += line.count("{") - line.count("}")
        if server_depth is not None and depth <= server_depth:
            server_depth = None
            is_8080 = False
    if file_changed:
        path.write_text("".join(out))
        changed = True
raise SystemExit(0 if changed else 1)
PY
}

# Laravel / CloudPanel dirs that must exist on the replica even when we skip
# syncing logs and disposable caches. Missing bootstrap/cache is a site-wide 500.
ensure_site_runtime_dirs() {
  local user="$1"
  local home="/home/${user}"
  local htdocs="${home}/htdocs"
  ensure_site_log_files "${user}"
  if [[ -d "${htdocs}/bootstrap" ]]; then
    mkdir -p "${htdocs}/bootstrap/cache"
    rsync_from_master "${htdocs}/bootstrap/cache/" "${htdocs}/bootstrap/cache/" \
      --chown="${user}:${user}" \
      || log_warn "could not pull ${htdocs}/bootstrap/cache"
  fi
  if [[ -d "${htdocs}/storage" ]]; then
    mkdir -p \
      "${htdocs}/storage/logs" \
      "${htdocs}/storage/framework/cache/data" \
      "${htdocs}/storage/framework/sessions" \
      "${htdocs}/storage/framework/views"
  fi
  chown -R "${user}:${user}" "${home}/logs" \
    "${htdocs}/bootstrap/cache" \
    "${htdocs}/storage" 2>/dev/null || true
  chmod -R ug+rwX "${htdocs}/bootstrap/cache" "${htdocs}/storage" 2>/dev/null || true
}

pull_site_files() {
  local db_snap="$1"
  local user excludes="${RSYNC_EXCLUDES_FILE}"
  [[ -f "${excludes}" ]] || die "Missing ${excludes}"
  log_info "Pulling site home directories"
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    mkdir -p "/home/${user}"
    rsync_from_master "/home/${user}/" "/home/${user}/" --exclude-from="${excludes}" \
      --exclude='/logs/***' --exclude='*.log' --exclude='*.log.*' \
      --chown="${user}:${user}" \
      || die "could not pull /home/${user}"
    ensure_site_runtime_dirs "${user}"
  done < <(inventory_site_users "${db_snap}")
  log_ok "Site files pulled"
}

pull_nginx_php() {
  local db_snap="${1:-}"
  local changed=0
  local f ver_dir ver pool_dir unit
  local -A php_wanted=()
  while IFS= read -r unit; do
    [[ "${unit}" =~ ^php([0-9]+\.[0-9]+)-fpm$ ]] || continue
    php_wanted["${BASH_REMATCH[1]}"]=1
  done < <(site_php_fpm_units "${db_snap}")

  log_info "Pulling nginx / SSL / PHP-FPM"
  if ((${#php_wanted[@]})); then
    log_info "PHP versions used by sites: ${!php_wanted[*]}"
  fi
  for f in nginx.conf global_settings fastcgi_params mime.types blocked_ips proxy_params; do
    rsync_from_master "/etc/nginx/${f}" "/etc/nginx/${f}" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
  done
  for dir in sites-enabled sites-available ssl-certificates conf.d modules-enabled cloudflare; do
    rsync_from_master "/etc/nginx/${dir}" "/etc/nginx/" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
  done
  shopt -s nullglob
  for ver_dir in /etc/php/*/fpm; do
    [[ -d "${ver_dir}" ]] || continue
    ver="${ver_dir#/etc/php/}"
    ver="${ver%/fpm}"
    if ((${#php_wanted[@]})) && [[ -z "${php_wanted[$ver]:-}" ]]; then
      INC_SKIPPED=$((INC_SKIPPED + 1))
      continue
    fi
    mkdir -p "${ver_dir}/conf.d" "${ver_dir}/pool.d"
    rsync_from_master "${ver_dir}/php.ini" "${ver_dir}/php.ini" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
    rsync_from_master "${ver_dir}/conf.d/" "${ver_dir}/conf.d/" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
  done
  for pool_dir in /etc/php/*/fpm/pool.d; do
    ver="${pool_dir#/etc/php/}"
    ver="${ver%/fpm/pool.d}"
    if ((${#php_wanted[@]})) && [[ -z "${php_wanted[$ver]:-}" ]]; then
      INC_SKIPPED=$((INC_SKIPPED + 1))
      continue
    fi
    mkdir -p "${pool_dir}"
    rsync_from_master "${pool_dir}/" "${pool_dir}/" && [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && changed=1
    true
  done
  shopt -u nullglob

  local u base patched=0
  for u in /home/*; do
    [[ -d "${u}" ]] || continue
    base="$(basename "${u}")"
    case "${base}" in root|clp|lost+found) continue ;; esac
    ensure_site_log_files "${base}"
  done
  if ensure_backend_access_logs; then
    patched=1
    log_info "Enabled replica :8080 access/error logs (not on live vhost)"
  fi

  if [[ "${changed}" -eq 1 || "${patched}" -eq 1 ]]; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    else
      log_warn "nginx -t failed after config pull — not reloading"
    fi
    ensure_php_services
    reload_active_php_fpm
  else
    log_info "nginx/PHP configs unchanged — skip reload"
  fi
  log_ok "Nginx/PHP pulled"
}

reload_active_php_fpm() {
  local s
  for s in clp-php-fpm; do
    systemctl is-active --quiet "${s}" 2>/dev/null && systemctl reload "${s}" 2>/dev/null || true
  done
  systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
    | awk '$1 ~ /^php[0-9]+\.[0-9]+-fpm\.service$/ { sub(/\.service$/, "", $1); print $1 }' \
    | while IFS= read -r s; do
        [[ -n "${s}" ]] || continue
        systemctl reload "${s}" 2>/dev/null || true
      done
}

pull_site_crontabs() {
  local report line kind user b64
  log_info "Pulling site user crontabs"
  report="$(master_ssh clp-sync-crontabs 2>/dev/null || true)"
  if [[ "${report}" != clp-sync-crontabs* ]]; then
    log_warn "Master has no clp-sync-crontabs yet — update /opt/clp-sync on the live box"
    return 0
  fi
  while IFS=$'\t' read -r kind user b64; do
    [[ "${kind}" == "C" ]] || continue
    [[ "${user}" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]] || continue
    id -u "${user}" >/dev/null 2>&1 || continue
    [[ -n "${b64}" ]] || continue
    if printf '%s' "${b64}" | base64 -d 2>/dev/null | crontab -u "${user}" - 2>/dev/null; then
      log_info "crontab ${user}: applied"
    else
      log_warn "crontab ${user}: could not apply"
    fi
  done < <(printf '%s\n' "${report}" | grep -E '^C	')
  log_ok "Site crontabs pulled"
}

pull_system_extras() {
  local le_changed=0
  log_info "Pulling certs, cron, varnish config"
  rsync_from_master "/etc/letsencrypt/" "/etc/letsencrypt/" || log_warn "letsencrypt pull skipped"
  [[ "${RSYNC_CHANGED:-0}" -eq 1 ]] && le_changed=1
  rsync_from_master "/etc/cron.d/" "/etc/cron.d/" || log_warn "cron.d pull skipped"
  rsync_from_master "/etc/varnish/" "/etc/varnish/" || true
  pull_site_crontabs
  if [[ "${le_changed}" -eq 1 ]]; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  fi
}

# Read-only RAM / PHP-FPM / MySQL snapshot. Safe on live and replica.
report_resources() {
  python3 - <<'PY'
import glob, os, re, subprocess, textwrap

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

def kv_file(path):
    out = {}
    try:
        for line in open(path, errors="replace"):
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return out

cfg = kv_file("/etc/clp-sync/config.env")
role = cfg.get("ROLE", open("/etc/clp-sync/role").read().strip() if os.path.isfile("/etc/clp-sync/role") else "?")
host = sh("hostname -f") or sh("hostname")
print("clp-sync resources")
print("  host:", host)
print("  role:", role)

mem = {}
for line in sh("cat /proc/meminfo").splitlines():
    if ":" in line:
        k, v = line.split(":", 1)
        mem[k] = v.strip()
def mib(key):
    raw = mem.get(key, "0")
    n = int(re.sub(r"[^0-9]", "", raw) or 0)
    return n // 1024
print("  ram: %s MiB total, %s MiB available" % (mib("MemTotal"), mib("MemAvailable")))

units = sh("systemctl list-units --type=service --state=running --no-legend --plain").splitlines()
php_units = []
for line in units:
    name = line.split()[0] if line.split() else ""
    if re.match(r"php[0-9]+\.[0-9]+-fpm\.service$", name) or name in ("clp-php-fpm.service", "varnish.service", "mysql.service", "nginx.service"):
        php_units.append(name.replace(".service", ""))
print("  running:", ", ".join(php_units) if php_units else "(none)")

nproc = sh("pgrep -c php-fpm") or sh("pgrep -c php-fpm8.5")
print("  php-fpm processes:", nproc or "0")

print("  pools:")
warned = False
for path in sorted(glob.glob("/etc/php/*/fpm/pool.d/*.conf")):
    base = os.path.basename(path)
    if base in ("www.conf", "default.conf", "global.conf"):
        continue
    text = open(path, errors="replace").read()
    def grab(key, default="-"):
        m = re.search(r"^%s\s*=\s*(.+)$" % re.escape(key), text, re.M)
        return m.group(1).strip() if m else default
    pm = grab("pm")
    mx = grab("pm.max_children")
    user = grab("user")
    listen = grab("listen")
    print("    %s  user=%s pm=%s max_children=%s listen=%s" % (base, user, pm, mx, listen))
    try:
        if pm == "ondemand" and int(mx) >= 200:
            warned = True
    except ValueError:
        pass

bp = sh("mysql --no-defaults -N -e 'SELECT @@innodb_buffer_pool_size' 2>/dev/null | tail -1")
if bp.isdigit():
    print("  innodb_buffer_pool_size: %s MiB" % (int(bp) // 1024 // 1024))

print()
print("  Live tuning (CloudPanel UI, then next pull copies it):")
print("    - Cap pm.max_children from RAM, not 250:")
print("      (RAM_MiB - MySQL - 1024) / memory_limit_MiB  per pool")
print("    - OPcache JIT 128M x several Laravel sites burns idle RAM; 32-64M is usually enough")
print("    - Keep pm=ondemand for spiky traffic, or dynamic for sustained load")
print("    - Leave Varnish off if Cloudflare already sits in front")
if warned:
    print("  WARN: one or more pools use ondemand max_children>=200 (OOM risk under load)")
PY
}

ensure_php_services() {
  # Panel PHP only. Site php*-fpm units are matched to the master in
  # apply_master_service_state (do not start every installed version).
  systemctl start clp-php-fpm 2>/dev/null || true
}

# PHP-FPM units that at least one site actually uses (panel sqlite).
site_php_fpm_units() {
  local db="${1:-}"
  [[ -n "${db}" && -f "${db}" ]] || return 0
  python3 - "${db}" <<'PY'
import re, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
try:
    rows = con.execute("SELECT DISTINCT php_version FROM php_settings WHERE php_version IS NOT NULL")
except sqlite3.Error:
    sys.exit(0)
seen = set()
for (raw,) in rows:
    s = str(raw or "").strip().lower()
    m = re.search(r"(\d+\.\d+)", s)
    if not m:
        continue
    unit = "php%s-fpm" % m.group(1)
    if unit not in seen:
        seen.add(unit)
        print(unit)
PY
}

# Match optional services to the master. Cache/daemons (varnish, redis, …)
# follow is-active (CloudPanel "Stopped" is often still enabled). PHP-FPM
# follows is-enabled plus which versions sites use. Never touch mysql/nginx/ssh/panel PHP.
apply_master_service_state() {
  local db_snap="${1:-}"
  local unit enabled active want disable_unit
  local -A master_enabled=()
  local -A master_active=()
  local -A php_needed=()
  local report probe_out

  while IFS= read -r unit; do
    [[ -n "${unit}" ]] && php_needed["${unit}"]=1
  done < <(site_php_fpm_units "${db_snap}")

  report="$(master_ssh clp-sync-services 2>/dev/null || true)"
  probe_out="$(master_ssh clp-sync-probe 2>/dev/null || true)"
  if [[ "${report}" != clp-sync-services* ]]; then
    report="clp-sync-services 1"$'\n'
    report+="$(printf '%s\n' "${probe_out}" | awk -F '\t' '$1=="svc" && NF==4 { print $2 "\t" $3 "\t" $4 }')"
  fi
  if ! printf '%s\n' "${report}" | grep -q $'^varnish\t'; then
    log_warn "Master has no service report yet — update /opt/clp-sync on the live box. Stopping varnish if nginx does not use it."
  fi

  log_info "Matching optional services to master"
  while IFS=$'\t' read -r unit enabled active; do
    [[ "${unit}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || continue
    case "${unit}" in
      mysql|mysqld|mariadb|nginx|clp-nginx|cloudpanel-nginx|ssh|sshd|tailscaled|clp-php-fpm|clp-sync|cron)
        continue
        ;;
    esac
    systemctl cat "${unit}.service" >/dev/null 2>&1 || continue
    master_enabled["${unit}"]="${enabled}"
    master_active["${unit}"]="${active}"

    want=0
    disable_unit=0
    case "${enabled}" in
      disabled|masked)
        want=0
        disable_unit=1
        ;;
      enabled|enabled-runtime|alias|static|indirect|generated)
        want=1
        ;;
      *)
        continue
        ;;
    esac

    case "${unit}" in
      varnish|varnishncsa|redis-server|redis|proftpd|memcached|rabbitmq-server)
        # CloudPanel shows Stopped without always disabling the unit.
        # Disable on the replica so a reboot does not start a daemon the master has off.
        if [[ "${active}" != "active" ]]; then
          want=0
          disable_unit=1
        fi
        ;;
    esac

    if [[ "${unit}" =~ ^php[0-9]+\.[0-9]+-fpm$ ]]; then
      if [[ ${#php_needed[@]} -gt 0 && -z "${php_needed[${unit}]:-}" ]]; then
        want=0
      fi
    fi

    if [[ "${want}" -eq 1 ]]; then
      if [[ "${disable_unit}" -eq 0 ]]; then
        systemctl enable "${unit}" >/dev/null 2>&1 || true
      fi
      if ! systemctl is-active --quiet "${unit}"; then
        log_info "Starting ${unit} (running on master)"
        systemctl start "${unit}" 2>/dev/null || log_warn "Could not start ${unit}"
      fi
    else
      if systemctl is-active --quiet "${unit}"; then
        log_info "Stopping ${unit} (stopped/disabled on master or unused PHP)"
        systemctl stop "${unit}" 2>/dev/null || true
      fi
      if [[ "${disable_unit}" -eq 1 ]]; then
        systemctl disable "${unit}" >/dev/null 2>&1 || true
      fi
    fi
  done < <(printf '%s\n' "${report}" | awk -F '\t' 'NF==3 && $1 !~ /^clp-sync-services/')

  local u
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    [[ -n "${master_enabled[${u}]:-}" ]] && continue
    if [[ -n "${php_needed[${u}]:-}" ]]; then
      systemctl enable "${u}" >/dev/null 2>&1 || true
      systemctl start "${u}" 2>/dev/null || true
    elif [[ ${#php_needed[@]} -gt 0 ]] && systemctl is-active --quiet "${u}"; then
      log_info "Stopping unused ${u} (no site uses this PHP)"
      systemctl stop "${u}" 2>/dev/null || true
    fi
  done < <(systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null \
      | awk '$1 ~ /^php[0-9]+\.[0-9]+-fpm\.service$/ { sub(/\.service$/, "", $1); print $1 }')

  # No master varnish row: if vhosts do not use it, stop the replica daemon.
  # No master varnish row: stop the replica daemon unless nginx actually
  # proxies to it (ignore leftover "X-Varnish" hide_header / comments).
  if [[ -z "${master_enabled[varnish]:-}" ]] && { systemctl is-active --quiet varnish || systemctl is-enabled --quiet varnish; }; then
    if ! grep -RqiE '127\.0\.0\.1:6081|localhost:6081|varnish:6081' /etc/nginx/sites-enabled /etc/nginx/conf.d /home/clp/services/nginx 2>/dev/null; then
      log_info "Stopping varnish (not proxied by nginx; master service report missing)"
      systemctl disable --now varnish varnishncsa 2>/dev/null || true
    fi
  fi

  ensure_php_services
  log_ok "Optional services matched"
}

CLP_REPLICATED_MARK="clp-sync-replicated.html.twig"
CLP_SITES_HEADER="/home/clp/htdocs/app/files/templates/Frontend/Partial/header.html.twig"
CLP_REPLICATED_PARTIAL="/home/clp/htdocs/app/files/templates/Frontend/Partial/clp-sync-replicated.html.twig"

ensure_sync_ui() {
  local sudoers=/etc/sudoers.d/clp-sync-ui
  local tokenf=/etc/clp-sync/ui.token
  local pub=/home/clp/htdocs/app/files/public/clp-sync.php
  mkdir -p /etc/clp-sync
  if [[ ! -f "${tokenf}" ]]; then
    openssl rand -hex 16 >"${tokenf}"
  fi
  chmod 600 "${tokenf}"
  chown root:root "${tokenf}"
  install -m 644 "${CLP_SYNC_ROOT}/share/clp-sync.php" "${pub}"
  chown clp:clp "${pub}" 2>/dev/null || true
  cat >"${sudoers}" <<'EOF'
Defaults:clp !requiretty
clp ALL=(root) NOPASSWD: /opt/clp-sync/bin/clp-sync-ui
EOF
  chmod 440 "${sudoers}"
  visudo -cf "${sudoers}" >/dev/null 2>&1 || log_warn "sudoers clp-sync-ui failed visudo"
}

ensure_replicated_badge() {
  local header="${CLP_SITES_HEADER}"
  local partial="${CLP_REPLICATED_PARTIAL}"
  local when tz="${DISPLAY_TZ:-Europe/London}" token interval
  [[ -f "${header}" ]] || return 0
  ensure_sync_ui
  when="$(TZ="${tz}" date '+%-d %b %Y, %H:%M')"
  token="$(tr -d '[:space:]' </etc/clp-sync/ui.token)"
  interval="${SYNC_INTERVAL:-1h}"
  case "${interval}" in
    1h|2h|4h|6h|12h|24h|off) ;;
    *) interval=1h ;;
  esac
  age_min="$(last_sync_age_minutes 2>/dev/null || echo 99999)"
  if [[ "${age_min}" -ge 99999 ]]; then
    age_txt="no completed sync recorded"
  elif [[ "${age_min}" -le 1 ]]; then
    age_txt="1 minute ago"
  else
    age_txt="${age_min} minutes ago"
  fi
  mkdir -p "$(dirname "${partial}")"
  CLP_BADGE_WHEN="${when}" CLP_BADGE_TOKEN="${token}" CLP_BADGE_INTERVAL="${interval}" \
    CLP_BADGE_AGE="${age_txt}" \
    python3 - "${partial}" <<'PY'
import html, json, os, pathlib, sys
p = pathlib.Path(sys.argv[1])
when = html.escape(os.environ.get("CLP_BADGE_WHEN") or "")
token = html.escape(os.environ.get("CLP_BADGE_TOKEN") or "")
cur = os.environ.get("CLP_BADGE_INTERVAL") or "1h"
age_txt = os.environ.get("CLP_BADGE_AGE") or "unknown age"
when_raw = os.environ.get("CLP_BADGE_WHEN") or ""
prompt = (
    f"Last sync was {age_txt} ({when_raw}). "
    "This server becomes LIVE. The other becomes the replica and will copy FROM here. "
    "Point DNS here first.\n"
    "Type LIVE to confirm you want this copy."
)
prompt_js = json.dumps(prompt)
opts = [("1h", "Every 1 hour"), ("2h", "Every 2 hours"), ("4h", "Every 4 hours"),
        ("6h", "Every 6 hours"), ("12h", "Every 12 hours"), ("24h", "Every 24 hours"),
        ("off", "Manual only")]
sel = []
for val, lab in opts:
    s = " selected" if val == cur else ""
    sel.append(f'<option value="{val}"{s}>{lab}</option>')
p.write_text(f"""\
<style>.clp-sync-replicated-badge details>summary{{list-style:none}}.clp-sync-replicated-badge details>summary::-webkit-details-marker{{display:none}}</style>
<span class="clp-sync-replicated-badge" style="display:inline-flex;align-items:center;gap:.4rem;vertical-align:middle;margin-left:.5rem;position:relative;">
  <span style="display:inline-flex;flex-direction:column;line-height:1.15;text-align:center;">
    <span class="badge bg-danger" style="font-size:.65rem;letter-spacing:.04em;">REPLICATED</span>
{{% if is_granted('ROLE_ADMIN') %}}
    <details style="position:relative;">
      <summary style="list-style:none;cursor:pointer;font-size:.58rem;opacity:.8;white-space:nowrap;text-align:center;">{when} &#9662;</summary>
      <div style="position:absolute;left:50%;transform:translateX(-50%);top:calc(100% + .35rem);z-index:1080;min-width:13.5rem;padding:.55rem .65rem .65rem;border-radius:.4rem;background:var(--bs-body-bg,#fff);color:var(--bs-body-color,#212529);border:1px solid var(--bs-border-color,#dee2e6);box-shadow:0 .35rem .8rem rgba(0,0,0,.12);text-align:left;">
        <form method="post" action="/clp-sync.php" style="margin:0;">
          <input type="hidden" name="token" value="{token}">
          <input type="hidden" name="clp_op" value="frequency">
          <label style="display:block;font-size:.62rem;opacity:.65;margin-bottom:.2rem;">Sync every</label>
          <select name="interval" onchange="this.form.submit()" style="width:100%;font-size:.75rem;padding:.2rem .3rem;border:1px solid var(--bs-border-color,#dee2e6);border-radius:.25rem;background:transparent;color:inherit;">
            {''.join(sel)}
          </select>
        </form>
        <form method="post" action="/clp-sync.php" style="margin:.5rem 0 0;display:flex;gap:.35rem;flex-wrap:nowrap;">
          <input type="hidden" name="token" value="{token}">
          <button type="submit" name="clp_op" value="now" class="btn btn-sm btn-outline-secondary" style="font-size:.7rem;padding:.18rem .5rem;white-space:nowrap;">Sync now</button>
          <input type="hidden" name="confirm" id="clp-sync-live-confirm" value="">
          <button type="submit" name="clp_op" value="live" class="btn btn-sm btn-danger" style="font-size:.7rem;padding:.18rem .5rem;white-space:nowrap;"
            onclick='var t=prompt({prompt_js}); if(t!=="LIVE") return false; document.getElementById("clp-sync-live-confirm").value=t; return true;'>Make live</button>
        </form>
      </div>
    </details>
{{% else %}}
    <span style="font-size:.58rem;opacity:.8;white-space:nowrap;">{when}</span>
{{% endif %}}
  </span>
</span>
""")
PY
  chown clp:clp "${partial}" 2>/dev/null || true
  python3 - "${header}" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
include = "{{ include('Frontend/Partial/clp-sync-replicated.html.twig') }}"
old = (
    '<span class="badge bg-danger clp-sync-replicated-badge" '
    'style="vertical-align:middle;margin-left:.4rem;font-size:.65rem;'
    'letter-spacing:.04em;">REPLICATED</span>'
)
text = text.replace(old, "")
needle = """<a href="{{ path('clp_sites') }}" title="{% trans %}Sites{% endtrans %}">{% trans %}Sites{% endtrans %}</a>"""
if include not in text and needle in text:
    text = text.replace(needle, needle + include, 1)
p.write_text(text)
PY
  rm -rf /home/clp/htdocs/app/files/var/cache/prod/twig 2>/dev/null || true
  log_ok "CloudPanel menu: REPLICATED ${when}"
}

ensure_live_badge() {
  local header="${CLP_SITES_HEADER}"
  local partial="${CLP_REPLICATED_PARTIAL}"
  mkdir -p "$(dirname "${partial}")"
  cat >"${partial}" <<'EOF'
<span class="clp-sync-replicated-badge" style="display:inline-flex;flex-direction:column;vertical-align:middle;margin-left:.45rem;line-height:1.15;text-align:center;">
  <span class="badge bg-success" style="font-size:.65rem;letter-spacing:.04em;">LIVE</span>
</span>
EOF
  chown clp:clp "${partial}" 2>/dev/null || true
  [[ -f "${header}" ]] || return 0
  python3 - "${header}" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
include = "{{ include('Frontend/Partial/clp-sync-replicated.html.twig') }}"
needle = """<a href="{{ path('clp_sites') }}" title="{% trans %}Sites{% endtrans %}">{% trans %}Sites{% endtrans %}</a>"""
if include not in text and needle in text:
    text = text.replace(needle, needle + include, 1)
p.write_text(text)
PY
  rm -rf /home/clp/htdocs/app/files/var/cache/prod/twig 2>/dev/null || true
  rm -f /home/clp/htdocs/app/files/public/clp-sync.php
}

remove_replicated_badge() {
  ensure_live_badge
}

apply_user_identities() {
  local report line kind user uid gid home shell hash groups
  report="$(master_ssh clp-sync-passwd 2>/dev/null || true)"
  if [[ "${report}" != clp-sync-passwd* ]]; then
    log_warn "Master has no clp-sync-passwd yet — update /opt/clp-sync on the live box (site passwords not mirrored)"
    return 0
  fi
  log_info "Applying site/FTP/clp password hashes from master"
  while IFS=$'\t' read -r kind user a b c d; do
    [[ "${user}" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]] || continue
    case "${user}" in
      root|daemon|bin|sys|sync|nobody|mysql|sshd|ubuntu|admin|debian) continue ;;
    esac
    case "${kind}" in
      P)
        uid="$a"; gid="$b"; home="$c"; shell="$d"
        getent group "${gid}" >/dev/null 2>&1 || groupadd -g "${gid}" "${user}" 2>/dev/null || true
        if ! id -u "${user}" >/dev/null 2>&1; then
          useradd -u "${uid}" -g "${gid}" -d "${home}" -s "${shell:-/bin/bash}" -m "${user}" 2>/dev/null \
            || useradd --disabled-password --gecos "" --home "${home}" --shell "${shell:-/bin/bash}" "${user}" || true
        else
          cur="$(id -u "${user}" 2>/dev/null || true)"
          if [[ -n "${uid}" && -n "${cur}" && "${cur}" != "${uid}" ]]; then
            log_warn "User ${user} UID ${cur} != live ${uid} (leaving as-is; rsync --chown maps files)"
          fi
        fi
        [[ -n "${home}" ]] && mkdir -p "${home}"
        ;;
      S)
        hash="$a"
        [[ -n "${hash}" ]] && usermod -p "${hash}" "${user}" 2>/dev/null || true
        ;;
      G)
        groups="$a"
        IFS=',' read -r -a garr <<<"${groups}"
        local g=""
        for g in "${garr[@]}"; do
          [[ -z "${g}" || "${g}" == "${user}" ]] && continue
          getent group "${g}" >/dev/null 2>&1 || continue
          usermod -aG "${g}" "${user}" 2>/dev/null || true
        done
        ;;
    esac
  done < <(printf '%s\n' "${report}" | grep -E '^[PSG]	')
  log_ok "User identities applied"
}

verify_standby_ready() {
  local fail=0
  log_info "Checking standby is fail-over ready"
  if nginx -t >/dev/null 2>&1; then
    log_ok "nginx config valid"
  else
    log_warn "nginx -t failed"; fail=1
  fi
  if local_mysql -N -e "SELECT 1" >/dev/null 2>&1; then
    log_ok "MySQL accepting connections"
  else
    log_warn "MySQL probe failed"; fail=1
  fi
  if systemctl is-active --quiet clp-php-fpm; then
    log_ok "clp-php-fpm running"
  else
    log_warn "clp-php-fpm not running"; fail=1
  fi
  if [[ "${fail}" -eq 0 ]]; then
    log_ok "Standby health check passed"
  else
    log_warn "Standby health check had warnings (sync still recorded)"
  fi
}

# Master CloudPanel is often AWS. The dashboard includes aws-information.html.twig
# which cURLs IMDS (169.254.169.254). That times out on a local LXC and 500s.
adapt_standby_panel_config() {
  local dest="${1:-${CLP_DB_PATH}}"
  python3 - "${dest}" <<'PY' || true
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
names = [c[1] for c in con.execute('PRAGMA table_info("config")')]
keycol = next((n for n in names if n.lower() in ("name", "key")), None)
valcol = next((n for n in names if n.lower() in ("value", "setting_value", "data")), None)
if not keycol or not valcol:
    raise SystemExit(0)
# Empty cloud matches {% if cloud == "" %} and skips AWS/DO/Hetzner/GCE/Vultr partials.
con.execute(f'UPDATE config SET "{valcol}" = ? WHERE "{keycol}" = ?', ("", "cloud"))
con.commit()
con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
print("sqlite cloud= (standby, skip IMDS)")
PY
}

apply_panel_db_local() {
  local src="$1"
  local dest="${CLP_DB_PATH}"
  local stamp="${CLP_SYNC_STATE_DIR}/panel-db.sha256"
  local digest
  [[ "${APPLY_PANEL_DB}" == "1" ]] || return 0
  digest="$(sha256_file "${src}")"
  if [[ -f "${stamp}" && "$(cat "${stamp}")" == "${digest}" ]]; then
    log_info "Panel sqlite already applied (unchanged) — skip PHP restart"
    INC_SKIPPED=$((INC_SKIPPED + 1))
    return 0
  fi
  log_info "Applying panel sqlite locally"
  local s
  for s in clp-php-fpm php7.4-fpm php8.0-fpm php8.1-fpm php8.2-fpm php8.3-fpm php8.4-fpm php8.5-fpm; do
    systemctl stop "${s}" 2>/dev/null || true
  done
  rm -f "${dest}-wal" "${dest}-shm" "${dest}-journal"
  cp -a "${src}" "${dest}.new"
  chown clp:clp "${dest}.new" 2>/dev/null || true
  chmod 660 "${dest}.new"
  mv -f "${dest}.new" "${dest}"
  rm -f "${dest}-wal" "${dest}-shm" "${dest}-journal"
  adapt_standby_panel_config "${dest}"
  chown clp:clp "${dest}" 2>/dev/null || true
  ensure_php_services
  printf '%s\n' "${digest}" >"${stamp}"
  chmod 600 "${stamp}"
  local n
  n="$(sqlite3 "${src}" 'SELECT COUNT(*) FROM user;' 2>/dev/null || echo 0)"
  log_ok "Panel sqlite applied (${n} user(s))"
}

pull_app_secret() {
  log_info "Pulling CloudPanel .env (APP_SECRET)"
  mkdir -p /home/clp/htdocs/app/files
  rsync_from_master "/home/clp/htdocs/app/files/.env" "/home/clp/htdocs/app/files/.env" || true
}

disable_local_backup_jobs() {
  log_info "Disabling backup / image jobs on this standby"
  python3 - "${CLP_DB_PATH}" <<'PY' || true
import pathlib, re, sqlite3, sys
JOB_RE = re.compile(r"db:backup|remote-backup|\brclone\b|create_backup\.sh|aws:image:create", re.I)
p = pathlib.Path("/etc/cron.d/clp")
if p.is_file():
    lines = p.read_text(errors="replace").splitlines(True)
    out, ch = [], False
    for line in lines:
        raw = line.rstrip("\n")
        stripped = raw.lstrip()
        if stripped and not stripped.startswith("#") and JOB_RE.search(stripped):
            out.append("# clp-sync-disabled: " + stripped + "\n")
            ch = True
        else:
            out.append(line if line.endswith("\n") else line + "\n")
    if ch:
        p.write_text("".join(out))
        print("disabled jobs in", p)
try:
    con = sqlite3.connect(sys.argv[1])
    names = [c[1] for c in con.execute('PRAGMA table_info("config")')]
    keycol = next((n for n in names if n.lower() in ("name", "key")), None)
    valcol = next((n for n in names if n.lower() in ("value", "setting_value", "data")), None)
    if keycol and valcol:
        con.execute(f'UPDATE config SET "{valcol}" = ? WHERE "{keycol}" = ?', ("0", "remote_backup_enabled"))
        con.commit()
        print("sqlite remote_backup_enabled=0")
except sqlite3.Error as e:
    print("sqlite skip", e)
PY
}

write_client_cnf() {
  local cnf="$1"
  MYSQL_DUMP_USER="$2" MYSQL_DUMP_PASS="$3" MYSQL_DUMP_HOST="$4" MYSQL_DUMP_PORT="$5" \
    MYSQL_DUMP_CNF="${cnf}" python3 - <<'PY'
import os, pathlib
p = pathlib.Path(os.environ["MYSQL_DUMP_CNF"])
pw = os.environ["MYSQL_DUMP_PASS"].replace("\\", "\\\\").replace('"', '\\"')
p.write_text(
    "[client]\n"
    f"user={os.environ['MYSQL_DUMP_USER']}\n"
    f"password=\"{pw}\"\n"
    f"host={os.environ['MYSQL_DUMP_HOST']}\n"
    f"port={os.environ['MYSQL_DUMP_PORT']}\n"
    "protocol=tcp\n"
)
p.chmod(0o600)
PY
}

grant_site_mysql_user() {
  local dump_user="$1" password="$2" db_name="$3"
  local sql_pass
  sql_pass="$(sql_escape "${password}")"
  local_mysql -e "
    CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '${dump_user}'@'localhost' IDENTIFIED BY '${sql_pass}';
    CREATE USER IF NOT EXISTS '${dump_user}'@'127.0.0.1' IDENTIFIED BY '${sql_pass}';
    ALTER USER '${dump_user}'@'localhost' IDENTIFIED BY '${sql_pass}';
    ALTER USER '${dump_user}'@'127.0.0.1' IDENTIFIED BY '${sql_pass}';
    GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${dump_user}'@'localhost';
    GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${dump_user}'@'127.0.0.1';
    FLUSH PRIVILEGES;" 2>/dev/null || log_warn "Could not GRANT ${dump_user}"
}

# Replica-only: LXC fsync makes default InnoDB commits crawl. Relax durability
# and disable redo for the import, then restore. Never touches live MySQL.
MYSQL_IMPORT_SPEEDUP=0
MYSQL_IMPORT_SAVED_FLUSH=""
MYSQL_IMPORT_SAVED_SYNC=""
MYSQL_REDO_DISABLED=0
mysql_import_speedup_begin() {
  MYSQL_IMPORT_SAVED_FLUSH="$(local_mysql -N -e 'SELECT @@GLOBAL.innodb_flush_log_at_trx_commit' 2>/dev/null | tail -1 || true)"
  MYSQL_IMPORT_SAVED_SYNC="$(local_mysql -N -e 'SELECT @@GLOBAL.sync_binlog' 2>/dev/null | tail -1 || true)"
  [[ "${MYSQL_IMPORT_SAVED_FLUSH}" =~ ^[0-2]$ ]] || MYSQL_IMPORT_SAVED_FLUSH=1
  [[ "${MYSQL_IMPORT_SAVED_SYNC}" =~ ^[0-9]+$ ]] || MYSQL_IMPORT_SAVED_SYNC=1
  MYSQL_IMPORT_SPEEDUP=1
  MYSQL_REDO_DISABLED=0
  if local_mysql -e "SET GLOBAL innodb_flush_log_at_trx_commit=0; SET GLOBAL sync_binlog=0;" >/dev/null 2>&1; then
    log_info "Replica InnoDB flush relaxed for import"
  else
    log_warn "Could not relax InnoDB flush for import"
  fi
  local redo
  redo="$(local_mysql -N -e "ALTER INSTANCE DISABLE INNODB REDO_LOG; SHOW STATUS LIKE 'Innodb_redo_log_enabled'" 2>/dev/null | awk '{print $2}' | tail -1 || true)"
  if [[ "${redo}" == "OFF" ]]; then
    MYSQL_REDO_DISABLED=1
    log_info "Replica InnoDB redo log off for import (re-enabled after)"
  else
    log_warn "Could not disable InnoDB redo log; import may stay slow"
  fi
}

mysql_import_speedup_end() {
  [[ "${MYSQL_IMPORT_SPEEDUP}" == "1" ]] || return 0
  MYSQL_IMPORT_SPEEDUP=0
  if [[ "${MYSQL_REDO_DISABLED}" == "1" ]]; then
    MYSQL_REDO_DISABLED=0
    local redo
    redo="$(local_mysql -N -e "ALTER INSTANCE ENABLE INNODB REDO_LOG; SHOW STATUS LIKE 'Innodb_redo_log_enabled'" 2>/dev/null | awk '{print $2}' | tail -1 || true)"
    if [[ "${redo}" != "ON" ]]; then
      log_error "Failed to re-enable InnoDB redo log on replica — re-run: mysql -e \"ALTER INSTANCE ENABLE INNODB REDO_LOG\""
    fi
  fi
  local_mysql -e "SET GLOBAL innodb_flush_log_at_trx_commit=${MYSQL_IMPORT_SAVED_FLUSH:-1}; SET GLOBAL sync_binlog=${MYSQL_IMPORT_SAVED_SYNC:-1};" >/dev/null 2>&1 || true
}

# Dump from master:3306 as the site user, then mysql CLI import locally
# (password in a defaults-file so stdin is SQL — same path as phpMyAdmin).
pull_and_import_mysql() {
  local db_snap="$1"
  local site_id domain site_user db_name db_user dump_user password sql_file dump_cnf local_cnf n tables digest stamp fp meta

  mysql_import_speedup_begin

  while IFS=$'\t' read -r site_id domain site_user db_name db_user; do
    [[ -n "${db_name}" ]] || continue
    [[ ",${MYSQL_SKIP_DATABASES}," == *",${db_name},"* ]] && continue
    [[ "${db_name}" =~ ^[A-Za-z0-9_]+$ ]] || continue

    password=""
    password="$(guess_db_password "${site_user}" "${domain}" "${db_name}")" || true
    dump_user="$(guess_db_username "${site_user}" "${domain}" || true)"
    [[ -n "${dump_user}" ]] || dump_user="${db_user}"
    [[ -n "${password}" && -n "${dump_user}" ]] || die "no DB creds in .env for ${db_name}"

    dump_cnf="${CLP_SYNC_TMP_DIR}/dump-${db_name}.cnf"
    local_cnf="${CLP_SYNC_TMP_DIR}/import-${db_name}.cnf"
    sql_file="${CLP_SYNC_TMP_DIR}/${db_name}.sql"
    write_client_cnf "${dump_cnf}" "${dump_user}" "${password}" "${MASTER_HOST}" "${MYSQL_DUMP_PORT}"
    write_client_cnf "${local_cnf}" "${dump_user}" "${password}" "127.0.0.1" "3306"
    grant_site_mysql_user "${dump_user}" "${password}" "${db_name}"

    stamp="${CLP_SYNC_STATE_DIR}/mysql-${db_name}.sha256"
    meta="${CLP_SYNC_STATE_DIR}/mysql-${db_name}.meta"
    fp=""
    fp="$(mysql --defaults-file="${dump_cnf}" --connect-timeout=8 --batch --skip-column-names -N -e \
      "SELECT table_name, IFNULL(ENGINE,''), IFNULL(TABLE_ROWS,0), IFNULL(DATA_LENGTH,0), IFNULL(INDEX_LENGTH,0), IFNULL(DATA_FREE,0), IFNULL(AUTO_INCREMENT,0), IFNULL(UNIX_TIMESTAMP(UPDATE_TIME),0) FROM information_schema.tables WHERE table_schema='${db_name}' AND table_type='BASE TABLE' ORDER BY table_name" \
      2>/dev/null | sha256sum | awk '{print $1}')" || true
    if [[ "${MYSQL_SKIP_UNCHANGED}" == "1" && -n "${fp}" && "${fp}" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" && -f "${meta}" && "$(cat "${meta}")" == "${fp}" ]]; then
      log_info "Skipping dump+import ${db_name} (unchanged)"
      INC_MYSQL_SKIP=$((INC_MYSQL_SKIP + 1))
      rm -f "${dump_cnf}" "${local_cnf}"
      continue
    fi

    log_info "Dumping ${db_name} from ${MASTER_HOST}:${MYSQL_DUMP_PORT} as ${dump_user}"
    rm -f "${sql_file}"
    if ! mysqldump --defaults-file="${dump_cnf}" --single-transaction --quick \
      --routines --triggers --skip-dump-date --set-gtid-purged=OFF \
      --default-character-set=utf8mb4 --no-tablespaces "${db_name}" >"${sql_file}"; then
      rm -f "${dump_cnf}" "${local_cnf}" "${sql_file}"
      die "mysqldump failed for ${db_name}"
    fi
    rm -f "${dump_cnf}"
    [[ -s "${sql_file}" ]] || die "empty dump ${db_name}"
    sed -i '/sandbox mode/d;/^SET @@GLOBAL.GTID_PURGED/d' "${sql_file}" || true
    n="$(wc -c <"${sql_file}")"
    digest="$(sha256_file "${sql_file}")"
    stamp="${CLP_SYNC_STATE_DIR}/mysql-${db_name}.sha256"
    if [[ "${MYSQL_SKIP_UNCHANGED}" == "1" && -f "${stamp}" && "$(cat "${stamp}")" == "${digest}" ]]; then
      log_info "Skipping import ${db_name} (dump unchanged, ${n} bytes)"
      INC_MYSQL_SKIP=$((INC_MYSQL_SKIP + 1))
      [[ -n "${fp}" ]] && printf '%s\n' "${fp}" >"${meta}"
      rm -f "${local_cnf}" "${sql_file}"
      continue
    fi
    log_info "Loading ${db_name} locally (${n} bytes, mysql CLI)"
    if ! {
      printf '%s\n' 'SET SESSION sql_log_bin=0; SET SESSION unique_checks=0; SET SESSION foreign_key_checks=0; SET SESSION autocommit=0;'
      cat "${sql_file}"
      printf '%s\n' 'COMMIT;'
    } | local_mysql "${db_name}"; then
      rm -f "${local_cnf}" "${sql_file}"
      die "import failed for ${db_name}"
    fi
    tables="$(mysql --defaults-file="${local_cnf}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db_name}'" 2>/dev/null || echo '?')"
    printf '%s\n' "${digest}" >"${stamp}"
    chmod 600 "${stamp}"
    if [[ -n "${fp}" ]]; then
      printf '%s\n' "${fp}" >"${meta}"
      chmod 600 "${meta}"
    fi
    rm -f "${local_cnf}" "${sql_file}"
    log_ok "${db_name}: ok tables=${tables}"
    INC_MYSQL_IMPORT=$((INC_MYSQL_IMPORT + 1))
  done < <(inventory_databases "${db_snap}")
  mysql_import_speedup_end
  log_ok "MySQL clone complete"
}
