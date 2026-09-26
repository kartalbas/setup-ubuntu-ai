# shellcheck shell=bash
# lib/runtime.sh — llama-server's runtime, rendered from the config in ONE
# place: the systemd unit, its EnvironmentFile, the arguments derived from
# other keys (served model name, vision projector, chat template), the API-key
# credential and the optional GPU pin. `configure` and `service install` both
# render through here, so what they write can never disagree.
[[ -n "${_RUNTIME_SH_LOADED:-}" ]] && return 0
_RUNTIME_SH_LOADED=1

# shellcheck disable=SC2034  # read by setup.sh and the build module
LLAMACPP_REPO_DEFAULT="https://github.com/ggml-org/llama.cpp"
LLAMA_SERVICE="llama-server"
LLAMA_UNIT_FILE="${LLAMA_UNIT_FILE:-/etc/systemd/system/${LLAMA_SERVICE}.service}"
LLAMA_ENV_FILE="${LLAMA_ENV_FILE:-/etc/setup-ubuntu-ai/llama-server.env}"
LLAMA_KEY_FILE="${LLAMA_KEY_FILE:-/etc/setup-ubuntu-ai/api-key}"
CHAT_TEMPLATE_DIR="${CHAT_TEMPLATE_DIR:-/etc/setup-ubuntu-ai}"
# Profiles ship this placeholder for LLAMA_API_KEY; deploy.sh replaces it.
API_KEY_PLACEHOLDER="REPLACE_WITH_YOUR_API_KEY"

# ---- engine ----------------------------------------------------------------

# llamacpp_dir — the engine's source/build directory: LLAMACPP_DIR, else
# ~/llama — one place whichever llama.cpp fork LLAMACPP_REPO names (switching
# forks repoints the checkout there).
llamacpp_dir() { cfg_get LLAMACPP_DIR "$INVOKING_HOME/llama"; }

# llama_bin — the llama-server binary the service runs.
llama_bin() { cfg_get LLAMACPP_BIN "$(llamacpp_dir)/build/bin/llama-server"; }

# llama_bin_runs BIN — true if the binary actually executes on THIS machine.
# Presence and +x are not enough: a build from another host can die with
# SIGILL (GGML_NATIVE baked in that CPU's instruction set), and a zero-byte
# stub from an aborted build is "run" by the shell as an empty script that
# exits 0. So require real ELF magic (systemd's execve would reject the stub
# with status 203), then run it.
llama_bin_runs() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  [[ -s "$1" ]] || return 1
  [[ "$(LC_ALL=C head -c4 -- "$1" 2>/dev/null)" == $'\177ELF' ]] || return 1
  "$1" --version >/dev/null 2>&1
}

# ---- chat template (CHAT_TEMPLATE_FIXUP=1) ----------------------------------

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

# ---- arguments -------------------------------------------------------------

# llama_served_name — the model id the API reports: LLAMA_ALIAS, else the GGUF
# file name (llama-server's own default would be the full path).
llama_served_name() {
  local model; model="$(cfg_get LLAMA_MODEL)"
  cfg_get LLAMA_ALIAS "${model##*/}"
}

# llama_runtime_args — the stored LLAMA_EXTRA_ARGS plus the arguments derived
# from other keys. Derived values are never stored, so they cannot go stale
# when the model changes; the same flag in LLAMA_EXTRA_ARGS takes precedence.
llama_runtime_args() {
  local args name mmproj
  args="$(cfg_get LLAMA_EXTRA_ARGS "--flash-attn on")"
  name="$(llama_served_name)"
  if [[ -n "$name" && " $args " != *" --alias "* && " $args " != *" -a "* ]]; then
    args+=" --alias ${name}"
  fi
  mmproj="$(cfg_get LLAMA_MMPROJ)"
  if [[ -n "$mmproj" && " $args " != *" --mmproj "* ]]; then
    args+=" --mmproj ${mmproj}"
  fi
  if [[ "$(cfg_get CHAT_TEMPLATE_FIXUP)" == "1" && " $args " != *" --chat-template-file "* ]]; then
    args+=" --chat-template-file $(_chat_template_path "$(cfg_get LLAMA_MODEL)")"
  fi
  printf '%s' "${args# }"
}

