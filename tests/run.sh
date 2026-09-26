#!/usr/bin/env bash
# tests/run.sh — behavioural tests for setup-ubuntu-ai. Runs unprivileged in a
# throwaway sandbox: modules are sourced the way setup.sh sources them, with
# systemctl, curl, apt, cmake and the Hugging Face CLI stubbed out. Nothing
# outside the sandbox is touched.
#
# Usage: tests/run.sh          (KEEP=1 keeps the sandbox for inspection)
#
# Test conditions are single-quoted on purpose: t() evaluates them later.
# Stubs are called by the sourced modules; conditions read variables later.
# shellcheck disable=SC2016,SC1090,SC2329,SC2034
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d)"
[[ -n "${KEEP:-}" ]] || trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/etc" "$SB/systemd" "$SB/state" "$SB/home/models"

export LOG_FILE="$SB/install.log" CONFIG_FILE="$SB/etc/config.conf" STATE_DIR="$SB/state"
export LLAMA_ENV_FILE="$SB/etc/llama-server.env" LLAMA_KEY_FILE="$SB/etc/api-key"
export LLAMA_UNIT_FILE="$SB/systemd/llama-server.service" CHAT_TEMPLATE_DIR="$SB/etc"
export RESUME_UNIT_FILE="$SB/systemd/setup-ubuntu-ai-resume.service"
export NO_COLOR=1 NO_UI=1 QUIET=1 REPO_ROOT="$ROOT" SCRIPT_PATH="$ROOT/setup.sh"
LIBS="$(sed -n 's/^for _lib in \(.*\); do$/\1/p' "$ROOT/setup.sh")"
OUT="$SB/out.log"

