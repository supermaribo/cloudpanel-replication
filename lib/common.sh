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
  [[ "$(id -u)" -eq 0 ]] || die "Must run as root on the primary server"
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

  : "${ROLE:=master}"
  : "${STANDBY_SSH_USER:=root}"
  : "${STANDBY_SSH_PORT:=22}"
  : "${CLP_DB_PATH:=/home/clp/htdocs/app/data/db.sq3}"
  : "${CLP_SYNC_STATE_DIR:=/var/lib/clp-sync}"
  : "${CLP_SYNC_TMP_DIR:=/var/tmp/clp-sync}"
  : "${CLP_SYNC_LOG_DIR:=/var/log/clp-sync}"
  : "${RSYNC_EXCLUDES_FILE:=${CLP_SYNC_ROOT}/excludes/rsync-excludes.txt}"
  : "${BOOTSTRAP_SITE_TYPES:=php,nodejs,python,static,reverse-proxy}"
  : "${MYSQL_SKIP_UNCHANGED:=1}"
  : "${MYSQL_SKIP_DATABASES:=information_schema,performance_schema,sys,mysql}"
  : "${RELOAD_NGINX_ON_STANDBY:=1}"
  : "${APPLY_PANEL_DB:=1}"
  : "${SYNC_EXTRA_USERS:=clp}"
  : "${FAIL_NOTIFY_CMD:=}"
  : "${PRIMARY_HOST:=}"
  : "${STANDBY_HOST:=}"
  : "${SYNC_ENABLED:=1}"
  : "${PROMOTED:=0}"
  : "${FORMER_PRIMARY_HOST:=}"
  : "${PROMOTED_AT:=}"

  if [[ "${ROLE}" == "standby" ]]; then
    : # standby does not need STANDBY_HOST
  elif [[ "${ROLE}" == "master" && "${SYNC_ENABLED}" == "1" && -z "${STANDBY_HOST}" ]]; then
    die "STANDBY_HOST required for ROLE=master with SYNC_ENABLED=1 (or run clp-set-standby / clp-sync-control off)"
  fi

  mkdir -p "${CLP_SYNC_STATE_DIR}" "${CLP_SYNC_TMP_DIR}" "${CLP_SYNC_LOG_DIR}"
  chmod 700 "${CLP_SYNC_STATE_DIR}" "${CLP_SYNC_TMP_DIR}"
}

ssh_opts() {
  SSH_OPTS=(-p "${STANDBY_SSH_PORT}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  if [[ -n "${STANDBY_SSH_KEY:-}" ]]; then
    SSH_OPTS+=(-i "${STANDBY_SSH_KEY}")
  fi
}

standby_target() {
  echo "${STANDBY_SSH_USER}@${STANDBY_HOST}"
}

# Quote one argument for the remote bash -c string (spaces, (), $, quotes).
ssh_quote() {
  printf '%q' "$1"
}

# Run a command on the standby.
# One argument  = remote shell snippet (may contain &&, quotes, redirects).
# Several args  = argv (each token is quoted so spaces/() in vhost templates
#                 and passwords cannot break the remote shell).
remote() {
  local SSH_OPTS remote_cmd="" arg
  ssh_opts
  if [[ $# -eq 1 ]]; then
    ssh "${SSH_OPTS[@]}" "$(standby_target)" "$1"
    return
  fi
  for arg in "$@"; do
    remote_cmd+="$(ssh_quote "${arg}") "
  done
  ssh "${SSH_OPTS[@]}" "$(standby_target)" "${remote_cmd}"
}

remote_bash() {
  remote bash -s
}

rsync_ssh_cmd() {
  local cmd="ssh -p ${STANDBY_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
  if [[ -n "${STANDBY_SSH_KEY:-}" ]]; then
    cmd+=" -i ${STANDBY_SSH_KEY}"
  fi
  echo "${cmd}"
}

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

# Returns 0 if type is in BOOTSTRAP_SITE_TYPES
site_type_allowed() {
  local t="$1"
  [[ ",${BOOTSTRAP_SITE_TYPES}," == *",${t},"* ]]
}

write_status() {
  local status="$1"
  local detail="${2:-}"
  local f="${CLP_SYNC_STATE_DIR}/last-status"
  {
    echo "status=${status}"
    echo "finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo "standby=${STANDBY_HOST}"
    [[ -n "${detail}" ]] && echo "detail=${detail}"
  } >"${f}"
  chmod 600 "${f}"
}
