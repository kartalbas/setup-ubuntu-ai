# shellcheck shell=bash
# lib/configs.sh — this machine's config.conf in your own private config
# repository, as it is (API key included — keep that repository private).
# CONFIGS_REPO=OWNER/NAME is cloned as you to ~/repos/<owner>/<name>; the file
# lives in setup-ubuntu-ai/hosts/<CONFIGS_HOST>/ there (default: the short
# host name — set another when machines share one).
#   sudo ./setup.sh configs        put it in place (then: restore)
#   sudo ./setup.sh configs save   copy it back, commit, push
[[ -n "${_CONFIGS_SH_LOADED:-}" ]] && return 0
_CONFIGS_SH_LOADED=1

configs_run() { # [save]
  local mode="${1:-apply}" repo host dir sub
  [[ "$INVOKING_USER" != root ]] || die "Run it with sudo from your own account: the repository is cloned and pushed as you"
  repo="$(cfg_get CONFIGS_REPO)" host="$(cfg_get CONFIGS_HOST)"
  if [[ "$repo" != */* ]]; then
    [[ -z "${ASSUME_YES:-}" ]] || die "No CONFIGS_REPO in ${CONFIG_FILE}"
    repo="$(ui_input "Your private config repository (OWNER/NAME)" "" "Config repository")" || die "Cancelled"
    [[ "$repo" == */* ]] || die "Not OWNER/NAME: ${repo}"
  fi
  if [[ -z "$host" ]]; then
    host="$(hostname -s)"
    if [[ -z "${ASSUME_YES:-}" ]]; then
      host="$(ui_input "This machine's folder in it (setup-ubuntu-ai/hosts/NAME)" "$host" "Config repository")" || die "Cancelled"
    fi
  fi
  dir="$INVOKING_HOME/repos/$(tr '[:upper:]' '[:lower:]' <<<"${repo%%/*}")/${repo#*/}"
  sub="$dir/setup-ubuntu-ai/hosts/$host"
  log_step "This machine's settings: ${repo}, hosts/${host}"
  if [[ ! -d "$dir/.git" ]]; then
    run_as_user mkdir -p "$(dirname "$dir")"
    run_as_user git clone -q "https://github.com/${repo}.git" "$dir" || die "Could not clone ${repo} (is ${INVOKING_USER} signed in to GitHub?)"
  fi
  run_as_user git -C "$dir" pull -q --ff-only || log_warn "${repo} not updated (offline or local changes) — using it as it is"
  case "$mode" in
    apply)
      [[ -f "$sub/config.conf" ]] || die "Nothing saved for ${host} in ${repo} yet: sudo ./setup.sh configs save on that machine"
      ensure_dir "$(dirname "$CONFIG_FILE")" 0755
      atomic_write "$CONFIG_FILE" 0600 1 <"$sub/config.conf"
      cfg_load
      log_ok "${CONFIG_FILE} — rebuild the stack from it with: sudo ./setup.sh restore" ;;
    save)
      # Only rewrite the config when these change: every save stamps its time.
      if [[ "$(cfg_get CONFIGS_REPO)" != "$repo" || "$(cfg_get CONFIGS_HOST)" != "$host" ]]; then
        cfg_set CONFIGS_REPO "$repo"; cfg_set CONFIGS_HOST "$host"; cfg_save
      fi
      run_as_user mkdir -p "$sub"
      cmp -s "$CONFIG_FILE" "$sub/config.conf" \
        || run install -m 0600 -o "$INVOKING_USER" -g "$(id -gn "$INVOKING_USER")" "$CONFIG_FILE" "$sub/config.conf"
      run_as_user git -C "$dir" add -A
      if as_user git -C "$dir" diff --cached --quiet; then log_ok "Nothing changed"; return 0; fi
      [[ -n "$(as_user git -C "$dir" config user.email)" ]] \
        || die "git has no identity for ${INVOKING_USER}: git config --global user.name NAME; git config --global user.email EMAIL"
      run_as_user git -C "$dir" commit -q -m "setup-ubuntu-ai settings from ${host}"
      run_as_user git -C "$dir" push -q && log_ok "Saved to ${repo}" ;;
    *) die "configs [save]" ;;
  esac
}
