# shellcheck shell=bash
# modules/45-strata.sh — install the Strata engine and its model (ENGINE="strata").
# Checks out STRATA_REPO at STRATA_REF in ~/strata (as you), then runs Strata's
# own installer unattended with the options lib/strata.sh derives from the
# config: it compiles the engine for this GPU with the CUDA toolkit from
# 'drivers', downloads the model into STRATA_DATA_DIR at pinned revisions
# (SHA-256 checked; an interrupted download resumes), packs it and writes
# strata-<tag>.json + run-<tag>.sh. Re-running is cheap: what is built and
# downloaded is kept, the settings are rewritten.
# shellcheck source=/dev/null

_st_checkout() {
  local dir repo ref
  dir="$(strata_dir)"; repo="$(cfg_get STRATA_REPO "$STRATA_REPO_DEFAULT")"; ref="$(cfg_get STRATA_REF)"
  if [[ ! -d "$dir/.git" ]]; then
    narrate "Cloning Strata (${repo}) into ${dir}."
    run_as_user git clone -q "$repo" "$dir" || return 1
  else
    [[ "$(as_user git -C "$dir" remote get-url origin 2>/dev/null)" == "$repo" ]] \
      || run_as_user git -C "$dir" remote set-url origin "$repo"
    run_as_user git -C "$dir" fetch -q --tags origin || log_warn "Could not fetch ${repo} — using the checkout as it is."
  fi
  if [[ -n "$ref" ]]; then
    narrate "Pinning Strata to ${ref}."
    run_as_user git -C "$dir" -c advice.detachedHead=false checkout -q "$ref" || return 1
  else
    run_as_user git -C "$dir" pull -q --ff-only || log_warn "Strata not updated (local changes?) — using it as it is."
  fi
  cfg_set STRATA_BUILT_REV "$(as_user git -C "$dir" rev-parse HEAD 2>/dev/null)"; cfg_save
}

module_main() {
  log_step "Strata engine + model"
  local problem; problem="$(strata_problem)"
  [[ -z "$problem" ]] || { log_error "${problem} — set it in ${CONFIG_FILE}."; return 1; }
  case "$(cfg_get HW_VENDOR)" in
    nvidia) [[ "$(cfg_get CUDA_OK)" == 1 ]] || log_warn "No CUDA toolkit recorded — run 'drivers' first; Strata compiles its engine with it." ;;
    amd)    log_info "AMD: Strata builds its HIP engine itself (ROCm into its own .venv)." ;;
  esac
  # What Strata's installer would otherwise ask sudo for.
  apt_install git python3 python3-venv python3-pip build-essential
  _st_checkout || { log_error "Could not check out Strata."; return 1; }

  local -a args=()
  mapfile -t args < <(strata_setup_args)
  narrate "Running Strata's installer: engine for this GPU, $(cfg_get STRATA_FAMILY) $(cfg_get STRATA_MODEL), $(cfg_get STRATA_CONTEXT "Strata's default") context — the first run downloads the model (100+ GB) and compiles for 10-20 minutes."
  ensure_dir "$(strata_data_dir)" 0755
  [[ "${DRY_RUN:-0}" == "1" ]] || chown "$INVOKING_USER:$(id -gn "$INVOKING_USER")" "$(strata_data_dir)"
  run_as_user env "PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$(strata_dir)/setup.sh" "${args[@]}" || { log_error "Strata's installer failed (its output is above)."; return 1; }

  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  local cfgf; cfg_del STRATA_CONFIG; cfgf="$(strata_config)"
  [[ -n "$cfgf" ]] || { log_error "Strata's installer wrote no strata-*$(cfg_get STRATA_MODEL | tr '[:upper:]' '[:lower:]').json in $(strata_dir)."; return 1; }
  [[ -x "$(strata_run_script)" ]] || { log_error "No start script $(strata_run_script)."; return 1; }
  cfg_set STRATA_CONFIG "$cfgf"; cfg_save
  log_ok "Strata ready: ${cfgf} (start: $(strata_run_script))"
  if [[ -f "$STRATA_UNIT_FILE" ]] && systemctl is-active --quiet "$STRATA_SERVICE"; then
    log_info "The running ${STRATA_SERVICE} picks the new settings up on: sudo ${SCRIPT_PATH##*/} service restart"
  fi
}

module_uninstall() {
  log_step "Removing the Strata engine"
  local dir; dir="$(strata_dir)"
  [[ -d "$dir" ]] && run rm -rf "$dir"
  cfg_del STRATA_CONFIG; cfg_del STRATA_BUILT_REV; cfg_save
  log_ok "Strata removed. The model files stay in $(strata_data_dir) (delete them by hand to free the disk)."
}