PASS=0; FAIL=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
t()   { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # t NAME CONDITION
section() { printf '\n%s\n' "$1"; }

# load — source the libraries like setup.sh, then stub the outside world.
# Call inside a subshell (lib/core.sh switches on strict mode).
load() {
  local l
  for l in $LIBS; do . "$ROOT/lib/$l.sh"; done
  set +e; trap - ERR
  INVOKING_USER="$(id -un)"; INVOKING_HOME="$SB/home"
  systemctl()   { echo "systemctl $*" >>"$SB/calls.log"; return 0; }
  curl()        { return 0; }
  apt_install() { echo "apt_install $*" >>"$SB/calls.log"; return 0; }
}
write_cfg() { local kv; for kv in "$@"; do printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}"; done >"$CONFIG_FILE"; }
cfg_value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$CONFIG_FILE"; }

# A minimal GGUF: architecture, native context and a chat template with the
# raise_exception guard CHAT_TEMPLATE_FIXUP removes.
python3 - "$SB/home/models/m.gguf" <<'PY'
import struct, sys
def s(x): b = x.encode(); return struct.pack('<Q', len(b)) + b
kv = [('general.architecture', 8, s('qwen35')),
      ('qwen35.context_length', 4, struct.pack('<I', 262144)),
      ('tokenizer.chat_template', 8, s("{%- for message in messages %}{%- set content = message.content %}"
          "{%- if message.role == 'system' %}{%- if not loop.first %}{{- raise_exception('System message must be at the beginning.') }}"
          "{%- endif %}{%- else %}{{- '<|im_start|>' + message.role + '\\n' + content + '<|im_end|>\\n' }}{%- endif %}{%- endfor %}"
          "{%- if x %}{{- raise_exception('roles must alternate') }}{%- endif %}OK"))]
with open(sys.argv[1], 'wb') as f:
    f.write(b'GGUF' + struct.pack('<I', 3) + struct.pack('<Q', 0) + struct.pack('<Q', len(kv)))
    for k, t, v in kv: f.write(s(k) + struct.pack('<I', t) + v)
PY
: >"$SB/home/models/mmproj.gguf"
MODEL="$SB/home/models/m.gguf"; MMPROJ="$SB/home/models/mmproj.gguf"
GPU=""
for d in /sys/bus/pci/devices/*/; do
  [[ "$(cat "$d/vendor" 2>/dev/null)" == 0x10de && "$(cat "$d/class" 2>/dev/null)" == 0x030* ]] && { GPU="$(basename "$d")"; break; }
done

# ---------------------------------------------------------------------------
section "runtime: configure and service install render ONE consistent setup"
KEY='k+/e=y&1'
write_cfg "LLAMA_MODEL=$MODEL" "LLAMA_MMPROJ=$MMPROJ" "CHAT_TEMPLATE_FIXUP=1" \
  "LLAMA_CTX=65536" "LLAMACPP_BIN=/bin/true" "LLAMA_API_KEY=$KEY" \
  "LLAMA_EXTRA_ARGS=--flash-attn on --parallel 1" ${GPU:+"LLAMA_GPU=$GPU"}
( load; cfg_load; . "$ROOT/modules/55-configure-runtime.sh"; NONINTERACTIVE=1 module_main ) >>"$OUT" 2>&1
t "configure: env carries --alias, --mmproj and --chat-template-file" \
  'grep -q -- "--alias m.gguf" "$LLAMA_ENV_FILE" && grep -q -- "--mmproj $MMPROJ" "$LLAMA_ENV_FILE" && grep -q -- "--chat-template-file $SB/etc/m-template.jinja" "$LLAMA_ENV_FILE"'
t "configure: template regenerated without raise_exception" \
  '[[ -s "$SB/etc/m-template.jinja" ]] && ! grep -q raise_exception "$SB/etc/m-template.jinja"'
if python3 -c 'import jinja2' 2>/dev/null; then
  t "configure: a later system message renders as a system turn (Claude Code)" \
    '[[ "$(python3 -c "import jinja2, sys; print(jinja2.Template(open(sys.argv[1]).read()).render(messages=[{\"role\": \"user\", \"content\": \"hi\"}, {\"role\": \"system\", \"content\": \"ENV\"}]))" "$SB/etc/m-template.jinja")" == *"<|im_start|>system"*ENV*"<|im_end|>"* ]]'
fi
t "configure: no unit rendered before 'service install'" '[[ ! -e "$LLAMA_UNIT_FILE" ]]'
( load; cfg_load; . "$ROOT/modules/60-service-llama.sh"; module_main install ) >>"$OUT" 2>&1
t "service install: env still carries the derived args" \
  'grep -q -- "--mmproj $MMPROJ" "$LLAMA_ENV_FILE" && grep -q -- "--chat-template-file" "$LLAMA_ENV_FILE"'
[[ -n "$GPU" ]] && t "service install: GPU pin present" 'grep -q "^CUDA_VISIBLE_DEVICES=" "$LLAMA_ENV_FILE"'
t "unit loads the key as a systemd credential" 'grep -qx "LoadCredential=api-key:$LLAMA_KEY_FILE" "$LLAMA_UNIT_FILE"'
t "unit passes --api-key-file %d/api-key" 'grep -q -- " --api-key-file %d/api-key$" "$LLAMA_UNIT_FILE"'
t "unit orders after the NVIDIA persistence + power-limit units" \
  'grep -q "^After=.*nvidia-persistenced.service nvidia-powerlimit.service" "$LLAMA_UNIT_FILE"'
t "key file holds exactly the key, mode 600" '[[ "$(cat "$LLAMA_KEY_FILE")" == "$KEY" && "$(stat -c %a "$LLAMA_KEY_FILE")" == 600 ]]'
t "env file and config are mode 600" '[[ "$(stat -c %a "$LLAMA_ENV_FILE")" == 600 && "$(stat -c %a "$CONFIG_FILE")" == 600 ]]'
t "the key appears in no other rendered file or output" '! grep -rqF -- "$KEY" "$LLAMA_ENV_FILE" "$LLAMA_UNIT_FILE" "$OUT"'
t "service install enables and restarts (not enable --now)" \
  'grep -q "systemctl enable llama-server.service" "$SB/calls.log" && grep -q "systemctl restart llama-server.service" "$SB/calls.log"'
( load; cfg_load; . "$ROOT/modules/55-configure-runtime.sh"; NONINTERACTIVE=1 module_main ) >>"$OUT" 2>&1
[[ -n "$GPU" ]] && t "re-configure keeps the GPU pin" 'grep -q "^CUDA_VISIBLE_DEVICES=" "$LLAMA_ENV_FILE"'

# ---------------------------------------------------------------------------
section "configure (interactive) keeps what it does not ask about"
write_cfg "LLAMA_MODEL=$MODEL" "LLAMA_HOST=0.0.0.0" "LLAMA_CTX=90112" "CHAT_TEMPLATE_FIXUP=0" \
  "LLAMACPP_BIN=/bin/true" "LLAMA_EXTRA_ARGS=--flash-attn on --parallel 1 --cache-type-k turbo8 --no-mmap --api-key LEGACY"
( load; cfg_load; . "$ROOT/modules/55-configure-runtime.sh"
  ui_input()    { printf '%s' "$2"; }          # accept every default
  ui_password() { printf ''; }                 # blank = keep the current key
  ui_yesno()    { case "$1" in *flash*|*"API key"*) return 0 ;; *) return 1 ;; esac; }
  module_main ) >>"$OUT" 2>&1
t "unasked args survive" '[[ "$(cfg_value LLAMA_EXTRA_ARGS)" == "--flash-attn on --parallel 1 --cache-type-k turbo8 --no-mmap" ]]'
t "an inline --api-key moves to LLAMA_API_KEY" '[[ "$(cfg_value LLAMA_API_KEY)" == LEGACY ]]'
t "the unit is re-rendered with the credential" 'grep -q "^LoadCredential=" "$LLAMA_UNIT_FILE"'
( load; cfg_load; . "$ROOT/modules/55-configure-runtime.sh"
  ui_input()    { printf '%s' "$2"; }
  ui_yesno()    { case "$1" in *flash*) return 0 ;; *) return 1 ;; esac; }
  module_main ) >>"$OUT" 2>&1
t "declining the key removes it, its file and the credential" \
  '[[ -z "$(cfg_value LLAMA_API_KEY)" && ! -e "$LLAMA_KEY_FILE" ]] && ! grep -q "^LoadCredential=" "$LLAMA_UNIT_FILE"'

# ---------------------------------------------------------------------------
section "API key safety"
write_cfg "LLAMA_MODEL=$MODEL" "LLAMACPP_BIN=/bin/true" "LLAMA_API_KEY=REPLACE_WITH_YOUR_API_KEY"
( load; cfg_load; render_llama_runtime ) >>"$OUT" 2>&1; rc=$?
t "the profile placeholder is refused" '[[ $rc -ne 0 && ! -e "$LLAMA_KEY_FILE" ]]'
printf 'X=--api-key OLDSECRET\n' >"$SB/diffme"
( load; show_diff "$SB/diffme" <<<'X=--api-key NEWSECRET' ) >"$SB/diff.out" 2>&1
t "diffs mask inline keys" '! grep -qE "OLDSECRET|NEWSECRET" "$SB/diff.out" && grep -q "<redacted>" "$SB/diff.out"'

# ---------------------------------------------------------------------------
section "config show | set"
write_cfg "LLAMA_MODEL=$MODEL" "LLAMA_API_KEY=secret123"
eval "$(sed -n '/^cmd_config() {/,/^}/p' "$ROOT/setup.sh")"
( load; cfg_load; cmd_config set CHAT_TEMPLATE_FIXUP 1 ) >>"$OUT" 2>&1
t "config set changes one key and keeps the rest" '[[ "$(cfg_value CHAT_TEMPLATE_FIXUP)" == 1 && "$(cfg_value LLAMA_API_KEY)" == secret123 ]]'
t "config show hides the API key" '( load; cmd_config show ) 2>/dev/null | grep -q "LLAMA_API_KEY=\"<hidden>\"" && ! ( load; cmd_config show ) 2>/dev/null | grep -q secret123'
( load; cfg_load; cmd_config set CHAT_TEMPLATE_FIXUP 'a"b' ) >>"$OUT" 2>&1; rc=$?
t "config set refuses quotes" '[[ $rc -ne 0 ]]'

# ---------------------------------------------------------------------------
section "configs: your own config repository"
write_cfg "LLAMA_MODEL=$MODEL"
( load; cfg_load; ASSUME_YES=1 configs_run save ) >>"$OUT" 2>&1; rc=$?
t "unattended without CONFIGS_REPO it stops instead of asking" '[[ $rc -ne 0 ]] && grep -q "No CONFIGS_REPO" "$OUT"'
( load; cfg_load; INVOKING_USER=root configs_run save ) >>"$OUT" 2>&1; rc=$?
t "it refuses to clone and push as root" '[[ $rc -ne 0 ]] && grep -q "from your own account" "$OUT"'

# ---------------------------------------------------------------------------
section "resume after a reboot keeps the mode the run started in"
resume_mode() {   # prints the NONINTERACTIVE/ASSUME_YES cmd_resume hands on
  ( load; cfg_load; resume_cleanup() { :; }
    guided_all() { echo "NONINTERACTIVE=${NONINTERACTIVE:-} ASSUME_YES=${ASSUME_YES:-}"; }
    eval "$(sed -n '/^cmd_resume() {/,/^}/p' "$ROOT/setup.sh")"; cmd_resume ) 2>/dev/null
}
( load; cfg_load; NONINTERACTIVE=1 ASSUME_YES=1 schedule_resume drivers ) >>"$OUT" 2>&1
t "an unattended restore resumes unattended" '[[ "$(resume_mode)" == "NONINTERACTIVE=1 ASSUME_YES=1" ]]'
( load; cfg_load; schedule_resume build ) >>"$OUT" 2>&1
t "an interactive run resumes interactively" '[[ "$(resume_mode)" == "NONINTERACTIVE= ASSUME_YES=" ]]'

# ---------------------------------------------------------------------------
section "build: staged, verified, swapped in; rollback; incremental"
UP="$SB/upstream"; git init -q "$UP"; echo 'project(x)' >"$UP/CMakeLists.txt"
git -C "$UP" add . && git -C "$UP" -c user.name=t -c user.email=t@t commit -qm one
LC="$SB/home/engine"; mkdir -p "$LC/build/bin"
printf '#!/bin/sh\nexit 0\n' >"$LC/build/bin/llama-server"; chmod +x "$LC/build/bin/llama-server"
write_cfg "HW_VENDOR=nvidia" "HW_SM=120" "LLAMACPP_REPO=$UP" "LLAMACPP_DIR=$LC" "LLAMACPP_PREBUILT=1"
build() {   # build [ARGS] — run the build module with cmake/toolchain stubs
  ( load; cfg_load; . "$ROOT/modules/40-build-llamacpp.sh"
    _lc_nvcc() { printf /usr/bin/true; }; _lc_install_deps() { :; }; _lc_cuda_turbo_guard() { :; }
    cmake() {   # configure records the tree's path; build yields a runnable ELF
      if [[ "$1" == --build ]]; then echo "build $2" >>"$SB/cmake.log"; mkdir -p "$2/bin"; cp /bin/true "$2/bin/llama-server"; return; fi
      local s="" b=""; while (( $# )); do case "$1" in -S) s="$2" ;; -B) b="$2" ;; esac; shift; done
      [[ -f "$s/CMakeLists.txt" ]] || return 1
      echo "configure $b" >>"$SB/cmake.log"; mkdir -p "$b"; echo "CMAKE_CACHEFILE_DIR:INTERNAL=$b" >"$b/CMakeCache.txt"
    }
    module_main "$@" ) >>"$OUT" 2>&1
}
is_elf() { [[ "$(head -c4 "$1" 2>/dev/null)" == $'\177ELF' ]]; }
build; rc=$?
t "a staged prebuilt that does not run falls back to a source build" '(( rc == 0 )) && is_elf "$LC/build/bin/llama-server"'
t "the source was checked out into the prebuilt's directory (init + fetch)" '[[ -f "$LC/CMakeLists.txt" && -d "$LC/.git" ]]'
t "the rejected prebuilt is kept as build-prev" '! is_elf "$LC/build-prev/bin/llama-server"'
t "the built revision is recorded" '[[ "$(cfg_value LLAMACPP_BUILT_REV)" == "$(git -C "$UP" rev-parse HEAD)" ]]'
: >"$SB/cmake.log"; build
t "an unchanged source is not rebuilt" '[[ ! -s "$SB/cmake.log" ]]'
build --rollback
t "--rollback swaps the previous engine back" '! is_elf "$LC/build/bin/llama-server" && is_elf "$LC/build-prev/bin/llama-server"'
build --rollback
t "rolling back twice restores the new engine" 'is_elf "$LC/build/bin/llama-server"'
touch "$LC/build/marker"
git -C "$UP" -c user.name=t -c user.email=t@t commit -qm two --allow-empty; build
git -C "$UP" -c user.name=t -c user.email=t@t commit -qm three --allow-empty; build
t "builds recycle the previous tree (incremental)" '[[ -e "$LC/build/marker" ]] && is_elf "$LC/build/bin/llama-server"'
t "LLAMACPP_REF pins the checkout" \
  'write_cfg "HW_VENDOR=nvidia" "HW_SM=120" "LLAMACPP_REPO=$UP" "LLAMACPP_DIR=$LC" "LLAMACPP_REF=$(git -C "$UP" rev-parse HEAD~2)"; build; [[ "$(git -C "$LC" rev-parse HEAD)" == "$(git -C "$UP" rev-parse HEAD~2)" ]]'

t "the engine lives in ~/llama whichever fork is configured" \
  '[[ "$( ( load; write_cfg "LLAMACPP_REPO=https://github.com/PrismML-Eng/llama.cpp"; cfg_load; llamacpp_dir ) )" == "$SB/home/llama" ]]'

# ---------------------------------------------------------------------------
section "model: config-driven download incl. the vision projector"
write_cfg "MODEL_REPO=org/repo" "MODEL_FILE=M-Q4.gguf" "MODEL_MMPROJ_FILE=mmproj-M.gguf" "MODEL_DIR=$SB/dl"
fetch() {
  ( load; cfg_load; . "$ROOT/modules/50-model-manager.sh"
    _hf() { local dir="${*: -1}"; [[ "$4" == --local-dir ]] && touch "$dir/$3"; return 0; }
    _mm_from_config ) >>"$OUT" 2>&1
}
fetch
t "model + projector downloaded and recorded" \
  '[[ "$(cfg_value LLAMA_MODEL)" == "$SB/dl/M-Q4.gguf" && "$(cfg_value LLAMA_MMPROJ)" == "$SB/dl/mmproj-M.gguf" && -e "$SB/dl/mmproj-M.gguf" ]]'
sed -i '/^MODEL_MMPROJ_FILE=/d' "$CONFIG_FILE"; fetch
t "dropping MODEL_MMPROJ_FILE turns vision off" '[[ -z "$(cfg_value LLAMA_MMPROJ)" ]]'
mkdir -p "$SB/dl/sub"; touch "$SB/dl/sub/N-00001-of-00003.gguf" "$SB/dl/sub/M-00001-of-00002.gguf" "$SB/dl/sub/M-00002-of-00002.gguf"
t "a sharded model resolves to ITS first shard" \
  '[[ "$( ( load; . "$ROOT/modules/50-model-manager.sh"; _mm_resolve "$SB/dl" "sub/M-*-of-*.gguf" ) )" == "$SB/dl/sub/M-00001-of-00002.gguf" ]]'

# ---------------------------------------------------------------------------
section "deploy.sh: the installed API key survives a redeploy"
eval "$(sed -n '/^conf_value()/p; /^set_conf_value() {/,/^}/p; /^installed_key() {/,/^}/p' "$ROOT/deploy.sh")"
PLACEHOLDER=REPLACE_WITH_YOUR_API_KEY; CONF_DST="$SB/deploy.conf"
printf 'LLAMA_API_KEY="new+/=&\\key"\n' >"$CONF_DST"
t "reads LLAMA_API_KEY" '[[ "$(installed_key)" == "new+/=&\\key" ]]'
printf 'LLAMA_EXTRA_ARGS="--flash-attn on --api-key legacy+/key --no-mmap"\n' >"$CONF_DST"
t "reads a legacy inline --api-key" '[[ "$(installed_key)" == "legacy+/key" ]]'
printf 'LLAMA_API_KEY="REPLACE_WITH_YOUR_API_KEY"\n' >"$CONF_DST"
t "ignores the placeholder" '[[ -z "$(installed_key)" ]]'
printf 'A="1"\nLLAMA_API_KEY="old"\n' >"$CONF_DST"; set_conf_value "$CONF_DST" LLAMA_API_KEY 'x+/y&z\w'; set_conf_value "$CONF_DST" B 2
t "set_conf_value replaces and appends verbatim" \
  '[[ "$(cat "$CONF_DST")" == "$(printf '\''A="1"\nLLAMA_API_KEY="x+/y&z\\w"\nB="2"'\'')" ]]'

# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null; then
  section "shellcheck"
  t "all scripts are clean" 'shellcheck -x "$ROOT"/setup.sh "$ROOT"/deploy.sh "$ROOT"/package-engine.sh "$ROOT"/lib/*.sh "$ROOT"/modules/*.sh "$ROOT"/tests/run.sh >"$SB/sc.log" 2>&1 || { cat "$SB/sc.log"; false; }'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || { echo "module output: ${OUT}${KEEP:+ (sandbox kept)} — rerun with KEEP=1 to inspect"; exit 1; }
