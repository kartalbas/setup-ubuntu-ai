# shellcheck shell=bash
# modules/55-configure-runtime.sh — set llama-server runtime parameters
# (context, GPU layers, host/port, flash attention, API key, other arguments)
# and persist them. Rendering goes through lib/runtime.sh; an installed
# service is restarted to apply the new settings.
# shellcheck source=/dev/null

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

# _cfg_apply RESTART — render the runtime and show the resulting command. An
# installed service gets its unit re-rendered too (the API-key credential
# lives there); RESTART=1 then restarts it to apply everything now.
_cfg_apply() {
  local restart="$1"
  render_llama_runtime || return 1
  printf '\n%s  Resulting command:%s\n    %s\n\n' "$C_BOLD" "$C_RST" "$(llama_cmdline_preview)" >&2
  if ! llama_unit_installed; then
    log_info "Next: install the service →  sudo ${SCRIPT_PATH##*/} service install"
    return 0
  fi
  render_llama_unit
  run systemctl daemon-reload
  if (( restart )); then
    llama_restart
  else
    log_info "Rendered; ${LLAMA_SERVICE} picks the settings up on its next (re)start."
  fi
}

module_main() {
  log_step "Configure llama-server runtime"

  if [[ -z "$(cfg_get LLAMA_MODEL)" ]]; then
    if [[ -n "${NONINTERACTIVE:-}" ]]; then
      log_error "No model selected (LLAMA_MODEL) — run the model step first."
      return 1
    fi
    log_warn "No model selected yet. Run 'sudo ${SCRIPT_PATH##*/} model' first."
    ui_yesno "Continue and set a model path manually?" || return 0
    local m; m="$(ui_input "Path to a .gguf model file" "$INVOKING_HOME/models/")" || return 0
    cfg_set LLAMA_MODEL "$m"
  fi
  log_info "Model: $(cfg_get LLAMA_MODEL)"
  [[ -n "$(cfg_get LLAMA_MMPROJ)" ]] && log_info "Vision projector: $(cfg_get LLAMA_MMPROJ)"

  # Unattended (restore / resume): the config is the source of truth. Render
  # only — the service step that follows (re)starts the server exactly once.
  if [[ -n "${NONINTERACTIVE:-}" ]]; then
    log_info "Non-interactive: ctx=$(cfg_get LLAMA_CTX 8192) ngl=$(cfg_get LLAMA_NGL 999) host=$(cfg_get LLAMA_HOST 0.0.0.0):$(cfg_get LLAMA_PORT 8080) (from config)"
    _cfg_apply 0
    return
  fi

  local budget; budget="$(gpu_budget_gb)"
  local ctx ngl host port key rest

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
    log_warn "If the server OOMs, lower it and keep flash-attention on."
  fi
  ngl="$(ui_input "GPU layers to offload (999 = all on GPU; lower if it won't fit ${budget}GiB)" "$(cfg_get LLAMA_NGL 999)")" || return 0
  host="$(ui_input "Listen address (0.0.0.0 = reachable on your LAN)" "$(cfg_get LLAMA_HOST 0.0.0.0)")" || return 0
  port="$(ui_input "Port" "$(cfg_get LLAMA_PORT 8080)")" || return 0

  # Keep every stored argument the prompts below don't ask about — profiles
  # rely on e.g. --parallel 1 or the KV-cache types. Only flash attention is
  # asked; an inline --api-key from older configs moves to LLAMA_API_KEY.
  local -a stored=() keep=()
  local i legacy_key=""
  read -ra stored <<<"$(cfg_get LLAMA_EXTRA_ARGS)"
  for (( i = 0; i < ${#stored[@]}; i++ )); do
    case "${stored[i]}" in
      --flash-attn|-fa) case "${stored[i+1]:-}" in on|off|auto) i=$((i + 1)) ;; esac ;;
      --api-key)        legacy_key="${stored[i+1]:-}"; i=$((i + 1)) ;;
      *)                keep+=("${stored[i]}") ;;
    esac
  done

  local extra=""
  if ui_yesno "Enable flash-attention (recommended, faster + less VRAM)?"; then extra="--flash-attn on"; fi

  key="$(cfg_get LLAMA_API_KEY "$legacy_key")"
  if ui_yesno "Require an API key (clients send Authorization: Bearer <key>)?"; then
    local newkey hint="leave blank to keep the current key"
    [[ -z "$key" ]] && hint="required"
    newkey="$(ui_password "API key (${hint})")" || return 0
    [[ -n "$newkey" ]] && key="$newkey"
    if [[ -z "$key" ]]; then log_error "An API key is required when authentication is on."; return 1; fi
  else
    key=""
    [[ "$host" == "0.0.0.0" ]] && log_warn "No API key on 0.0.0.0: anyone on your network can use the API."
  fi

  # Permissive chat template — needed for agentic clients (OpenCode, etc.) that
  # send consecutive same-role turns, and Claude Code, which sends a system
  # message mid-conversation; some stock templates reject both.
  if ui_yesno "Regenerate a permissive chat template from the model (fixes agentic clients' 'roles must alternate' and Claude Code's 'System message must be at the beginning' errors, keeps tool-calls)?"; then
    cfg_set CHAT_TEMPLATE_FIXUP 1
  else
    cfg_set CHAT_TEMPLATE_FIXUP 0
  fi

  rest="$(ui_input "Other llama-server arguments (kept from your config — edit or clear)" "${keep[*]}")" || return 0
  [[ -n "$rest" ]] && extra="${extra:+$extra }${rest}"

  cfg_set LLAMA_CTX "$ctx"
  cfg_set LLAMA_NGL "$ngl"
  cfg_set LLAMA_HOST "$host"
  cfg_set LLAMA_PORT "$port"
  cfg_set LLAMA_EXTRA_ARGS "$extra"
  if [[ -n "$key" ]]; then cfg_set LLAMA_API_KEY "$key"; else cfg_del LLAMA_API_KEY; fi
  cfg_save

  if llama_unit_installed && ui_yesno "Service is installed — restart it now to apply these settings?"; then
    _cfg_apply 1
  else
    _cfg_apply 0
  fi
}
