# shellcheck shell=bash
# modules/60-service-llama.sh — install llama-server as a systemd service that
# starts on boot and runs as the invoking user. Also enable/disable/restart/
# status/logs/uninstall. The unit, its environment and the API-key credential
# are rendered by lib/runtime.sh.
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

svc_install() {
  log_step "Install ${LLAMA_SERVICE} service"
  _svc_preflight
  render_llama_runtime || return 1
  render_llama_unit
  run systemctl daemon-reload
  narrate "Enabling the service so it starts automatically on every boot."
  run systemctl enable "${LLAMA_SERVICE}.service"
  if [[ -z "$(cfg_get LLAMA_API_KEY)" && "$(cfg_get LLAMA_HOST 0.0.0.0)" == "0.0.0.0" ]]; then
    log_warn "API is on 0.0.0.0 without an API key: anyone on your network can use it."
  fi
  # restart, not `enable --now`: a server that is already running must pick
  # up the freshly rendered unit and environment.
  llama_restart || return 1
  cfg_set SERVICE_INSTALLED 1; cfg_save
  log_info "Manage with: systemctl {status|restart|stop} ${LLAMA_SERVICE}  ·  logs: journalctl -u ${LLAMA_SERVICE} -f"
}

svc_uninstall() {
  log_step "Uninstall ${LLAMA_SERVICE} service"
  run systemctl disable --now "${LLAMA_SERVICE}.service" 2>/dev/null || true
  run rm -f "$LLAMA_UNIT_FILE" "$LLAMA_ENV_FILE" "$LLAMA_KEY_FILE"
  run systemctl daemon-reload
  cfg_del SERVICE_INSTALLED; cfg_save
  log_ok "Service removed."
}

module_main() {
  local sub="${1:-}"
  if [[ -z "$sub" ]]; then
    sub="$(ui_menu "llama-server service" "Choose an action:" \
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
    enable)    run systemctl enable --now "${LLAMA_SERVICE}.service" ;;
    disable)   run systemctl disable --now "${LLAMA_SERVICE}.service" ;;
    restart)   llama_restart ;;
    status)    run systemctl --no-pager status "${LLAMA_SERVICE}.service" || true ;;
    logs)      run journalctl -u "${LLAMA_SERVICE}.service" -n 40 --no-pager || true ;;
    *)         die "Unknown service action: $sub" ;;
  esac
}

module_uninstall() { svc_uninstall; }
