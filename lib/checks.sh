#!/usr/bin/env bash
# Compatibility and preflight checks for clp-sync.
# Can run locally, against standby over SSH, and compare both hosts.

set -euo pipefail

# Counters (caller may reset with checks_reset)
CHECK_ERRORS=0
CHECK_WARNINGS=0

checks_reset() {
  CHECK_ERRORS=0
  CHECK_WARNINGS=0
}

_check_pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
_check_fail() { CHECK_ERRORS=$((CHECK_ERRORS + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2; }
_check_warn() { CHECK_WARNINGS=$((CHECK_WARNINGS + 1)); printf '  \033[1;33mWARN\033[0m %s\n' "$*"; }

checks_summary() {
  echo
  echo "Check summary: ${CHECK_ERRORS} error(s), ${CHECK_WARNINGS} warning(s)"
  [[ "${CHECK_ERRORS}" -eq 0 ]]
}

# Emit host profile as KEY=value (machine-readable)
collect_host_profile() {
  local role="${1:-unknown}"
  local clp_ver php_list nginx mysql disk_avail disk_used home_used site_count arch os_id

  arch="$(uname -m)"
  os_id="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-unknown}-${VERSION_ID:-unknown}"
  fi

  clp_ver="unknown"
  if command -v clpctl >/dev/null 2>&1; then
    clp_ver="$(clpctl --version 2>/dev/null | head -1 | tr -d '\r' || true)"
    [[ -z "${clp_ver}" ]] && clp_ver="$(clpctl 2>&1 | head -1 | tr -d '\r' || true)"
  fi
  if [[ "${clp_ver}" == "unknown" ]] && dpkg -l cloudpanel 2>/dev/null | grep -q '^ii'; then
    clp_ver="$(dpkg -l cloudpanel 2>/dev/null | awk '/^ii/ {print $3}')"
  fi

  php_list=""
  if [[ -d /etc/php ]]; then
    php_list="$(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -u | paste -sd, - || true)"
  fi

  nginx="missing"
  if systemctl is-active nginx >/dev/null 2>&1 || systemctl is-active cloudpanel-nginx >/dev/null 2>&1; then
    nginx="active"
  elif command -v nginx >/dev/null 2>&1; then
    nginx="installed"
  fi

  mysql="missing"
  if systemctl is-active mysql >/dev/null 2>&1 || systemctl is-active mariadb >/dev/null 2>&1; then
    mysql="active"
  elif command -v mysql >/dev/null 2>&1; then
    mysql="installed"
  fi

  disk_avail="$(df -Pk /home 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  disk_used="$(df -Pk /home 2>/dev/null | awk 'NR==2 {print $3}' || echo 0)"
  home_used="$(du -sk /home 2>/dev/null | awk '{print $1}' || echo 0)"

  site_count="0"
  if [[ -f /home/clp/htdocs/app/data/db.sq3 ]]; then
    site_count="$(sqlite3 /home/clp/htdocs/app/data/db.sq3 'SELECT COUNT(*) FROM site;' 2>/dev/null || echo 0)"
  fi

  local ts_ip ts_name
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  ts_name="$(hostname -f 2>/dev/null || hostname)"

  cat <<EOF
ROLE=${role}
HOSTNAME=${ts_name}
ARCH=${arch}
OS=${os_id}
TAILSCALE_IP=${ts_ip}
CLP_VERSION=${clp_ver}
PHP_VERSIONS=${php_list}
NGINX=${nginx}
MYSQL=${mysql}
DISK_HOME_AVAIL_KB=${disk_avail}
DISK_HOME_USED_KB=${disk_used}
HOME_USED_KB=${home_used}
SITE_COUNT=${site_count}
HAS_CLPCTL=$(command -v clpctl >/dev/null 2>&1 && echo yes || echo no)
HAS_DB=$(test -f /home/clp/htdocs/app/data/db.sq3 && echo yes || echo no)
HAS_RSYNC=$(command -v rsync >/dev/null 2>&1 && echo yes || echo no)
HAS_SQLITE3=$(command -v sqlite3 >/dev/null 2>&1 && echo yes || echo no)
HAS_PYTHON3=$(command -v python3 >/dev/null 2>&1 && echo yes || echo no)
HAS_MYSQLDUMP=$(command -v mysqldump >/dev/null 2>&1 && echo yes || echo no)
HAS_FLOCK=$(command -v flock >/dev/null 2>&1 && echo yes || echo no)
EOF
}

profile_get() {
  local profile="$1" key="$2"
  grep -E "^${key}=" <<<"${profile}" | head -1 | cut -d= -f2- || true
}

# --- Local checks -----------------------------------------------------------

check_local_os() {
  local os_id=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
  fi
  case "${os_id}" in
    ubuntu|debian) _check_pass "OS supported: ${PRETTY_NAME:-${os_id}}" ;;
    *) _check_warn "OS may be unsupported (CloudPanel targets Ubuntu/Debian): ${os_id:-unknown}" ;;
  esac
}