# llama_cmdline_preview — the full command the service runs (key never shown).
llama_cmdline_preview() {
  local keyarg=""
  [[ -n "$(cfg_get LLAMA_API_KEY)" ]] && keyarg=" --api-key-file <credential>"
  printf '%s --model %s --host %s --port %s --ctx-size %s --n-gpu-layers %s %s%s\n' \
    "$(llama_bin)" "$(cfg_get LLAMA_MODEL '<none>')" "$(cfg_get LLAMA_HOST 0.0.0.0)" \
    "$(cfg_get LLAMA_PORT 8080)" "$(cfg_get LLAMA_CTX 8192)" "$(cfg_get LLAMA_NGL 999)" \
    "$(llama_runtime_args)" "$keyarg" | redact_secrets
}

# ---- API key ---------------------------------------------------------------

# api_key_problem — print why LLAMA_API_KEY cannot be served; nothing if it
# can (an empty key is valid: the API is then open to everyone).
api_key_problem() {
  local key; key="$(cfg_get LLAMA_API_KEY)"
  if [[ "$key" == "$API_KEY_PLACEHOLDER" ]]; then
    echo "LLAMA_API_KEY is still the ${API_KEY_PLACEHOLDER} placeholder"
  elif [[ "$key" == *[[:space:]\"]* ]]; then
    echo "LLAMA_API_KEY must not contain whitespace or quotes"
  fi
  return 0
}

# _render_api_key — the file the service loads as a systemd credential:
# root-only, never on a command line, in the environment or in a diff.
_render_api_key() {
  local key; key="$(cfg_get LLAMA_API_KEY)"
  if [[ -z "$key" ]]; then
    if [[ -e "$LLAMA_KEY_FILE" ]]; then run rm -f "$LLAMA_KEY_FILE"; fi
    return 0
  fi
  ensure_dir "$(dirname "$LLAMA_KEY_FILE")" 0755
  printf '%s\n' "$key" | atomic_write "$LLAMA_KEY_FILE" 0600 1
  log_ok "API key stored for the service (root-only credential): ${LLAMA_KEY_FILE}"
}

# ---- GPU pin (LLAMA_GPU) ---------------------------------------------------

# _cuda_index_of PCI_ADDR — CUDA index of that NVIDIA GPU under
# CUDA_DEVICE_ORDER=PCI_BUS_ID (ascending bus id). Passive — reads sysfs only,
# never nvidia-smi — so it cannot poke a flaky eGPU link.
_cuda_index_of() {
  local target="$1" d i=0
  for d in /sys/bus/pci/devices/*/; do
    [[ "$(cat "$d/vendor" 2>/dev/null)" == "0x10de" ]] || continue
    [[ "$(cat "$d/class"  2>/dev/null)" == 0x030* ]]  || continue
    [[ "$(basename "$d")" == "$target" ]] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# _gpu_pin_lines — EnvironmentFile lines pinning llama-server to LLAMA_GPU:
#   all / unset   -> no pin (llama.cpp uses every visible GPU)
#   egpu          -> the detected external GPU (gpu_pci_addr, prefers removable)
#   0000:bb:dd.f  -> that explicit PCI address
# Pinning avoids splitting the model across an unwanted second GPU and keeps
# the choice reproducible across reboots.
_gpu_pin_lines() {
  local pin target idx
  pin="$(cfg_get LLAMA_GPU all)"
  [[ "$pin" == all || -z "$pin" ]] && return 0
  case "$pin" in
    egpu) target="$(gpu_pci_addr 2>/dev/null)" ;;
    *)    target="$pin" ;;
  esac
  [[ -n "$target" ]] || return 0
  if idx="$(_cuda_index_of "$target")"; then
    log_info "Pinning llama-server to GPU ${target} (CUDA index ${idx})."
    printf 'CUDA_DEVICE_ORDER=PCI_BUS_ID\nCUDA_VISIBLE_DEVICES=%s\n' "$idx"
  else
    log_warn "Could not map LLAMA_GPU='${pin}' to a CUDA index; leaving all GPUs visible."
  fi
}

# ---- rendering -------------------------------------------------------------

# llama_unit_installed — true once `service install` has written the unit.
llama_unit_installed() { [[ -f "$LLAMA_UNIT_FILE" ]]; }

# render_llama_runtime — write what the service reads when it starts: the chat
# template (CHAT_TEMPLATE_FIXUP=1), the API-key credential and the
# EnvironmentFile. Refuses an unusable key rather than serving with it.
render_llama_runtime() {
  local problem; problem="$(api_key_problem)"
  if [[ -n "$problem" ]]; then
    log_error "${problem} — set it in ${CONFIG_FILE}, or deploy with: sudo ./deploy.sh <profile> --key KEY"
    return 1
  fi
  _ensure_chat_template
  _render_api_key
  _render_llama_env
}

_render_llama_env() {
  local content pin
  pin="$(_gpu_pin_lines)"
  content="$(cat <<EOF
# Managed by setup-ubuntu-ai — edit the config, then: sudo ./setup.sh configure
LLAMA_MODEL=$(cfg_get LLAMA_MODEL)
LLAMA_HOST=$(cfg_get LLAMA_HOST 0.0.0.0)
LLAMA_PORT=$(cfg_get LLAMA_PORT 8080)
LLAMA_CTX=$(cfg_get LLAMA_CTX 8192)
LLAMA_NGL=$(cfg_get LLAMA_NGL 999)
LLAMA_EXTRA_ARGS=$(llama_runtime_args)
EOF
)"
  [[ -n "$pin" ]] && content+=$'\n'"$pin"
  ensure_dir "$(dirname "$LLAMA_ENV_FILE")" 0755
  show_diff "$LLAMA_ENV_FILE" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$LLAMA_ENV_FILE" 0600
}

# render_llama_unit — the systemd unit. With an API key the key file is loaded
# as a credential (%d is the service's private credentials directory).
render_llama_unit() {
  local tmpl="$REPO_ROOT/services/${LLAMA_SERVICE}.service.tmpl" cred keyarg content
  [[ -f "$tmpl" ]] || die "Missing template: $tmpl"
  cred="# No API key configured (LLAMA_API_KEY): every client is accepted."
  keyarg=""
  if [[ -n "$(cfg_get LLAMA_API_KEY)" ]]; then
    cred="LoadCredential=api-key:${LLAMA_KEY_FILE}"
    keyarg=" --api-key-file %d/api-key"
  fi
  content="$(sed -e "s|@USER@|${INVOKING_USER}|g" -e "s|@BIN@|$(llama_bin)|g" \
                 -e "s|@ENVFILE@|${LLAMA_ENV_FILE}|g" -e "s|@CREDENTIAL@|${cred}|g" \
                 -e "s|@KEYARG@|${keyarg}|g" "$tmpl")"
  show_diff "$LLAMA_UNIT_FILE" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$LLAMA_UNIT_FILE" 0644
}

# llama_restart — restart the service (after a daemon-reload) and wait until
# the model has loaded.
llama_restart() {
  run systemctl restart "${LLAMA_SERVICE}.service" || return 1
  llama_wait_healthy
}

# llama_wait_healthy [TIMEOUT_S] — poll /health until the model has loaded;
# fail fast if the service dies meanwhile.
llama_wait_healthy() {
  local timeout="${1:-300}" port waited=0
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  port="$(cfg_get LLAMA_PORT 8080)"
  log_info "Waiting for llama-server on :${port} (loading the model takes a while)…"
  while (( waited < timeout )); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      log_ok "llama-server is healthy on :${port} (after ${waited}s)."
      return 0
    fi
    if ! systemctl is-active --quiet "${LLAMA_SERVICE}.service"; then
      log_error "llama-server stopped while loading — see: journalctl -u ${LLAMA_SERVICE} -e"
      return 1
    fi
    sleep 3; waited=$((waited + 3))
  done
  log_error "llama-server did not become healthy within ${timeout}s — see: journalctl -u ${LLAMA_SERVICE} -e"
  return 1
}
