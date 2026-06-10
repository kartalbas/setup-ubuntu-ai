# shellcheck shell=bash
# lib/state.sh — lightweight checkpoint state + cross-reboot resume support.
# Used so the guided flow survives the reboots that NVIDIA-MOK enrollment and
# AMD VRAM changes require.
[[ -n "${_STATE_SH_LOADED:-}" ]] && return 0
_STATE_SH_LOADED=1

STATE_DIR="${STATE_DIR:-/var/lib/setup-ubuntu-ai}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state}"
RESUME_UNIT="setup-ubuntu-ai-resume.service"

state_put() {
  local k="$1" v="$2"
  ensure_dir "$STATE_DIR" 0755
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_debug "[dry-run] state: $k=$v"; return 0
  fi
  local tmp; tmp="$(mktemp)"
  [[ -f "$STATE_FILE" ]] && grep -v "^${k}=" "$STATE_FILE" >"$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >>"$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

state_get() {
  [[ -f "$STATE_FILE" ]] || { printf '%s' "${2-}"; return 0; }
  local v; v="$(grep -m1 "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2-)"
  printf '%s' "${v:-${2-}}"
}

state_clear() { [[ "${DRY_RUN:-0}" == "1" ]] || rm -f "$STATE_FILE"; }

# schedule_resume VERB — record where to continue and (optionally) install a
# one-shot boot unit that reminds / auto-continues after the next reboot.
schedule_resume() {
  local verb="$1"
  state_put RESUME_FROM "$verb"
  state_put RESUME_PENDING 1
  log_info "Recorded resume point: after reboot run  sudo ${SCRIPT_PATH##*/} resume"

  local unit="/etc/systemd/system/${RESUME_UNIT}"
  local auto; auto="$(cfg_get AUTO_RESUME 0)"
  cat <<EOF | atomic_write "$unit"
[Unit]
Description=Resume setup-ubuntu-ai after reboot
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=no
# Self-disable so it only fires once.
ExecStartPre=/usr/bin/systemctl disable ${RESUME_UNIT}
ExecStart=/usr/bin/env bash -lc '$( [[ "$auto" == "1" ]] \
  && printf 'ASSUME_YES=1 %s resume' "$SCRIPT_PATH" \
  || printf 'wall "setup-ubuntu-ai: reboot complete. Run: sudo %s resume"' "$SCRIPT_PATH" )'

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable "${RESUME_UNIT}" 2>/dev/null || true
}

resume_cleanup() {
  state_put RESUME_PENDING 0
  [[ -f "/etc/systemd/system/${RESUME_UNIT}" ]] && {
    run systemctl disable "${RESUME_UNIT}" 2>/dev/null || true
    run rm -f "/etc/systemd/system/${RESUME_UNIT}"
    run systemctl daemon-reload
  }
  return 0
}

# offer_reboot REASON RESUME_VERB — common pattern after MOK / VRAM changes.
offer_reboot() {
  local reason="$1" verb="$2"
  log_warn "A reboot is required: ${reason}"
  schedule_resume "$verb"
  if ui_yesno "Reboot now to apply: ${reason}?  (You can also reboot later and run '${SCRIPT_PATH##*/} resume'.)"; then
    log_info "Rebooting…"
    run systemctl reboot
  else
    ui_msg "No reboot performed. When ready:\n  1. sudo reboot\n  2. sudo ${SCRIPT_PATH##*/} resume" "Reboot deferred"
  fi
}