check_local_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|aarch64|arm64) _check_pass "Architecture: ${arch}" ;;
    *) _check_fail "Unsupported architecture: ${arch}" ;;
  esac
}

check_local_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    _check_fail "Tailscale not installed"
    return
  fi
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -z "${ip}" ]]; then
    _check_fail "Tailscale not connected (run: tailscale up)"
    return
  fi
  _check_pass "Tailscale connected: ${ip}"
}

check_local_cloudpanel() {
  local role="$1"
  if command -v clpctl >/dev/null 2>&1 && [[ -f /home/clp/htdocs/app/data/db.sq3 ]]; then
    _check_pass "CloudPanel installed (clpctl + db.sq3)"
  elif [[ "${role}" == "standby" ]]; then
    _check_warn "CloudPanel not fully detected on standby — install CloudPanel before first sync"
  else
    _check_fail "CloudPanel not found on master (need clpctl and db.sq3)"
  fi
}

check_local_services() {
  local role="$1"
  if systemctl is-active nginx >/dev/null 2>&1 || systemctl is-active cloudpanel-nginx >/dev/null 2>&1; then
    _check_pass "nginx running"
  elif [[ "${role}" == "master" ]]; then
    _check_fail "nginx not running on master"
  else
    _check_warn "nginx not running on standby (will be needed after sync)"
  fi

  if systemctl is-active mysql >/dev/null 2>&1 || systemctl is-active mariadb >/dev/null 2>&1; then
    _check_pass "MySQL/MariaDB running"
  elif [[ "${role}" == "master" ]]; then
    _check_fail "MySQL/MariaDB not running on master"
  else
    _check_warn "MySQL/MariaDB not running on standby"
  fi
}

