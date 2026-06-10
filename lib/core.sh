# shellcheck shell=bash
# lib/core.sh — strict mode, error traps, and a LIFO cleanup/rollback stack.
# Source this FIRST (after log.sh) in every entry point.
[[ -n "${_CORE_SH_LOADED:-}" ]] && return 0
_CORE_SH_LOADED=1

# ---- strict mode -----------------------------------------------------------
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Require a reasonably modern bash (associative arrays, inherit_errexit).
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "This installer needs bash >= 4.4 (found ${BASH_VERSION})." >&2
  exit 1
fi

# ---- cleanup / rollback stack ---------------------------------------------
# Modules register reversal snippets right after a risky change, e.g.:
#   backup_file /etc/default/grub
#   add_cleanup "restore_file /etc/default/grub"
# On a mid-step failure (ERR trap) or normal exit, pending cleanups run LIFO.
declare -ga _CLEANUPS=()
add_cleanup() { _CLEANUPS+=("$1"); }
clear_cleanups() { _CLEANUPS=(); }     # call on success to "commit" the changes
_run_cleanups() {
  (( ${#_CLEANUPS[@]} )) || return 0
  local i
  for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do
    eval "${_CLEANUPS[i]}" || true
  done
  _CLEANUPS=()
}

# ---- traps -----------------------------------------------------------------
_on_err() {
  local rc=$? line="${1:-?}" cmd="${BASH_COMMAND}" src="${BASH_SOURCE[1]:-?}"
  log_error "Failed (exit ${rc}) at ${src}:${line}"
  log_error "  while running: ${cmd}"
  [[ -f "$LOG_FILE" ]] && log_error "  see full log: ${LOG_FILE}"
  _run_cleanups
  exit "$rc"
}
trap '_on_err "$LINENO"' ERR
trap '_run_cleanups' EXIT

# ---- small helpers ---------------------------------------------------------
die()      { log_error "$*"; exit 1; }
have()     { command -v "$1" >/dev/null 2>&1; }
need()     { have "$1" || die "Required command not found: $1"; }
is_true()  { [[ "${1:-0}" == "1" || "${1,,}" == "true" || "${1,,}" == "yes" ]]; }
