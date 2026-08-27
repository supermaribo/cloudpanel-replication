#!/usr/bin/env bash
# Shared helpers for clp-sync. Sourced by bin/* scripts.
# shellcheck disable=SC2034

set -euo pipefail

CLP_SYNC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(date -u +'%Y-%m-%dT%H:%M:%SZ') [${level}] ${msg}"
  echo "${line}"
  if [[ -n "${CLP_SYNC_LOG_FILE:-}" ]]; then
    echo "${line}" >>"${CLP_SYNC_LOG_FILE}"
  fi
}

log_info()  { log INFO "$*"; }
log_warn()  { log WARN "$*"; }
log_error() { log ERROR "$*"; }
log_ok()    { log OK "$*"; }

die() {
  log_error "$*"
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Must run as root"
}

load_config() {
  local cfg="${CLP_SYNC_CONFIG:-/etc/clp-sync/config.env}"
  if [[ ! -f "${cfg}" ]]; then
    # Dev / repo-relative fallback
    if [[ -f "${CLP_SYNC_ROOT}/config.env" ]]; then
      cfg="${CLP_SYNC_ROOT}/config.env"
    else
      die "Config not found: ${cfg} (copy config.example.env)"
    fi
  fi
  # shellcheck disable=SC1090
  set -a; source "${cfg}"; set +a

  : "${ROLE:=standby}"
  : "${MASTER_HOST:=${PRIMARY_HOST:-}}"
  : "${MASTER_SSH_USER:=root}"
  : "${MASTER_SSH_PORT:=22}"
  : "${MASTER_SSH_KEY:=/root/.ssh/clp_sync_ed25519}"
  : "${STANDBY_SSH_USER:=root}"
  : "${STANDBY_SSH_PORT:=22}"
  : "${CLP_DB_PATH:=/home/clp/htdocs/app/data/db.sq3}"
  : "${CLP_SYNC_STATE_DIR:=/var/lib/clp-sync}"
  : "${CLP_SYNC_TMP_DIR:=/var/tmp/clp-sync}"
  : "${CLP_SYNC_LOG_DIR:=/var/log/clp-sync}"
  : "${RSYNC_EXCLUDES_FILE:=${CLP_SYNC_ROOT}/excludes/rsync-excludes.txt}"
  : "${BOOTSTRAP_SITE_TYPES:=php,nodejs,python,static,reverse-proxy}"
  : "${INCREMENTAL:=1}"
  : "${MYSQL_SKIP_UNCHANGED:=1}"
  : "${MYSQL_SKIP_DATABASES:=information_schema,performance_schema,sys,mysql}"
  : "${RELOAD_NGINX_ON_STANDBY:=1}"
  : "${APPLY_PANEL_DB:=1}"
  : "${SYNC_EXTRA_USERS:=clp}"
  : "${FAIL_NOTIFY_CMD:=}"
  : "${PRIMARY_HOST:=}"
  : "${STANDBY_HOST:=}"
  : "${SYNC_ENABLED:=1}"
  : "${SYNC_AUTO:=0}"
  : "${PROMOTED:=0}"
  : "${FORMER_PRIMARY_HOST:=}"
  : "${PROMOTED_AT:=}"

  if [[ "${ROLE}" == "standby" && "${SYNC_ENABLED}" == "1" && -z "${MASTER_HOST}" ]]; then
    die "MASTER_HOST required for ROLE=standby (the live CloudPanel to pull from)"
  fi

  mkdir -p "${CLP_SYNC_STATE_DIR}" "${CLP_SYNC_TMP_DIR}" "${CLP_SYNC_LOG_DIR}"
  chmod 700 "${CLP_SYNC_STATE_DIR}" "${CLP_SYNC_TMP_DIR}"
}

ssh_opts() {
  local port="${MASTER_SSH_PORT:-${STANDBY_SSH_PORT:-22}}"
  local key="${MASTER_SSH_KEY:-${STANDBY_SSH_KEY:-}}"
  SSH_OPTS=(-p "${port}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  if [[ -n "${key}" && -f "${key}" ]]; then
    SSH_OPTS+=(-i "${key}")
  fi
}

master_target() {
  echo "${MASTER_SSH_USER}@${MASTER_HOST}"
}

# SSH to the live master (restricted key). One arg = remote command string.
master_ssh() {
  local SSH_OPTS
  ssh_opts
  ssh "${SSH_OPTS[@]}" "$(master_target)" "$1"
}

rsync_ssh_cmd() {
  local port="${MASTER_SSH_PORT:-22}"
  local key="${MASTER_SSH_KEY:-/root/.ssh/clp_sync_ed25519}"
  local cmd="ssh -p ${port} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
  if [[ -n "${key}" && -f "${key}" ]]; then
    cmd+=" -i ${key}"
  fi
  echo "${cmd}"
}

# Pull path from master → local dest. Extra rsync args after dest.
rsync_from_master() {
  local src="$1"
  local dest="$2"
  shift 2
  local rsync_ssh item_log n rc=0
  rsync_ssh="$(rsync_ssh_cmd)"
  item_log="${CLP_SYNC_TMP_DIR}/rsync-item.$$"
  mkdir -p "${CLP_SYNC_TMP_DIR}" "$(dirname "${dest}")"
  RSYNC_CHANGED=0

  rsync -aHAX --delete --omit-dir-times \
    --out-format='%i %n%L' \
    -e "${rsync_ssh}" \
    "$@" \
    "$(master_target):${src}" "${dest}" >"${item_log}" || rc=$?

  if [[ "${rc}" -ne 0 ]]; then
    rm -f "${item_log}"
    log_error "rsync pull failed (rc=${rc}): ${src} → ${dest}"
    return 1
  fi

  n="$(grep -cE '^[<>c*h]|^\.[fL]' "${item_log}" 2>/dev/null || true)"
  n="${n:-0}"
  rm -f "${item_log}"
  if [[ "${n}" -gt 0 ]]; then
    INC_FILE_CHANGES=$((INC_FILE_CHANGES + n))
    RSYNC_CHANGED=1
    log_info "pull ${src} (${n} change(s))"
    return 0
  fi
  INC_SKIPPED=$((INC_SKIPPED + 1))
  log_info "pull ${src}: unchanged"
  return 0
}

write_status() {
  local status="$1"
  local detail="${2:-}"
  local f="${CLP_SYNC_STATE_DIR}/last-status"
  {
    echo "status=${status}"
    echo "finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo "master=${MASTER_HOST}"
    [[ -n "${detail}" ]] && echo "detail=${detail}"
  } >"${f}"
  chmod 600 "${f}"
}

# shellcheck source=incremental.sh
source "${CLP_SYNC_ROOT}/lib/incremental.sh"

require_cmds() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  ((${#missing[@]} == 0)) || die "Missing commands: ${missing[*]}"
}

notify_failure() {
  local reason="${1:-unknown}"
  if [[ -n "${FAIL_NOTIFY_CMD}" ]]; then
    # shellcheck disable=SC2086
    eval ${FAIL_NOTIFY_CMD} || true
  fi
  log_error "Sync failed: ${reason}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

site_type_allowed() {
  local t="$1"
  [[ ",${BOOTSTRAP_SITE_TYPES}," == *",${t},"* ]]
}
