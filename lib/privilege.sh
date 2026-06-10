# shellcheck shell=bash
# lib/privilege.sh — root escalation and dropping back to the invoking user.
[[ -n "${_PRIV_SH_LOADED:-}" ]] && return 0
_PRIV_SH_LOADED=1

# The human who launched us, even after re-exec under sudo.
INVOKING_USER="${SUDO_USER:-${USER:-$(id -un)}}"
if [[ "$INVOKING_USER" == "root" && -n "${SUDO_USER:-}" ]]; then
  INVOKING_USER="$SUDO_USER"
fi
INVOKING_HOME="$(getent passwd "$INVOKING_USER" 2>/dev/null | cut -d: -f6)"
INVOKING_HOME="${INVOKING_HOME:-$HOME}"

# ensure_root — re-exec the whole script under sudo -E once, preserving the
# environment knobs the suite cares about. After this returns we are root.
ensure_root() {
  (( EUID == 0 )) && return 0
  have sudo || die "Need root, and sudo is not installed. Re-run as root."
  log_info "Elevating with sudo (preserving environment)…"
  exec sudo \
    LOG_FILE="$LOG_FILE" LOG_LEVEL="$LOG_LEVEL" DRY_RUN="$DRY_RUN" QUIET="$QUIET" \
    NO_UI="${NO_UI:-}" ASSUME_YES="${ASSUME_YES:-}" NO_COLOR="${NO_COLOR:-}" \
    CONFIG_FILE="$CONFIG_FILE" SUDO_USER="$INVOKING_USER" \
    bash "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
}

# run_as_user CMD [ARGS...] — run a command as the invoking human (for HF
# downloads with their token, home-dir git clones/builds). Verbose like run().
run_as_user() {
  _logfile CMD "(as $INVOKING_USER) $*"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s▶ [dry-run]%s (as %s) %s\n' "$C_YEL" "$C_RST" "$INVOKING_USER" "$*" >&2
    return 0
  fi
  [[ "${QUIET:-0}" == "1" ]] || printf '%s▶%s (as %s) %s\n' "$C_CYAN" "$C_RST" "$INVOKING_USER" "$*" >&2
  if (( EUID == 0 )) && [[ "$INVOKING_USER" != "root" ]]; then
    sudo -u "$INVOKING_USER" -H "$@"
  else
    "$@"
  fi
}
