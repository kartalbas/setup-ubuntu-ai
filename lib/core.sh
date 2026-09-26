# shellcheck shell=bash
# lib/core.sh — strict mode, the error trap, and small helpers.
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

# ---- error trap ------------------------------------------------------------
# Report where an unexpected failure happened. File edits are backed up
# (timestamped .bak) before they happen — see backup_file in lib/fs.sh.
_on_err() {
  local rc=$? line="${1:-?}" cmd="${BASH_COMMAND}" src="${BASH_SOURCE[1]:-?}"
  log_error "Failed (exit ${rc}) at ${src}:${line}"
  log_error "  while running: ${cmd}"
  [[ -f "$LOG_FILE" ]] && log_error "  see full log: ${LOG_FILE}"
  exit "$rc"
}
trap '_on_err "$LINENO"' ERR

# ---- small helpers ---------------------------------------------------------
die()      { log_error "$*"; exit 1; }
have()     { command -v "$1" >/dev/null 2>&1; }
need()     { have "$1" || die "Required command not found: $1"; }
is_true()  { [[ "${1:-0}" == "1" || "${1,,}" == "true" || "${1,,}" == "yes" ]]; }
