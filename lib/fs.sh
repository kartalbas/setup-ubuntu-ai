# shellcheck shell=bash
# lib/fs.sh — safe file writes, backups with rollback, transparent diffs,
# and disk-space checks.
[[ -n "${_FS_SH_LOADED:-}" ]] && return 0
_FS_SH_LOADED=1

# atomic_write PATH  — content arrives on stdin; written via temp + mv so a
# crash never leaves a half-written file. Honours DRY_RUN.
atomic_write() {
  local dst="$1" tmp
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s▶ [dry-run]%s write %s:\n' "$C_YEL" "$C_RST" "$dst" >&2
    sed 's/^/    │ /' >&2
    return 0
  fi
  tmp="$(mktemp "${dst}.XXXXXX.tmp")"
  cat >"$tmp"
  chmod --reference="$dst" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv -f "$tmp" "$dst"
  _logfile WRITE "$dst"
}

# backup_file PATH  — timestamped .bak copy; registers an automatic restore on
# the cleanup stack so a failed step reverts the file. Idempotent per run.
backup_file() {
  local f="$1" bak
  [[ -e "$f" ]] || { log_debug "backup_file: $f does not exist yet"; return 0; }
  bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s▶ [dry-run]%s cp -a %s %s\n' "$C_YEL" "$C_RST" "$f" "$bak" >&2
  else
    cp -a "$f" "$bak"
    log_info "Backed up ${f} → ${bak}"
  fi
  add_cleanup "restore_file '$f' '$bak'"
}

# restore_file PATH BAK — used by the cleanup stack on rollback.
restore_file() {
  local f="$1" bak="$2"
  [[ -e "$bak" ]] || return 0
  cp -a "$bak" "$f" 2>/dev/null && log_warn "Rolled back ${f} from ${bak}" || true
}

# show_diff OLD NEWCONTENT_ON_STDIN — print a unified diff of what a write will
# change, so the user sees exactly what is being modified before it happens.
show_diff() {
  local old="$1" tmp rc
  tmp="$(mktemp)"; cat >"$tmp"
  if [[ ! -e "$old" ]]; then
    printf '%s  new file %s:%s\n' "$C_DIM" "$old" "$C_RST" >&2
    sed 's/^/    + /' "$tmp" >&2
    rm -f "$tmp"; return 0
  fi
  if diff -u --label "$old (current)" --label "$old (proposed)" "$old" "$tmp" >/tmp/.fsdiff 2>/dev/null; then
    printf '%s  no change to %s%s\n' "$C_DIM" "$old" "$C_RST" >&2
    rc=1
  else
    printf '%s  changes to %s:%s\n' "$C_BOLD" "$old" "$C_RST" >&2
    # colourise +/- lines lightly
    while IFS= read -r line; do
      case "$line" in
        +++*|---*) printf '%s    %s%s\n' "$C_DIM" "$line" "$C_RST" >&2 ;;
        +*)        printf '%s    %s%s\n' "$C_GRN" "$line" "$C_RST" >&2 ;;
        -*)        printf '%s    %s%s\n' "$C_RED" "$line" "$C_RST" >&2 ;;
        *)         printf '    %s\n' "$line" >&2 ;;
      esac
    done </tmp/.fsdiff
    rc=0
  fi
  rm -f "$tmp" /tmp/.fsdiff
  return "$rc"
}

# ensure_dir PATH [MODE] [OWNER] — mkdir -p with optional mode/owner.
ensure_dir() {
  local d="$1" mode="${2:-0755}" owner="${3:-}"
  [[ -d "$d" ]] || run install -d -m "$mode" "$d"
  [[ -n "$owner" ]] && run chown "$owner" "$d"
  return 0
}

# free_gib PATH — echo free space in whole GiB on the filesystem holding PATH.
free_gib() {
  local p="$1"
  while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  df -BG --output=avail "$p" 2>/dev/null | tail -1 | tr -dc '0-9'
}

# require_space PATH NEED_GIB LABEL — die if not enough free space.
require_space() {
  local p="$1" need="$2" label="${3:-operation}" avail
  avail="$(free_gib "$p")"; avail="${avail:-0}"
  if (( avail < need )); then
    die "Not enough disk for ${label}: need ~${need} GiB on $(df "$p" --output=target | tail -1), have ${avail} GiB."
  fi
  log_debug "Disk OK for ${label}: ${avail} GiB free (need ${need})."
}
