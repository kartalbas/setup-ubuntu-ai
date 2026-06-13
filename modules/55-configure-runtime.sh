# shellcheck shell=bash
# modules/55-configure-runtime.sh — set llama-server runtime parameters
# (context, GPU layers, host/port, flash-attention, optional API key) and
# persist them. If the service is already installed, offer to apply + restart.
# shellcheck source=/dev/null

LLAMA_ENV_FILE="/etc/setup-ubuntu-ai/llama-server.env"
CHAT_TEMPLATE_DIR="/etc/setup-ubuntu-ai"

# _chat_template_path MODEL — deterministic path for the generated template,
# derived from the model filename so nothing extra needs to be stored.
_chat_template_path() {
  local base; base="$(basename "${1:-model}")"; base="${base%.gguf}"
  printf '%s/%s-template.jinja' "$CHAT_TEMPLATE_DIR" "$base"
}

# regen_chat_template MODEL OUT — extract the chat template embedded in the
# GGUF and neutralise every raise_exception(...) guard, then write OUT.
# Why: the stock Mistral/Devstral template raises on consecutive same-role
# turns ("roles must alternate"), which OpenCode legitimately produces. Each
# guard is an isolated `{{- raise_exception(...) }}` inside an if/else, so
# blanking the call leaves a harmless empty block and keeps all the real
# [INST]/[SYSTEM_PROMPT]/[TOOL_CALLS] handling intact. Derived from the model
# at restore time — never committed. Returns 1 if the GGUF has no template.
regen_chat_template() {
  local model="$1" out="$2" tmpl
  [[ -f "$model" ]] || { log_warn "Model not found for template regen: $model"; return 1; }
  have python3 || { log_warn "python3 needed to regenerate the chat template."; return 1; }
  tmpl="$(python3 - "$model" <<'PY'
import sys, struct, re
f = open(sys.argv[1], 'rb')
if f.read(4) != b'GGUF': sys.exit(1)
struct.unpack('<I', f.read(4)); struct.unpack('<Q', f.read(8))
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
    raise Exception('unknown gguf value type %d' % t)
tmpl = None
for _ in range(n_kv):
    k = rstr(); vt, = struct.unpack('<I', f.read(4)); v = rval(vt)
    if k.endswith('chat_template') and isinstance(v, str): tmpl = v
if not tmpl: sys.exit(2)
# Blank every raise_exception(...) output statement (non-greedy to the `}}`).
tmpl = re.sub(r'\{\{-?\s*raise_exception\(.*?\)\s*-?\}\}', '{# guard removed #}', tmpl, flags=re.S)
sys.stdout.write(tmpl)
PY
)" || { log_warn "GGUF has no embedded chat template (exit $?); leaving template unchanged."; return 1; }
  [[ -n "$tmpl" ]] || return 1
  ensure_dir "$CHAT_TEMPLATE_DIR" 0755
  show_diff "$out" <<<"$tmpl" || true
  printf '%s\n' "$tmpl" | atomic_write "$out"
  log_ok "Chat template regenerated (validation guards neutralised): $out"
}

# _ensure_chat_template — regenerate the permissive template if the config asks
# for it (CHAT_TEMPLATE_FIXUP=1). No-op otherwise.
_ensure_chat_template() {
  [[ "$(cfg_get CHAT_TEMPLATE_FIXUP)" == "1" ]] || return 0
  local model; model="$(cfg_get LLAMA_MODEL)"
  regen_chat_template "$model" "$(_chat_template_path "$model")" \
    || log_warn "Chat-template fixup requested but failed; server may reject consecutive user turns."
}

# _assemble_extra_args — the stored base args plus, when fixup is on, a
# --chat-template-file pointing at the derived path. Keeping the path out of
# the stored value means it can never go stale when the model changes.
_assemble_extra_args() {
  local extra; extra="$(cfg_get LLAMA_EXTRA_ARGS "--flash-attn on")"
  if [[ "$(cfg_get CHAT_TEMPLATE_FIXUP)" == "1" && "$extra" != *"--chat-template-file"* ]]; then
    extra="${extra:+$extra }--chat-template-file $(_chat_template_path "$(cfg_get LLAMA_MODEL)")"
  fi
  printf '%s' "$extra"
}

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

# Write the systemd EnvironmentFile from current CFG values. Regenerates the
# chat template first (if requested) so the --chat-template-file path is valid.
render_llama_env() {
  _ensure_chat_template
  local content
  content="$(cat <<EOF
# Managed by setup-ubuntu-ai — edit then: systemctl restart llama-server
LLAMA_MODEL=$(cfg_get LLAMA_MODEL)
LLAMA_MODEL_DIR=$(cfg_get MODEL_DIR "$INVOKING_HOME/models")
LLAMA_HOST=$(cfg_get LLAMA_HOST 0.0.0.0)
LLAMA_PORT=$(cfg_get LLAMA_PORT 8080)
LLAMA_CTX=$(cfg_get LLAMA_CTX 8192)
LLAMA_NGL=$(cfg_get LLAMA_NGL 999)
LLAMA_EXTRA_ARGS=$(_assemble_extra_args)
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
    "$(_assemble_extra_args)"
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

  # Non-interactive (restore): trust the config verbatim, regenerate the
  # template, write the env file, restart if the service exists.
  if [[ -n "${NONINTERACTIVE:-}" ]]; then
    log_info "Non-interactive: ctx=$(cfg_get LLAMA_CTX 8192) ngl=$(cfg_get LLAMA_NGL 999) host=$(cfg_get LLAMA_HOST 0.0.0.0):$(cfg_get LLAMA_PORT 8080) (from config)"
    render_llama_env
    printf '\n%s  Resulting command:%s\n    %s\n\n' "$C_BOLD" "$C_RST" "$(_cfg_cmdline_preview)" >&2
    if systemctl list-unit-files 2>/dev/null | grep -q '^llama-server.service'; then
      run systemctl restart llama-server && log_ok "Restarted llama-server."
    fi
    return 0
  fi

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

  # Permissive chat template — needed for agentic clients (OpenCode, etc.) that
  # send consecutive same-role turns, which the stock template rejects.
  if ui_yesno "Regenerate a permissive chat template from the model (fixes agentic clients' 'roles must alternate' error, keeps tool-calls)?"; then
    cfg_set CHAT_TEMPLATE_FIXUP 1
  else
    cfg_set CHAT_TEMPLATE_FIXUP 0
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
