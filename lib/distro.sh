# shellcheck shell=bash
# lib/distro.sh — OS / version detection (warn-not-fail on the untested-but-newer).
[[ -n "${_DISTRO_SH_LOADED:-}" ]] && return 0
_DISTRO_SH_LOADED=1

DISTRO_ID=""; DISTRO_VER=""; DISTRO_CODENAME=""; DISTRO_PRETTY=""

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VER="${VERSION_ID:-0}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"
    DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID $DISTRO_VER}"
  else
    DISTRO_ID="unknown"; DISTRO_PRETTY="unknown OS"
  fi
  log_debug "Distro: ${DISTRO_PRETTY} (id=${DISTRO_ID} ver=${DISTRO_VER} codename=${DISTRO_CODENAME})"
}

# assert_supported — hard-fail only on the wrong distro family; warn on newer
# or untested Ubuntu releases so the suite stays usable on 24.04/25.04/26.04+.
assert_supported() {
  case "$DISTRO_ID" in
    ubuntu) : ;;
    debian|pop|linuxmint|neon)
      log_warn "Detected ${DISTRO_PRETTY}: Ubuntu-like, mostly supported — proceeding." ;;
    *)
      die "This installer targets Ubuntu (found: ${DISTRO_PRETTY}). Aborting to avoid breaking your system." ;;
  esac
  if [[ "$DISTRO_ID" == "ubuntu" ]] && ver_lt "${DISTRO_VER:-0}" 24.04; then
    log_warn "Ubuntu ${DISTRO_VER} is older than the tested 24.04+; driver packages may differ."
  fi
}
