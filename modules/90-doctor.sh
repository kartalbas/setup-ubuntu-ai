# shellcheck shell=bash
# modules/90-doctor.sh — read-only health check of the whole stack.
# shellcheck source=/dev/null

_chk()  { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
_warnx(){ printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
_failx(){ printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

module_main() {
  log_step "Doctor — diagnostics"
  local vendor; vendor="$(cfg_get HW_VENDOR unknown)"
  printf '%sGPU%s  %s\n' "$C_BOLD" "$C_RST" "$(cfg_get HW_MODEL '?')" >&2

  # --- driver ---
  case "$vendor" in
    nvidia)
      if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        _chk "NVIDIA driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/      /' >&2 || true
      else
        _failx "nvidia-smi not working — driver missing or needs a reboot."
      fi
      if have nvcc; then
        if nvcc --list-gpu-arch 2>/dev/null | grep -q compute_120; then
          _chk "CUDA toolkit supports sm_120"
        else
          _warnx "CUDA toolkit present but no sm_120 (need ≥12.8)"
        fi
      else
        _warnx "nvcc not found (CUDA toolkit not installed / not on PATH)."
      fi ;;
    amd)
      if have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; then
        _chk "Vulkan operational:"
        vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName' | sed 's/^/      /' >&2
      else
        _failx "vulkaninfo not working — run 'drivers'."
      fi
      if [[ -n "$(cfg_get AMD_UMA_GB)" ]]; then _chk "Unified-memory budget set: $(cfg_get AMD_UMA_GB) GiB"; else _warnx "AMD VRAM split not configured (optional)."; fi ;;
    *) _warnx "GPU vendor unknown — run 'detect'." ;;
  esac

  # --- secure boot / MOK ---
  if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    if [[ "$(cfg_get NVIDIA_MOK_PENDING 0)" == "1" ]]; then
      _warnx "MOK enrollment PENDING — reboot to a console and enroll, or the NVIDIA module won't load."
    else
      _chk "Secure Boot enabled (module signing OK)."
    fi
  fi

  # --- llama.cpp ---
  local bin; bin="$(cfg_get LLAMACPP_BIN "$INVOKING_HOME/llama.cpp/build/bin/llama-server")"
  if [[ -x "$bin" ]]; then
    _chk "llama.cpp built ($(cfg_get LLAMACPP_BACKEND '?')): $bin"
  else
    _failx "llama.cpp not built — run 'build'."
  fi

  # --- model ---
  local model; model="$(cfg_get LLAMA_MODEL)"
  if [[ -n "$model" && -e "$model" ]]; then _chk "Model present: $model"
  elif [[ -n "$model" ]]; then _warnx "Configured model file missing: $model"
  else _warnx "No model selected — run 'model'."; fi

  # --- service ---
  if systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
    local act; act="$(systemctl is-active llama-server 2>/dev/null)"
    local en;  en="$(systemctl is-enabled llama-server 2>/dev/null)"
    if [[ "$act" == active ]]; then _chk "Service active (boot: ${en})"; else _warnx "Service installed but ${act} (boot: ${en})"; fi
    local port; port="$(cfg_get LLAMA_PORT 8080)"
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      _chk "Health endpoint OK → http://$(cfg_get LLAMA_HOST 0.0.0.0):${port}"
    else
      _warnx "No /health response on :${port} (still loading? check journalctl -u llama-server)."
    fi
  else
    _warnx "Service not installed — run 'service install'."
  fi

  echo >&2
  log_ok "Diagnostics complete."
}
