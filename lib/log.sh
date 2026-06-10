# shellcheck shell=bash
# lib/log.sh — colour, levelled logging, verbose command runner.
# Sourced (never executed). Every state-changing command MUST go through run().
[[ -n "${_LOG_SH_LOADED:-}" ]] && return 0
_LOG_SH_LOADED=1

# ---- configuration (overridable from the environment) ----------------------
LOG_FILE="${LOG_FILE:-/var/log/setup-ubuntu-ai/install.log}"
LOG_LEVEL="${LOG_LEVEL:-info}"   # debug | info | warn | error
DRY_RUN="${DRY_RUN:-0}"          # 1 = print commands, change nothing
QUIET="${QUIET:-0}"              # 1 = suppress the verbose ▶ command echo

# ---- colours (TTY-aware, honour NO_COLOR) ----------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RST=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYAN=''
fi

# ---- log-file plumbing -----------------------------------------------------
# Append a raw line to the log file; never fail the caller if the file is
# not yet writable (standalone module runs before setup.sh made the dir).
_logfile() {
  local d="${LOG_FILE%/*}"
  # Skip quietly unless we can actually write (e.g. before sudo elevation the
  # root-owned log dir exists but isn't writable — avoid a redirection error).
  if [[ -e "$LOG_FILE" ]]; then
    [[ -w "$LOG_FILE" ]] || return 0
  else
    [[ -d "$d" && -w "$d" ]] || return 0
  fi
  printf '%s [%s] %s\n' "$(date '+%F %T')" "${1}" "${2}" >>"$LOG_FILE" 2>/dev/null || true
}

_lvl_num() { case "$1" in debug) echo 0;; info) echo 1;; warn) echo 2;; error) echo 3;; *) echo 1;; esac; }
_should_print() { (( $(_lvl_num "$1") >= $(_lvl_num "$LOG_LEVEL") )); }

# ---- user-facing log helpers (all to stderr; stdout stays clean) -----------
log_debug() { _logfile DEBUG "$*"; _should_print debug && printf '%s  %s%s\n'   "$C_DIM" "$*" "$C_RST" >&2; return 0; }
log_info()  { _logfile INFO  "$*"; _should_print info  && printf '%s•%s %s\n'   "$C_BLU" "$C_RST" "$*" >&2; return 0; }
log_ok()    { _logfile OK    "$*"; _should_print info  && printf '%s✓%s %s\n'   "$C_GRN" "$C_RST" "$*" >&2; return 0; }
log_warn()  { _logfile WARN  "$*"; _should_print warn  && printf '%s!%s %s\n'   "$C_YEL" "$C_RST" "$*" >&2; return 0; }
log_error() { _logfile ERROR "$*"; printf '%s✗%s %s\n'   "$C_RED" "$C_RST" "$*" >&2; return 0; }

# A one-line "why" narration so the user understands the intent of a step.
narrate()   { _logfile WHY   "$*"; printf '%s  ↳ %s%s\n' "$C_DIM" "$*" "$C_RST" >&2; return 0; }

# A bold section header that frames a whole step.
log_step() {
  _logfile STEP "$*"
  printf '\n%s%s━━ %s ━━%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RST" >&2
}

# ---- the verbose command runner -------------------------------------------
# run CMD [ARGS...]   — echoes the command in full, then executes it so its
# output streams live. Honours DRY_RUN (echo only) and QUIET (suppress echo).
# NOTE: run() executes a simple command; it cannot contain pipes or shell
# redirections. For those, call a dedicated helper function instead.
run() {
  _logfile CMD "$*"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s▶ [dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2
    return 0
  fi
  [[ "$QUIET" == "1" ]] || printf '%s▶%s %s\n' "$C_CYAN" "$C_RST" "$*" >&2
  "$@"
}

# run_quiet CMD — like run() but captures output; only shows it on failure.
# Use for noisy read-only probes where streaming would be pure clutter.
run_quiet() {
  _logfile CMD "$*"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s▶ [dry-run]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2
    return 0
  fi
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    printf '%s▶%s %s\n' "$C_CYAN" "$C_RST" "$*" >&2
    printf '%s\n' "$out" >&2
  fi
  _logfile OUT "$out"
  return "$rc"
}
