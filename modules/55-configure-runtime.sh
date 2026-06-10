# shellcheck shell=bash
# modules/55-configure-runtime.sh — set llama-server runtime parameters
# (context, GPU layers, host/port, flash-attention, optional API key) and
# persist them. If the service is already installed, offer to apply + restart.
# shellcheck source=/dev/null

LLAMA_ENV_FILE="/etc/setup-ubuntu-ai/llama-server.env"

# _model_max_ctx PATH — read the model's native (max trained) context length
# straight from the GGUF metadata header (no model load). Prints the integer,
# or nothing if it can't be determined.
_model_max_ctx() {
  local model="$1"
  [[ -f "$model" ]] || return 1
  have python3 || return 1
  python3 - "$model" <<'PY' 2>/dev/null
import sys, struct
try:
    f = open(sys.argv[1], 'rb')
    if f.read(4) != b'GGUF': sys.exit(0)
    struct.unpack('<I', f.read(4))           # version
    struct.unpack('<Q', f.read(8))           # tensor count
    n_kv, = struct.unpack('<Q', f.read(8))
    def rstr():
        ln, = struct.unpack('<Q', f.read(8)); return f.read(ln).decode('utf-8','replace')
    M = {0:('<B',1),1:('<b',1),2:('<H',2),3:('<h',2),4:('<I',4),5:('<i',4),
         6:('<f',4),7:('<?',1),10:('<Q',8),11:('<q',8),12:('<d',8)}
    def rval(t):
        if t in M: fmt,sz = M[t]; return struct.unpack(fmt, f.read(sz))[0]
        if t == 8: return rstr()
        if t == 9:
            et, = struct.unpack('<I', f.read(4)); ln, = struct.unpack('<Q', f.read(8))
            return [rval(et) for _ in range(ln)]
        raise Exception('type')
    ctx = None
    for _ in range(n_kv):
        k = rstr(); vt, = struct.unpack('<I', f.read(4)); v = rval(vt)
        if k.endswith('.context_length'): ctx = v
    if ctx is not None: print(int(ctx))
except Exception:
    pass
PY
}

# Write the systemd EnvironmentFile from current CFG values.
render_llama_env() {
  local content
  content="$(cat <<EOF
# Managed by setup-ubuntu-ai — edit then: systemctl restart llama-server
LLAMA_MODEL=$(cfg_get LLAMA_MODEL)
LLAMA_MODEL_DIR=$(cfg_get MODEL_DIR "$INVOKING_HOME/models")
LLAMA_HOST=$(cfg_get LLAMA_HOST 0.0.0.0)
LLAMA_PORT=$(cfg_get LLAMA_PORT 8080)
LLAMA_CTX=$(cfg_get LLAMA_CTX 8192)
LLAMA_NGL=$(cfg_get LLAMA_NGL 999)
LLAMA_EXTRA_ARGS=$(cfg_get LLAMA_EXTRA_ARGS "--flash-attn on")
EOF
)"
  ensure_dir "$(dirname "$LLAMA_ENV_FILE")" 0755
  show_diff "$LLAMA_ENV_FILE" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$LLAMA_ENV_FILE"
}

_cfg_cmdline_preview() {
  printf '%s --model %s --host %s --port %s --ctx-size %s --n-gpu-layers %s %s\n' \
    "$(cfg_get LLAMACPP_BIN "$INVOKING_HOME/llama.cpp/build/bin/llama-server")" \
    "$(cfg_get LLAMA_MODEL '<none>')" \
    "$(cfg_get LLAMA_HOST 0.0.0.0)" "$(cfg_get LLAMA_PORT 8080)" \
    "$(cfg_get LLAMA_CTX 8192)" "$(cfg_get LLAMA_NGL 999)" \
    "$(cfg_get LLAMA_EXTRA_ARGS '--flash-attn')"
}

module_main() {
  log_step "Configure llama-server runtime"

  if [[ -z "$(cfg_get LLAMA_MODEL)" ]]; then
    log_warn "No model selected yet. Run 'sudo ${SCRIPT_PATH##*/} model' first."
    ui_yesno "Continue and set a model path manually?" || return 0
    local m; m="$(ui_input "Path to a .gguf model file" "$INVOKING_HOME/models/")" || return 0
    cfg_set LLAMA_MODEL "$m"
  fi
  log_info "Model: $(cfg_get LLAMA_MODEL)"

  local budget; budget="$(gpu_budget_gb)"
  local ctx ngl host port apikey extra

  # Read the model's native (max) context from the GGUF and default to it.
  local maxctx def_ctx
  maxctx="$(_model_max_ctx "$(cfg_get LLAMA_MODEL)")" || true
  if [[ -n "$maxctx" ]]; then
    log_info "Model native (max) context: ${maxctx} tokens"
    def_ctx="$(cfg_get LLAMA_CTX "$maxctx")"      # default to the model's max
  else
    log_warn "Could not read the model's max context from its GGUF; using a safe default."
    def_ctx="$(cfg_get LLAMA_CTX 8192)"
  fi
  ctx="$(ui_input "Context size in tokens (model max: ${maxctx:-unknown}; 0 = auto = model max). Big context = lots of VRAM for the KV cache." "$def_ctx")" || return 0
  if [[ "$ctx" =~ ^[0-9]+$ ]] && { (( ctx == 0 )) || (( ctx > 32768 )); }; then
    log_warn "Context ${ctx} (0 = model max ${maxctx:-?}) is large — its KV cache may exceed your ~${budget}GiB VRAM and force CPU offload or fail to load."
    log_warn "If the server OOMs, lower it (try 16384–32768) and keep flash-attention on."
  fi
  ngl="$(ui_input "GPU layers to offload (999 = all on GPU; lower if it won't fit ${budget}GiB)" "$(cfg_get LLAMA_NGL 999)")" || return 0
  host="$(ui_input "Listen address (0.0.0.0 = reachable on your LAN)" "$(cfg_get LLAMA_HOST 0.0.0.0)")" || return 0
  port="$(ui_input "Port" "$(cfg_get LLAMA_PORT 8080)")" || return 0

  extra=""
  if ui_yesno "Enable flash-attention (recommended, faster + less VRAM)?"; then extra="--flash-attn on"; fi

  if [[ "$host" == "0.0.0.0" ]]; then
    log_warn "Binding 0.0.0.0 exposes the API to your whole LAN with NO authentication."
    if ui_yesno "Protect it with an API key (clients must send Authorization: Bearer <key>)?"; then
      apikey="$(ui_password "API key (leave blank to auto-skip)")" || apikey=""
      [[ -n "$apikey" ]] && extra="${extra:+$extra }--api-key ${apikey}"
    fi
  fi

  cfg_set LLAMA_CTX "$ctx"
  cfg_set LLAMA_NGL "$ngl"
  cfg_set LLAMA_HOST "$host"
  cfg_set LLAMA_PORT "$port"
  cfg_set LLAMA_EXTRA_ARGS "$extra"
  cfg_save

  printf '\n%s  Resulting command:%s\n    %s\n\n' "$C_BOLD" "$C_RST" "$(_cfg_cmdline_preview)" >&2

  render_llama_env

  if systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
    if ui_yesno "Service is installed — restart it now to apply these settings?"; then
      run systemctl restart llama-server
      log_ok "Restarted llama-server with new settings."
    fi
  else
    log_info "Next: install the service →  sudo ${SCRIPT_PATH##*/} service install"
  fi
}