check_local_tools() {
  local role="$1"
  local tool missing=()
  for tool in rsync sqlite3 openssl python3 flock; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  if [[ "${role}" == "master" ]]; then
    command -v mysqldump >/dev/null 2>&1 || missing+=("mysqldump")
    command -v ssh >/dev/null 2>&1 || missing+=("ssh")
  fi
  if [[ "${role}" == "standby" ]]; then
    if command -v sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
      :
    else
      missing+=("sshd/ssh-server")
    fi
  fi
  if ((${#missing[@]})); then
    _check_fail "Missing tools: ${missing[*]}"
  else
    _check_pass "Required tools present"
  fi
}

check_local_disk() {
  local role="$1"
  local avail_kb used_kb
  avail_kb="$(df -Pk /home 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  used_kb="$(du -sk /home 2>/dev/null | awk '{print $1}' || echo 0)"
  if [[ "${avail_kb}" -lt 1048576 ]]; then
    _check_warn "/home free space low: $(( avail_kb / 1024 )) MB"
  else
    _check_pass "/home free: $(( avail_kb / 1024 )) MB"
  fi
  if [[ "${role}" == "master" && "${used_kb}" -gt 0 ]]; then
    _check_pass "Master /home data: $(( used_kb / 1024 )) MB (standby needs at least this much free)"
  fi
}

check_local_sync_paths() {
  local role="$1"
  if [[ "${role}" != "master" ]]; then
    return 0
  fi
  for d in /var/lib/clp-sync /var/tmp/clp-sync /var/log/clp-sync; do
    mkdir -p "${d}" 2>/dev/null || true
    if [[ -w "${d}" ]]; then
      _check_pass "Writable sync path: ${d}"
    else
      _check_fail "Not writable: ${d}"
    fi
  done
}

run_local_preflight() {
  local role="$1"
  echo "=== Local preflight (${role}) ==="
  check_local_os
  check_local_arch
  check_local_tailscale
  check_local_cloudpanel "${role}"
  check_local_services "${role}"
  check_local_tools "${role}"
  check_local_disk "${role}"
  check_local_sync_paths "${role}"
  checks_summary
}

# --- Cross-host compatibility (master only, needs SSH) ----------------------

compare_profiles() {
  local master_profile="$1"
  local standby_profile="$2"

  echo "=== Cross-host compatibility ==="

  local m_host s_host m_ip s_ip m_arch s_arch m_os s_os m_clp s_clp
  m_host="$(profile_get "${master_profile}" HOSTNAME)"
  s_host="$(profile_get "${standby_profile}" HOSTNAME)"
  m_ip="$(profile_get "${master_profile}" TAILSCALE_IP)"
  s_ip="$(profile_get "${standby_profile}" TAILSCALE_IP)"

  if [[ -n "${m_ip}" && "${m_ip}" == "${s_ip}" ]]; then
    _check_fail "Master and standby appear to be the same Tailscale host (${m_ip})"
  else
    _check_pass "Distinct hosts: master=${m_host} standby=${s_host}"
  fi

  m_arch="$(profile_get "${master_profile}" ARCH)"
  s_arch="$(profile_get "${standby_profile}" ARCH)"
  if [[ "${m_arch}" == "${s_arch}" ]]; then
    _check_pass "Matching architecture: ${m_arch}"
  else
    _check_fail "Architecture mismatch: master=${m_arch} standby=${s_arch}"
  fi

  m_os="$(profile_get "${master_profile}" OS)"
  s_os="$(profile_get "${standby_profile}" OS)"
  if [[ "${m_os}" == "${s_os}" ]]; then
    _check_pass "Matching OS: ${m_os}"
  else
    _check_warn "OS differs: master=${m_os} standby=${s_os} (prefer same Ubuntu LTS)"
  fi

  m_clp="$(profile_get "${master_profile}" CLP_VERSION)"
  s_clp="$(profile_get "${standby_profile}" CLP_VERSION)"
  if [[ "${m_clp}" != "unknown" && "${s_clp}" != "unknown" ]]; then
    if [[ "${m_clp}" == "${s_clp}" ]]; then
      _check_pass "CloudPanel version match: ${m_clp}"
    else
      # Compare major-ish token
      local m_major s_major
      m_major="$(echo "${m_clp}" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "${m_clp}")"
      s_major="$(echo "${s_clp}" | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "${s_clp}")"
      if [[ "${m_major}" == "${s_major}" ]]; then
        _check_warn "CloudPanel versions differ slightly: master='${m_clp}' standby='${s_clp}'"
      else
        _check_fail "CloudPanel version mismatch: master='${m_clp}' standby='${s_clp}'"
      fi
    fi
  else
    _check_warn "Could not verify CloudPanel version on both hosts"
  fi

  # PHP versions required by master sites vs standby installed
  local master_php_needed standby_php
  if [[ -f /home/clp/htdocs/app/data/db.sq3 ]]; then
    master_php_needed="$(sqlite3 /home/clp/htdocs/app/data/db.sq3 \
      "SELECT DISTINCT php_version FROM php_settings WHERE php_version IS NOT NULL AND php_version != '' ORDER BY php_version;" 2>/dev/null \
      | paste -sd, - || true)"
  fi
  standby_php="$(profile_get "${standby_profile}" PHP_VERSIONS)"

  if [[ -n "${master_php_needed}" ]]; then
    local ver missing=()
    IFS=',' read -r -a need <<<"${master_php_needed}"
    for ver in "${need[@]}"; do
      [[ -z "${ver}" ]] && continue
      if [[ ",${standby_php}," != *",${ver},"* ]]; then
        missing+=("${ver}")
      fi
    done
    if ((${#missing[@]})); then
      _check_fail "Standby missing PHP versions used on master: ${missing[*]} (install via CloudPanel)"
    else
      _check_pass "Standby has all master PHP versions: ${master_php_needed}"
    fi
  fi

  # Disk: standby /home free >= master /home used
  local m_used s_avail
  m_used="$(profile_get "${master_profile}" HOME_USED_KB)"
  s_avail="$(profile_get "${standby_profile}" DISK_HOME_AVAIL_KB)"
  if [[ "${m_used}" =~ ^[0-9]+$ && "${s_avail}" =~ ^[0-9]+$ ]]; then
    local buffer=$(( m_used + m_used / 10 + 524288 ))  # +10% +512MB
    if [[ "${s_avail}" -ge "${buffer}" ]]; then
      _check_pass "Standby disk OK: $(( s_avail / 1024 )) MB free vs $(( m_used / 1024 )) MB master data"
    else
      _check_fail "Standby /home too small: need ~$(( buffer / 1024 )) MB free, have $(( s_avail / 1024 )) MB"
    fi
  else
    _check_warn "Could not compare disk usage"
  fi

  # Standby services
  if [[ "$(profile_get "${standby_profile}" NGINX)" == "active" ]]; then
    _check_pass "Standby nginx active"
  else
    _check_warn "Standby nginx not active"
  fi
  if [[ "$(profile_get "${standby_profile}" MYSQL)" == "active" ]]; then
    _check_pass "Standby MySQL/MariaDB active"
  else
    _check_fail "Standby MySQL/MariaDB not active"
  fi

  if [[ "$(profile_get "${standby_profile}" HAS_CLPCTL)" == "yes" && "$(profile_get "${standby_profile}" HAS_DB)" == "yes" ]]; then
    _check_pass "Standby CloudPanel ready"
  else
    _check_fail "Standby missing CloudPanel (clpctl or db.sq3)"
  fi

  for tool in HAS_RSYNC HAS_SQLITE3 HAS_PYTHON3; do
    if [[ "$(profile_get "${standby_profile}" "${tool}")" != "yes" ]]; then
      _check_fail "Standby missing ${tool#HAS_}"
    fi
  done
  _check_pass "Standby receiver tools OK"

  checks_summary
}

# Run full compatibility when common.sh remote() is available
run_peer_compatibility() {
  local role="${1:-master}"
  [[ "${role}" == "master" ]] || return 0

  if ! declare -F remote >/dev/null 2>&1; then
    _check_warn "SSH remote() not available — skipping peer checks"
    return 0
  fi

  local master_profile standby_profile
  master_profile="$(collect_host_profile master)"
  if ! standby_profile="$(remote "bash -s" <<'EOS'
set -euo pipefail
# Minimal inline profile collector on standby
arch=$(uname -m)
os_id=unknown
[[ -f /etc/os-release ]] && source /etc/os-release && os_id="${ID:-unknown}-${VERSION_ID:-unknown}"
clp_ver=unknown
command -v clpctl >/dev/null && clp_ver=$(clpctl --version 2>/dev/null | head -1 || echo unknown)
php_list=""
[[ -d /etc/php ]] && php_list=$(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | paste -sd, - || true)
nginx=missing; systemctl is-active nginx >/dev/null 2>&1 && nginx=active
mysql=missing; systemctl is-active mysql >/dev/null 2>&1 || systemctl is-active mariadb >/dev/null 2>&1 && mysql=active
disk_avail=$(df -Pk /home 2>/dev/null | awk 'NR==2 {print $4}')
home_used=$(du -sk /home 2>/dev/null | awk '{print $1}')
ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || true)
echo "ROLE=standby"
echo "HOSTNAME=$(hostname -f 2>/dev/null || hostname)"
echo "ARCH=${arch}"
echo "OS=${os_id}"
echo "TAILSCALE_IP=${ts_ip}"
echo "CLP_VERSION=${clp_ver}"
echo "PHP_VERSIONS=${php_list}"
echo "NGINX=${nginx}"
echo "MYSQL=${mysql}"
echo "DISK_HOME_AVAIL_KB=${disk_avail:-0}"
echo "HOME_USED_KB=${home_used:-0}"
echo "HAS_CLPCTL=$(command -v clpctl >/dev/null && echo yes || echo no)"
echo "HAS_DB=$(test -f /home/clp/htdocs/app/data/db.sq3 && echo yes || echo no)"
echo "HAS_RSYNC=$(command -v rsync >/dev/null && echo yes || echo no)"
echo "HAS_SQLITE3=$(command -v sqlite3 >/dev/null && echo yes || echo no)"
echo "HAS_PYTHON3=$(command -v python3 >/dev/null && echo yes || echo no)"
EOS
)"; then
    _check_fail "Could not collect standby profile over SSH"
    checks_summary
    return 1
  fi

  compare_profiles "${master_profile}" "${standby_profile}"
}

# Lighter check before each sync run
run_sync_preflight() {
  checks_reset
  echo "=== Sync preflight ==="
  check_local_tailscale
  check_local_tools master
  if ! remote "echo ok && command -v clpctl && command -v rsync && command -v sqlite3 &&
    (systemctl is-active nginx >/dev/null 2>&1 || systemctl is-active cloudpanel-nginx >/dev/null 2>&1) &&
    (systemctl is-active mysql >/dev/null 2>&1 || systemctl is-active mariadb >/dev/null 2>&1)"; then
    _check_fail "Standby not reachable or services/tools missing"
    checks_summary
    return 1
  fi
  _check_pass "Standby SSH + services OK"

  # Quick disk sanity
  local m_used s_avail
  m_used="$(du -sk /home 2>/dev/null | awk '{print $1}' || echo 0)"
  s_avail="$(remote "df -Pk /home | awk 'NR==2 {print \$4}'" 2>/dev/null || echo 0)"
  if [[ "${m_used}" =~ ^[0-9]+$ && "${s_avail}" =~ ^[0-9]+$ && "${s_avail}" -lt "${m_used}" ]]; then
    _check_fail "Standby /home may be too full ($(( s_avail/1024 )) MB free, ~$(( m_used/1024 )) MB needed)"
  else
    _check_pass "Standby disk looks sufficient"
  fi

  checks_summary
}
