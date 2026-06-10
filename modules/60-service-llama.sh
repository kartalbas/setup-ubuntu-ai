# shellcheck shell=bash
# modules/60-service-llama.sh — install llama-server as a systemd service that
# starts on boot and runs as the invoking user. Also enable/disable/restart/
# status/uninstall.
# shellcheck source=/dev/null

SVC_NAME="llama-server"
SVC_UNIT="/etc/systemd/system/${SVC_NAME}.service"
SVC_ENV="/etc/setup-ubuntu-ai/llama-server.env"

_svc_render_env() {
  local content
  content="$(cat <<EOF
# Managed by setup-ubuntu-ai — edit then: systemctl restart ${SVC_NAME}
LLAMA_MODEL=$(cfg_get LLAMA_MODEL)
LLAMA_MODEL_DIR=$(cfg_get MODEL_DIR "$INVOKING_HOME/models")
LLAMA_HOST=$(cfg_get LLAMA_HOST 0.0.0.0)
LLAMA_PORT=$(cfg_get LLAMA_PORT 8080)
LLAMA_CTX=$(cfg_get LLAMA_CTX 8192)
LLAMA_NGL=$(cfg_get LLAMA_NGL 999)
LLAMA_EXTRA_ARGS=$(cfg_get LLAMA_EXTRA_ARGS "--flash-attn on")
EOF
)"
  ensure_dir "$(dirname "$SVC_ENV")" 0755
  show_diff "$SVC_ENV" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$SVC_ENV"
}

_svc_render_unit() {
  local bin user content tmpl="$REPO_ROOT/services/${SVC_NAME}.service.tmpl"
  bin="$(cfg_get LLAMACPP_BIN "$INVOKING_HOME/llama.cpp/build/bin/llama-server")"
  user="$INVOKING_USER"
  [[ -f "$tmpl" ]] || die "Missing template: $tmpl"
  content="$(sed -e "s|@USER@|${user}|g" -e "s|@BIN@|${bin}|g" -e "s|@ENVFILE@|${SVC_ENV}|g" "$tmpl")"
  show_diff "$SVC_UNIT" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$SVC_UNIT"
}

_svc_preflight() {
  local bin model fatal="die"
  [[ "${DRY_RUN:-0}" == "1" ]] && fatal="log_warn"   # don't abort a dry-run walkthrough
  bin="$(cfg_get LLAMACPP_BIN "$INVOKING_HOME/llama.cpp/build/bin/llama-server")"
  model="$(cfg_get LLAMA_MODEL)"
  [[ -x "$bin" ]]   || $fatal "llama-server binary not found ($bin). Run 'build' first."
  [[ -n "$model" ]] || $fatal "No model selected. Run 'model' then 'configure' first."
  [[ -e "$model" ]] || log_warn "Configured model file does not exist yet: $model"
}

_svc_health() {
  local port; port="$(cfg_get LLAMA_PORT 8080)"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  log_info "Waiting for the server to answer on :${port} (model load can take a while)…"
  local _t
  for _t in {1..30}; do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      log_ok "Server healthy at http://$(cfg_get LLAMA_HOST 0.0.0.0):${port}"
      return 0
    fi
    sleep 2
  done
  log_warn "No healthy response yet. Check:  journalctl -u ${SVC_NAME} -e"
}

svc_install() {
  log_step "Install ${SVC_NAME} service"
  _svc_preflight
  _svc_render_env
  _svc_render_unit
  run systemctl daemon-reload
  narrate "Enabling the service so it starts automatically on every boot."
  run systemctl enable --now "${SVC_NAME}.service"
  [[ "$(cfg_get LLAMA_HOST 0.0.0.0)" == "0.0.0.0" ]] && \
    log_warn "API is on 0.0.0.0 (LAN-reachable). Anyone on your network can use it unless you set an API key."
  _svc_health
  cfg_set SERVICE_INSTALLED 1; cfg_save
  log_info "Manage with: systemctl {status|restart|stop} ${SVC_NAME}  ·  logs: journalctl -u ${SVC_NAME} -f"
}

svc_uninstall() {
  log_step "Uninstall ${SVC_NAME} service"
  run systemctl disable --now "${SVC_NAME}.service" 2>/dev/null || true
  run rm -f "$SVC_UNIT" "$SVC_ENV"
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
    enable)    run systemctl enable --now "${SVC_NAME}.service" ;;
    disable)   run systemctl disable --now "${SVC_NAME}.service" ;;
    restart)   run systemctl restart "${SVC_NAME}.service"; _svc_health ;;
    status)    run systemctl --no-pager status "${SVC_NAME}.service" || true ;;
    logs)      run journalctl -u "${SVC_NAME}.service" -n 40 --no-pager || true ;;
    *)         die "Unknown service action: $sub" ;;
  esac
}

module_uninstall() { svc_uninstall; }
