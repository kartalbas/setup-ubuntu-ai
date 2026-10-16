# shellcheck shell=bash
# modules/60-service-llama.sh — install the configured engine's server as a
# systemd service that starts on boot and runs as the invoking user:
# llama-server (ENGINE=llamacpp, the default) or strata-server (ENGINE=strata).
# Also enable/disable/restart/status/logs/uninstall. The units, the
# environment and the API-key credential are rendered by lib/runtime.sh and
# lib/strata.sh.
# shellcheck source=/dev/null

_svc_preflight() {
  local bin model mmproj fatal="die"
  [[ "${DRY_RUN:-0}" == "1" ]] && fatal="log_warn"   # don't abort a dry-run walkthrough
  bin="$(llama_bin)"; model="$(cfg_get LLAMA_MODEL)"; mmproj="$(cfg_get LLAMA_MMPROJ)"
  [[ -x "$bin" ]] || $fatal "llama-server binary not found ($bin). Run 'build' first."
  llama_bin_runs "$bin" \
    || $fatal "llama-server at ${bin} is not a working binary (truncated build, or built on another machine?). Run 'build' to recompile here."
  [[ -n "$model" ]] || $fatal "No model selected. Run 'model' then 'configure' first."
  [[ -e "$model" ]] || $fatal "Model file missing: ${model}. Run 'model' first."
  [[ -z "$mmproj" || -e "$mmproj" ]] || $fatal "Vision projector missing: ${mmproj}. Run 'model' first."
}

_svc_preflight_strata() {
  local fatal="die"
  [[ "${DRY_RUN:-0}" == "1" ]] && fatal="log_warn"
  [[ -n "$(strata_config)" ]] || $fatal "Strata is not installed for $(cfg_get STRATA_MODEL '?'). Run 'build' first."
  [[ -x "$(strata_run_script)" ]] || $fatal "Strata's start script is missing ($(strata_run_script)). Run 'build' first."
}

# _svc_retire UNIT_FILE SERVICE — the other engine's unit goes when this one is
# installed: both would listen on the same port.
_svc_retire() {
  [[ -f "$1" ]] || return 0
  narrate "Removing ${2} — the configured engine is $(engine_kind) now."
  run systemctl disable --now "${2}.service" 2>/dev/null || true
  run rm -f "$1"
}

svc_install() {
  local svc; svc="$(llm_service)"
  log_step "Install ${svc} service"
  if strata_enabled; then
    _svc_preflight_strata
    local problem; problem="$(api_key_problem)"
    [[ -z "$problem" ]] || { log_error "${problem} — set it in ${CONFIG_FILE}, or deploy with: sudo ./deploy.sh <profile> --key KEY"; return 1; }
    _render_api_key
    render_strata_unit
    _svc_retire "$LLAMA_UNIT_FILE" "$LLAMA_SERVICE"
    run rm -f "$LLAMA_ENV_FILE"
  else
    _svc_preflight
    render_llama_runtime || return 1
    render_llama_unit
    _svc_retire "$STRATA_UNIT_FILE" "$STRATA_SERVICE"
  fi
  run systemctl daemon-reload
  narrate "Enabling the service so it starts automatically on every boot."
  run systemctl enable "${svc}.service"
  if [[ -z "$(cfg_get LLAMA_API_KEY)" && "$(cfg_get LLAMA_HOST 0.0.0.0)" == "0.0.0.0" ]]; then
    log_warn "API is on 0.0.0.0 without an API key: anyone on your network can use it."
  fi
  # restart, not `enable --now`: a server that is already running must pick
  # up the freshly rendered unit and environment.
  llama_restart || return 1
  cfg_set SERVICE_INSTALLED 1; cfg_save
  log_info "Manage with: systemctl {status|restart|stop} ${svc}  ·  logs: journalctl -u ${svc} -f"
}

svc_uninstall() {
  log_step "Uninstall $(llm_service) service"
  run systemctl disable --now "${LLAMA_SERVICE}.service" "${STRATA_SERVICE}.service" 2>/dev/null || true
  run rm -f "$LLAMA_UNIT_FILE" "$STRATA_UNIT_FILE" "$LLAMA_ENV_FILE" "$LLAMA_KEY_FILE"
  run systemctl daemon-reload
  cfg_del SERVICE_INSTALLED; cfg_save
  log_ok "Service removed."
}

module_main() {
  local sub="${1:-}" svc; svc="$(llm_service)"
  if [[ -z "$sub" ]]; then
    sub="$(ui_menu "${svc} service" "Choose an action:" \
      install   "Install + enable (auto-start on boot)" \
      restart   "Restart" \
      status    "Status" \
      logs      "Recent logs" \
      disable   "Disable (stop auto-start)" \
      enable    "Enable (auto-start)" \
      uninstall "Uninstall")" || return 0
  fi
  case "$sub" in
    install)   svc_install ;;
    uninstall) svc_uninstall ;;
    enable)    run systemctl enable --now "${svc}.service" ;;
    disable)   run systemctl disable --now "${svc}.service" ;;
    restart)   llama_restart ;;
    status)    run systemctl --no-pager status "${svc}.service" || true ;;
    logs)      run journalctl -u "${svc}.service" -n 40 --no-pager || true ;;
    *)         die "Unknown service action: $sub" ;;
  esac
}

module_uninstall() { svc_uninstall; }
