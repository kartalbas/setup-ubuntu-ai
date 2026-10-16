# shellcheck shell=bash
# lib/strata.sh — the Strata engine (ENGINE="strata"): an MoE runtime for
# Qwen3.8-Flash-Next that keeps the hot experts on the GPU, every expert in RAM
# and its lookup table on the SSD (https://github.com/Niko1221/Strata).
#
# Strata brings its own installer: given the family, size and context it
# compiles the engine for this GPU, downloads the model at pinned revisions
# (SHA-256 checked, resumable), packs it and writes strata-<tag>.json plus
# run-<tag>.sh. This file drives that installer from the config, so the whole
# install stays one config:
#   STRATA_REPO / STRATA_REF       the source and the release it is pinned to
#   STRATA_DIR / STRATA_DATA_DIR   the checkout (~/strata) and the model files (~/Strata-data)
#   STRATA_FAMILY / STRATA_MODEL   e.g. unsloth / UD-Q5_K_XL
#   STRATA_CONTEXT / STRATA_KV / STRATA_VISION
#   STRATA_SETUP_ARGS              more of Strata's setup options, verbatim
#   LLAMA_HOST / LLAMA_PORT / LLAMA_API_KEY   shared with the llama.cpp engine
# The API key is never handed to Strata's installer (it would store it in its
# JSON): the service loads it as a systemd credential into STRATA_API_KEY.
[[ -n "${_STRATA_SH_LOADED:-}" ]] && return 0
_STRATA_SH_LOADED=1

# shellcheck disable=SC2034  # read by setup.sh and the strata module
STRATA_REPO_DEFAULT="https://github.com/Niko1221/Strata"
STRATA_SERVICE="strata-server"
STRATA_UNIT_FILE="${STRATA_UNIT_FILE:-/etc/systemd/system/${STRATA_SERVICE}.service}"

# engine_kind — llamacpp (default) or strata.
engine_kind() { cfg_get ENGINE llamacpp; }
strata_enabled() { [[ "$(engine_kind)" == strata ]]; }

# llm_service / llm_unit_file — the systemd unit of the configured engine.
llm_service()   { if strata_enabled; then echo "$STRATA_SERVICE"; else echo "$LLAMA_SERVICE"; fi; }
llm_unit_file() { if strata_enabled; then echo "$STRATA_UNIT_FILE"; else echo "$LLAMA_UNIT_FILE"; fi; }

strata_dir()      { cfg_get STRATA_DIR "$INVOKING_HOME/strata"; }
strata_data_dir() { cfg_get STRATA_DATA_DIR "$INVOKING_HOME/Strata-data"; }

# strata_config — the strata-<tag>.json Strata's installer wrote for
# STRATA_MODEL (its tag is the family prefix + the size, lower case), recorded
# as STRATA_CONFIG by the install step. Empty if there is none yet.
strata_config() {
  local c; c="$(cfg_get STRATA_CONFIG)"
  [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
  local model; model="$(cfg_get STRATA_MODEL)"; model="${model,,}"
  [[ -n "$model" ]] || return 0
  local f; for f in "$(strata_dir)"/strata-*"${model}".json; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# strata_run_script — the run-<tag>.sh next to that config.
strata_run_script() {
  local c; c="$(strata_config)"
  [[ -n "$c" ]] || return 0
  local tag; tag="$(basename "$c" .json)"; tag="${tag#strata-}"
  printf '%s/run-%s.sh' "$(dirname "$c")" "$tag"
}

# strata_problem — why the Strata settings cannot be installed; nothing if they can.
strata_problem() {
  [[ -n "$(cfg_get STRATA_FAMILY)" ]] || { echo "STRATA_FAMILY is not set (e.g. unsloth)"; return 0; }
  [[ -n "$(cfg_get STRATA_MODEL)" ]]  || { echo "STRATA_MODEL is not set (e.g. UD-Q5_K_XL)"; return 0; }
  local v
  for v in STRATA_FAMILY STRATA_MODEL STRATA_CONTEXT STRATA_KV STRATA_VISION; do
    [[ "$(cfg_get "$v")" =~ ^[A-Za-z0-9_.-]*$ ]] || { echo "${v} has characters Strata's options never take"; return 0; }
  done
  return 0
}

# strata_setup_args — the options for Strata's own installer, from the config.
# One per line (no word splitting of paths); STRATA_SETUP_ARGS is split on
# whitespace like a command line.
strata_setup_args() {
  printf '%s\n' --setup --yes --no-start --no-browser \
    --family "$(cfg_get STRATA_FAMILY)" --model "$(cfg_get STRATA_MODEL)" \
    --data-dir "$(strata_data_dir)" \
    --host "$(cfg_get LLAMA_HOST 0.0.0.0)" --port "$(cfg_get LLAMA_PORT 8080)"
  local v
  v="$(cfg_get STRATA_CONTEXT)"; [[ -n "$v" ]] && printf '%s\n' --context "$v"
  v="$(cfg_get STRATA_KV)";      [[ -n "$v" ]] && printf '%s\n' --kv "$v"
  v="$(cfg_get STRATA_VISION)";  [[ -n "$v" ]] && printf '%s\n' --vision "$v"
  local -a extra=()
  read -r -a extra <<<"$(cfg_get STRATA_SETUP_ARGS)"
  (( ${#extra[@]} )) && printf '%s\n' "${extra[@]}"
  return 0
}

# render_strata_unit — the systemd unit: Strata's run script as the invoking
# user, RAM lockable (the engine pins tens of GB for the GPU), a long start and
# stop (loading 100+ GB; releasing the pinned RAM on SIGTERM), and the API key
# as a credential exported to STRATA_API_KEY just before the server starts.
render_strata_unit() {
  local tmpl="$REPO_ROOT/services/${STRATA_SERVICE}.service.tmpl" script cred start content
  [[ -f "$tmpl" ]] || die "Missing template: $tmpl"
  script="$(strata_run_script)"
  cred="# No API key configured (LLAMA_API_KEY): every client is accepted."
  start="${script}"
  if [[ -n "$(cfg_get LLAMA_API_KEY)" ]]; then
    cred="LoadCredential=api-key:${LLAMA_KEY_FILE}"
    # $$ is systemd's escape for a literal $ (the shell sees $CREDENTIALS_DIRECTORY).
    start="/bin/sh -c 'STRATA_API_KEY=\"\$\$(cat \"\$\${CREDENTIALS_DIRECTORY}/api-key\")\" exec \"${script}\"'"
  fi
  content="$(sed -e "s|@USER@|${INVOKING_USER}|g" -e "s|@DIR@|$(strata_dir)|g" \
                 -e "s|@CREDENTIAL@|${cred}|g" "$tmpl")"
  content="${content//@START@/$start}"
  show_diff "$STRATA_UNIT_FILE" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$STRATA_UNIT_FILE" 0644
}
