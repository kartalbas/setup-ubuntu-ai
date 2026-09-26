# shellcheck shell=bash
# modules/90-doctor.sh — read-only health check of the whole stack.
# shellcheck source=/dev/null

_chk()  { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
_warnx(){ printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
_failx(){ printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

# _dr_http METHOD PATH [KEY] [BODY] — HTTP status of a request to the local
# server. The key goes in via stdin, so it never shows up in the process list.
_dr_http() {
  local url; url="http://127.0.0.1:$(cfg_get LLAMA_PORT 8080)$2"
  local -a args=(-s -o /dev/null -w '%{http_code}' --max-time 10 -X "$1" -H 'Content-Type: application/json')
  [[ -n "${4:-}" ]] && args+=(-d "$4")
  if [[ -n "${3:-}" ]]; then
    printf 'Authorization: Bearer %s\n' "$3" | curl "${args[@]}" -H @- "$url"
  else
    curl "${args[@]}" "$url"
  fi
}

# _dr_lan_addr — the address other machines (and the platform ingress) reach
# this host on: the source address of its default route.
_dr_lan_addr() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

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
      local nvcc sm; nvcc="$(command -v nvcc 2>/dev/null || echo /usr/local/cuda/bin/nvcc)"; sm="$(cfg_get HW_SM)"
      if [[ -x "$nvcc" ]]; then
        _chk "CUDA toolkit $("$nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p')"
        if [[ -n "$sm" ]] && ! "$nvcc" --list-gpu-arch 2>/dev/null | grep -q "compute_${sm}"; then
          _warnx "The CUDA toolkit cannot compile for sm_${sm}."
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

  # --- engine ---
  local bin; bin="$(llama_bin)"
  if llama_bin_runs "$bin"; then
    local rev; rev="$(cfg_get LLAMACPP_BUILT_REV)"
    _chk "Engine runs: ${bin}${rev:+ (${rev:0:9})}"
    local cudart; cudart="$(ldd "$(dirname "$bin")/libggml-cuda.so" 2>/dev/null | awk '/libcudart\.so/ {print $3; exit}')"
    [[ -n "$cudart" ]] && _chk "CUDA runtime used by the engine: $(readlink -f "$cudart")"
  elif [[ -e "$bin" ]]; then
    _failx "Engine present but does not run here: ${bin} — run 'build'."
  else
    _failx "Engine not built — run 'build'."
  fi

  # --- model ---
  local model mmproj; model="$(cfg_get LLAMA_MODEL)"; mmproj="$(cfg_get LLAMA_MMPROJ)"
  if [[ -n "$model" && -e "$model" ]]; then _chk "Model present: $model"
  elif [[ -n "$model" ]]; then _failx "Configured model file missing: $model"
  else _warnx "No model selected — run 'model'."; fi
  if [[ -n "$mmproj" ]]; then
    if [[ -e "$mmproj" ]]; then _chk "Vision projector present: $mmproj"; else _failx "Vision projector missing: $mmproj"; fi
  fi

  # --- API key ---
  local key=""
  if [[ -n "$(cfg_get LLAMA_API_KEY)" ]]; then
    if [[ -f "$LLAMA_KEY_FILE" && "$(stat -c %a "$LLAMA_KEY_FILE" 2>/dev/null)" == 600 ]]; then
      _chk "API key: root-only credential ${LLAMA_KEY_FILE}"
      key="$(head -1 "$LLAMA_KEY_FILE" 2>/dev/null)"
    else
      _failx "API key configured but ${LLAMA_KEY_FILE} is missing or not mode 600 — run 'configure'."
    fi
  else
    _warnx "No API key (LLAMA_API_KEY): the API accepts every client."
  fi

  # --- service ---
  if llama_unit_installed; then
    local act en; act="$(systemctl is-active "$LLAMA_SERVICE" 2>/dev/null)"; en="$(systemctl is-enabled "$LLAMA_SERVICE" 2>/dev/null)"
    if [[ "$act" == active ]]; then _chk "Service active (boot: ${en})"; else _warnx "Service installed but ${act} (boot: ${en})"; fi
    if [[ "$(_dr_http GET /health)" == 200 ]]; then
      _chk "Health endpoint OK → http://$(cfg_get LLAMA_HOST 0.0.0.0):$(cfg_get LLAMA_PORT 8080)"
      local lan health ui; lan="$(_dr_lan_addr)"
      if [[ -n "$lan" ]]; then
        health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${lan}:$(cfg_get LLAMA_PORT 8080)/health")"
        ui="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${lan}:$(cfg_get LLAMA_PORT 8080)/")"
        if [[ "$health" == 200 && "$ui" == 200 ]]; then
          _chk "Reachable for the ingress on the LAN address: http://${lan}:$(cfg_get LLAMA_PORT 8080) (/health, web UI /)"
        else
          _failx "On the LAN address ${lan}:$(cfg_get LLAMA_PORT 8080): /health → ${health}, web UI / → ${ui}"
        fi
      fi
      if [[ -n "$key" ]]; then
        local open authd; open="$(_dr_http POST /v1/chat/completions "" '{}')"; authd="$(_dr_http GET /v1/models "$key")"
        if [[ "$open" == 401 && "$authd" == 200 ]]; then _chk "Auth enforced (no key → 401, key → 200)"
        else _failx "Auth check failed (no key → ${open}, key → ${authd})"; fi
      fi
    else
      _warnx "No /health response (still loading? check journalctl -u ${LLAMA_SERVICE})."
    fi
  else
    _warnx "Service not installed — run 'service install'."
  fi

  echo >&2
  log_ok "Diagnostics complete."
}
