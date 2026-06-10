# shellcheck shell=bash
# modules/35-power-limit.sh — set a persistent NVIDIA GPU power limit (TDP cap).
# Applies the limit now AND installs a systemd service so it is re-applied on
# every boot. Useful for power/thermal headroom or limited PSU cabling
# (e.g. only 3x 8-pin = ~450W budget on an RTX 5090).
# shellcheck source=/dev/null

PL_SVC="nvidia-powerlimit.service"
PL_UNIT="/etc/systemd/system/${PL_SVC}"

_pl_smi_ok() { have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; }

# Extract a wattage field from `nvidia-smi -q -d POWER` (integer watts).
_pl_field() {
  nvidia-smi -q -d POWER 2>/dev/null | grep -m1 "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1
}

_pl_install_service() {
  local watts="$1"
  narrate "Installing ${PL_SVC} so the ${watts}W cap is re-applied on every boot."
  local content
  content="$(cat <<EOF
[Unit]
Description=NVIDIA GPU power limit (${watts}W) — setup-ubuntu-ai
After=nvidia-persistenced.service systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Best-effort, run ONCE at boot. If the driver/GPU isn't ready, skip cleanly
# (exit 0) instead of error-looping. NO Restart= — that would retry forever.
ExecStart=/usr/bin/env bash -c 'if nvidia-smi -L >/dev/null 2>&1; then nvidia-smi -pm 1 >/dev/null 2>&1 || true; nvidia-smi -pl ${watts}; else echo "nvidia driver not ready; skipping ${watts}W cap"; fi'

[Install]
WantedBy=multi-user.target
EOF
)"
  show_diff "$PL_UNIT" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$PL_UNIT"
  run systemctl daemon-reload
  run systemctl enable "${PL_SVC}"
}

module_main() {
  log_step "NVIDIA GPU power limit (TDP cap)"
  if [[ "$(cfg_get HW_VENDOR)" != "nvidia" ]]; then
    log_warn "Power-limit control here is NVIDIA-only (detected: $(cfg_get HW_VENDOR))."
    return 0
  fi

  local min max def cur
  if _pl_smi_ok; then
    min="$(_pl_field 'Min Power Limit')"
    max="$(_pl_field 'Max Power Limit')"
    def="$(_pl_field 'Default Power Limit')"
    cur="$(_pl_field 'Current Power Limit')"
    log_info "GPU power limits — min: ${min:-?}W  max: ${max:-?}W  default: ${def:-?}W  current: ${cur:-?}W"
  else
    log_warn "Driver not active yet (nvidia-smi can't talk to the GPU)."
    log_warn "I'll record the limit and install the boot service; it applies once the driver loads."
  fi

  # Desired watts: from the verb arg, else prompt (default to prior config or 450).
  local want="${1:-}"
  if [[ -z "$want" ]]; then
    local prefill; prefill="$(cfg_get NVIDIA_POWER_LIMIT_W "${cur:-450}")"
    want="$(ui_input "Power limit in WATTS (e.g. 350 or 450). Your 3x8-pin cabling ≈ 450W budget; 350W is a safe margin." "$prefill")" || return 0
  fi
  [[ "$want" =~ ^[0-9]+$ ]] || { log_error "Power limit must be an integer number of watts (got '$want')."; return 1; }

  # Validate against the card's allowed range when we can see it.
  if [[ -n "${min:-}" && -n "${max:-}" ]]; then
    if (( want < min )); then log_warn "Requested ${want}W is below the card minimum ${min}W — clamping to ${min}W."; want="$min"; fi
    if (( want > max )); then log_warn "Requested ${want}W exceeds the card maximum ${max}W — clamping to ${max}W."; want="$max"; fi
  fi

  # Safety note tied to cabling.
  if (( want > 450 )); then
    log_warn "${want}W exceeds a 3x 8-pin (~450W) budget. Only use >450W with all 4 cables connected."
    ui_yesno "Continue with ${want}W anyway?" || return 0
  fi

  # Apply immediately if the GPU is reachable.
  if _pl_smi_ok; then
    narrate "Applying ${want}W now (and enabling persistence mode)."
    run nvidia-smi -pm 1 || true
    run nvidia-smi -pl "$want"
    log_ok "Power limit set to ${want}W (now reads: $(_pl_field 'Current Power Limit')W)."
  fi

  _pl_install_service "$want"
  cfg_set NVIDIA_POWER_LIMIT_W "$want"; cfg_save
  log_ok "Power limit ${want}W will be enforced on every boot."
}

module_uninstall() {
  log_step "Removing GPU power limit"
  run systemctl disable --now "${PL_SVC}" 2>/dev/null || true
  run rm -f "$PL_UNIT"
  run systemctl daemon-reload
  if _pl_smi_ok && [[ -n "$(_pl_field 'Default Power Limit')" ]]; then
    narrate "Restoring the default power limit."
    run nvidia-smi -pl "$(_pl_field 'Default Power Limit')" || true
  fi
  cfg_del NVIDIA_POWER_LIMIT_W; cfg_save
  log_ok "Power limit removed (default restored; reboot to be sure)."
}
