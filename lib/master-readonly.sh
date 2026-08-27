#!/usr/bin/env bash
# Master read-only guarantee — install and sync must never modify CloudPanel on the master.

# Paths that must NEVER be written by clp-sync on the master (except read/copy source).
readonly CLP_PROTECTED_PREFIXES=(
  /home/clp/htdocs
  /home/*/htdocs
  /etc/nginx
  /etc/mysql
  /etc/php
  /var/lib/mysql
  /usr/share/cloudpanel
  /tmp/cloudpanel
)

master_install_allowed_paths() {
  cat <<'EOF'
/opt/clp-sync/
/etc/clp-sync/
/var/lib/clp-sync/
/var/log/clp-sync/
/var/tmp/clp-sync/
/etc/systemd/system/clp-sync.service
/etc/systemd/system/clp-sync.timer
/root/.ssh/clp_sync_ed25519
/root/.ssh/clp_sync_ed25519.pub
/root/clp-sync-src/
EOF
}

print_master_readonly_policy() {
  c_info "MASTER POLICY: zero changes to CloudPanel"
  echo "  This installer will NOT run apt-get on the master."
  echo "  It will NOT run clpctl, systemctl, or modify nginx/MySQL/PHP/sites on the master."
  echo "  Only adds: /opt/clp-sync, /etc/clp-sync, sync logs/state, SSH key, systemd timer."
  echo "  Sync reads your sites/DBs; all writes go to the standby over SSH."
}

# Verify required read tools exist — never install packages on master.
verify_master_tools() {
  local missing=()
  local p

  print_master_readonly_policy
  c_info "Verifying read-only tools on master (no apt-get)"

  for p in rsync sqlite3 openssl ssh flock python3; do
    command -v "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done
  if ! has_mysqldump; then
    missing+=("mysqldump")
  fi

  if ((${#missing[@]})); then
    c_err "Missing tools on master: ${missing[*]}"
    echo "  Install these manually WITHOUT touching Percona/MySQL packages."
    echo "  CloudPanel already includes mysqldump — if missing, repair CloudPanel, do NOT apt install mysql-client."
    echo "  Example (only if CloudPanel support advises): apt install rsync sqlite3 util-linux"
    return 1
  fi

  c_ok "All sync tools present — CloudPanel stack untouched"
  return 0
}

# Verify standby receiver tools — never apt-get (standby CloudPanel equally fragile).
verify_standby_tools() {
  local missing=()
  local p

  c_info "Verifying tools on standby (no apt-get — install manually if missing)"

  for p in rsync sqlite3 openssl python3 ssh; do
    command -v "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done
  if ! command -v sshd >/dev/null 2>&1 && ! systemctl is-active ssh >/dev/null 2>&1 && ! systemctl is-active sshd >/dev/null 2>&1; then
    missing+=("sshd/openssh-server")
  fi

  if ((${#missing[@]})); then
    c_err "Missing on standby: ${missing[*]}"
    echo "  Install manually on standby before continuing, e.g.:"
    echo "    apt install rsync sqlite3 openssl python3 openssh-server"
    return 1
  fi

  c_ok "Standby tools present"
  return 0
}

fetch_repo_no_apt() {
  local repo_url="$1" install_dir="$2" branch="$3"
  local tarball="https://github.com/supermaribo/cloudpanel-replication/archive/refs/heads/${branch}.tar.gz"
  local tmp
  tmp="$(mktemp /var/tmp/clp-sync-dl.XXXXXX.tgz)"

  if [[ -d "${install_dir}/.git" ]] && command -v git >/dev/null 2>&1; then
    c_info "Updating git clone at ${install_dir}"
    git -C "${install_dir}" fetch origin "${branch}"
    git -C "${install_dir}" checkout "${branch}" 2>/dev/null || true
    git -C "${install_dir}" pull origin "${branch}" || true
    return 0
  fi

  if command -v git >/dev/null 2>&1 && [[ ! -d "${install_dir}" ]]; then
    c_info "Cloning ${repo_url} → ${install_dir}"
    git clone --branch "${branch}" --depth 1 "${repo_url}" "${install_dir}"
    return 0
  fi

  c_info "Downloading release tarball (no git, no apt)"
  command -v curl >/dev/null 2>&1 || { c_err "curl required"; return 1; }
  command -v tar >/dev/null 2>&1 || { c_err "tar required"; return 1; }
  curl -fsSL "${tarball}" -o "${tmp}"
  rm -rf "${install_dir}"
  mkdir -p "${install_dir}"
  tar xzf "${tmp}" -C "${install_dir}" --strip-components=1
  rm -f "${tmp}"
  c_ok "Extracted to ${install_dir}"
}
