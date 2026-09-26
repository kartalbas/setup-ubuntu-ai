# shellcheck shell=bash
# lib/fs.sh — safe file writes, backups, transparent diffs, and disk-space
# checks.
[[ -n "${_FS_SH_LOADED:-}" ]] && return 0
_FS_SH_LOADED=1

# atomic_write PATH [MODE] [SECRET] — content arrives on stdin; written via
# temp + mv so a crash never leaves a half-written file. MODE sets the final
# permissions (default: keep the existing file's, else 0644). SECRET=1 keeps
# the content out of the dry-run preview. Honours DRY_RUN.
atomic_write() {
  local dst="$1" mode="${2:-}" secret="${3:-0}" tmp
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s▶ [dry-run]%s write %s%s:\n' "$C_YEL" "$C_RST" "$dst" "${mode:+ (mode ${mode})}" >&2
    if [[ "$secret" == "1" ]]; then
      printf '    │ <secret, %s bytes>\n' "$(wc -c | tr -d ' ')" >&2
    else
      redact_secrets | sed 's/^/    │ /' >&2
    fi
    return 0
  fi
  tmp="$(mktemp "${dst}.XXXXXX.tmp")"
  if [[ -n "$mode" ]]; then
    chmod "$mode" "$tmp"
  else
    chmod --reference="$dst" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  fi
  cat >"$tmp"
  mv -f "$tmp" "$dst"
  _logfile WRITE "$dst"
}

# backup_file PATH — timestamped .bak copy taken before a file is edited, so
# every change can be inspected and reverted by hand.
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
}

# show_diff OLD NEWCONTENT_ON_STDIN — print a unified diff of what a write will
# change, so the user sees exactly what is being modified before it happens.
# Inline API keys are masked. Returns 1 when nothing changes.
show_diff() {
  local old="$1" tmp out rc
  tmp="$(mktemp)"; cat >"$tmp"
  if [[ ! -e "$old" ]]; then
    printf '%s  new file %s:%s\n' "$C_DIM" "$old" "$C_RST" >&2
    redact_secrets <"$tmp" | sed 's/^/    + /' >&2
    rm -f "$tmp"; return 0
  fi
  out="$(mktemp)"
  if diff -u --label "$old (current)" --label "$old (proposed)" "$old" "$tmp" >"$out" 2>/dev/null; then
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
    done < <(redact_secrets <"$out")
    rc=0
  fi
  rm -f "$tmp" "$out"
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
