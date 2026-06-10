# shellcheck shell=bash
# lib/apt.sh — robust apt wrappers: lock handling, dpkg repair, idempotent
# installs, repo + GPG key management.
[[ -n "${_APT_SH_LOADED:-}" ]] && return 0
_APT_SH_LOADED=1

export DEBIAN_FRONTEND=noninteractive
_APT_UPDATED=0   # cache: run `apt-get update` at most once per invocation

# apt_wait_locks [TIMEOUT_S] — wait for dpkg/apt locks, naming the holder.
apt_wait_locks() {
  local timeout="${1:-180}" waited=0
  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
               /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  while :; do
    local held="" l
    for l in "${locks[@]}"; do
      [[ -e "$l" ]] || continue
      if fuser "$l" >/dev/null 2>&1; then held="$l"; break; fi
    done
    [[ -z "$held" ]] && return 0
    local who
    who="$(fuser "$held" 2>/dev/null | tr -d ' ')"
    who="$(ps -o comm= -p "${who%% *}" 2>/dev/null || echo '?')"
    if (( waited >= timeout )); then
      log_warn "apt is still locked by '${who}' after ${timeout}s."
      if ui_yesno "apt is locked by '${who}'. Stop unattended-upgrades and retry?"; then
        run systemctl stop unattended-upgrades 2>/dev/null || true
        run systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
        return 0
      fi
      die "apt is locked by another process (${who}). Try again later."
    fi
    (( waited == 0 )) && log_info "Waiting for apt lock (held by ${who})…"
    sleep 3; waited=$((waited+3))
  done
}

# apt_repair — fix an interrupted dpkg state if present.
apt_repair() {
  if [[ -e /var/lib/dpkg/updates && -n "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ]]; then
    log_warn "Detected an interrupted dpkg state; repairing with 'dpkg --configure -a'."
    run dpkg --configure -a || true
  fi
}

# apt_update — `apt-get update`, but only once per run.
apt_update() {
  (( _APT_UPDATED )) && return 0
  apt_wait_locks
  narrate "Refreshing the package index so we install current versions."
  run apt-get update -y
  _APT_UPDATED=1
}

# pkg_installed PKG — true if dpkg reports it installed.
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# apt_install PKG... — idempotent; only installs what is missing.
apt_install() {
  local want=("$@") missing=()
  local p
  for p in "${want[@]}"; do
    if pkg_installed "$p"; then
      log_ok "Already installed: ${p}"
    else
      missing+=("$p")
    fi
  done
  (( ${#missing[@]} == 0 )) && return 0
  apt_update
  apt_repair
  apt_wait_locks
  narrate "Installing: ${missing[*]}"
  run apt-get install -y "${missing[@]}"
}

# apt_add_key URL KEYRING_PATH — download & dearmor a repo signing key.
apt_add_key() {
  local url="$1" keyring="$2"
  [[ -f "$keyring" ]] && { log_ok "Key already present: ${keyring}"; return 0; }
  ensure_dir "$(dirname "$keyring")" 0755
  narrate "Adding signing key from ${url}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s▶ [dry-run]%s curl %s | gpg --dearmor > %s\n' "$C_YEL" "$C_RST" "$url" "$keyring" >&2
    return 0
  fi
  curl -fsSL "$url" | gpg --dearmor -o "$keyring"
  chmod 0644 "$keyring"
}

# apt_add_repo NAME "deb LINE" — write /etc/apt/sources.list.d/NAME.list.
apt_add_repo() {
  local name="$1" line="$2" dst="/etc/apt/sources.list.d/${1}.list"
  if [[ -f "$dst" ]] && grep -qF "$line" "$dst"; then
    log_ok "Repo already configured: ${name}"; return 0
  fi
  narrate "Configuring apt repo '${name}'."
  printf '%s\n' "$line" | atomic_write "$dst"
  _APT_UPDATED=0   # force a refresh next apt_update
}
