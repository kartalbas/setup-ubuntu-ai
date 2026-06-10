# shellcheck shell=bash
# modules/50-model-manager.sh — INTERACTIVE Hugging Face model browser.
# Search the Hub at runtime → pick a repo → pick an available quantisation
# (real .gguf files, with sizes) → download. No hard-coded model list.
# shellcheck source=/dev/null

HF_API="https://huggingface.co/api"

_mm_ensure_tools() {
  have jq    || { narrate "Installing jq (parses the Hugging Face search API)."; apt_install jq; }
  have curl  || apt_install curl
  if run_as_user bash -lc 'command -v hf || command -v huggingface-cli' >/dev/null 2>&1; then
    log_ok "Hugging Face CLI present."
  else
    narrate "Installing the huggingface_hub CLI via pipx (for resumable downloads + auth)."
    apt_install pipx
    run_as_user bash -lc 'pipx install "huggingface_hub[cli]" || pipx install huggingface_hub'
    run_as_user bash -lc 'pipx ensurepath' || true
  fi
}

# Run the HF CLI as the human (their token + ~/.local/bin on PATH).
# shellcheck disable=SC2016
_hf() {
  run_as_user bash -lc '
    if command -v hf >/dev/null 2>&1; then hf "$@";
    elif command -v huggingface-cli >/dev/null 2>&1; then huggingface-cli "$@";
    else "$HOME/.local/bin/hf" "$@"; fi' _ "$@"
}

_human_gib() { awk -v b="${1:-0}" 'BEGIN{ if(b<=0){print "?"} else {printf "%.1f", b/1073741824} }'; }

# _mm_search QUERY -> prints "repo_id<TAB>downloads" lines.
# Restricted to llama.cpp-usable models: GGUF format + text-generation pipeline
# (this drops vision/VL, embedding and reranker repos that llama-server can't
# serve as chat models).
_mm_search() {
  local q="$1"
  curl -fsG "$HF_API/models" \
       --data-urlencode "search=$q" \
       --data-urlencode "filter=gguf" \
       --data-urlencode "pipeline_tag=text-generation" \
       --data "sort=downloads" --data "direction=-1" --data "limit=30" 2>/dev/null \
    | jq -r '.[] | [.id, (.downloads // 0)] | @tsv' 2>/dev/null
}

# _mm_list_gguf REPO -> prints "path<TAB>bytes" for every loadable .gguf weight.
# Excludes mmproj / projector files (multimodal helpers, not standalone models).
_mm_list_gguf() {
  local repo="$1"
  curl -fsG "$HF_API/models/${repo}/tree/main" --data "recursive=true" 2>/dev/null \
    | jq -r '.[] | select(.type=="file")
             | select(.path|endswith(".gguf"))
             | select((.path|ascii_downcase|test("mmproj|projector"))|not)
             | [.path, (.lfs.size // .size // 0)] | @tsv' 2>/dev/null
}

# Pick a repo via search. Echoes the chosen repo id, or returns 1 to go back.
_mm_pick_repo() {
  local q results
  while :; do
    q="$(ui_input "Search Hugging Face for a model (e.g. 'qwen3 8b', 'llama 3.3', 'mistral')" "")" || return 1
    [[ -z "$q" ]] && return 1
    log_info "Searching Hugging Face for '${q}'…" >&2
    results="$(_mm_search "$q")"
    if [[ -z "$results" ]]; then
      ui_yesno "No GGUF models matched '${q}'. Search again?" && continue || return 1
    fi
    local -a items=() id dl
    while IFS=$'\t' read -r id dl; do
      [[ -z "$id" ]] && continue
      items+=( "$id" "$id   (⭳ ${dl})" )
    done <<<"$results"
    items+=( __again "↻ Search again with a different term" )
    local choice
    choice="$(ui_menu "Search results for '${q}'" "Select a model repository:" "${items[@]}")" || return 1
    [[ "$choice" == "__again" ]] && continue
    printf '%s' "$choice"; return 0
  done
}

# Pick a quantisation in REPO. Echoes "glob_or_path<TAB>approx_bytes", or 1=back.
_mm_pick_quant() {
  local repo="$1" files
  files="$(_mm_list_gguf "$repo")"
  if [[ -z "$files" ]]; then
    ui_msg "No .gguf files found in ${repo}.\n(It may store weights in a non-GGUF format.)" "Nothing to download"
    return 1
  fi
  # Collapse multi-part shards into one selectable entry.
  local -A G_SIZE=() G_GLOB=() G_SHARD=()
  local -a order=()
  local path size base prefix dirpart key
  while IFS=$'\t' read -r path size; do
    [[ -z "$path" ]] && continue
    base="${path##*/}"
    dirpart="${path%/*}"; [[ "$dirpart" == "$path" ]] && dirpart=""
    if [[ "$base" =~ ^(.+)-[0-9]+-of-[0-9]+\.gguf$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      key="${dirpart:+$dirpart/}${prefix}"
      G_SIZE[$key]=$(( ${G_SIZE[$key]:-0} + size ))
      if [[ -z "${G_GLOB[$key]:-}" ]]; then
        G_GLOB[$key]="${key}-*-of-*.gguf"; G_SHARD[$key]=1; order+=("$key")
      fi
    else
      key="$path"
      G_SIZE[$key]=$size; G_GLOB[$key]="$path"; order+=("$key")
    fi
  done <<<"$files"

  local budget; budget="$(gpu_budget_gb)"
  local -a items=()
  for key in "${order[@]}"; do
    local gib mark="" lbl
    gib="$(_human_gib "${G_SIZE[$key]}")"
    if [[ "$budget" =~ ^[0-9]+$ ]] && (( budget > 0 )) && awk -v g="$gib" -v b="$budget" 'BEGIN{exit !(g+0 > b)}'; then
      mark="  ⚠ > ${budget}GiB VRAM (partial offload)"
    fi
    lbl="${key##*/}   ${gib} GB"
    [[ -n "${G_SHARD[$key]:-}" ]] && lbl+="  (sharded)"
    items+=( "$key" "${lbl}${mark}" )
  done
  local sel
  sel="$(ui_menu "Quantisations in ${repo}" "Pick a quantisation (budget ~${budget} GiB):" "${items[@]}")" || return 1
  printf '%s\t%s' "${G_GLOB[$sel]}" "${G_SIZE[$sel]:-0}"
}

_mm_download() {
  local repo="$1" pathspec="$2" dir="$3"
  ensure_dir "$dir" 0755
  run chown "$INVOKING_USER" "$dir" 2>/dev/null || true
  narrate "Downloading from ${repo} into ${dir} (resumable; Ctrl-C is safe)."
  if [[ "$pathspec" == *'*'* ]]; then
    _hf download "$repo" --include "$pathspec" --local-dir "$dir"
  else
    _hf download "$repo" "$pathspec" --local-dir "$dir"
  fi
}

_mm_resolve() {   # echo the path llama-server should load
  local dir="$1" pathspec="$2" first
  if [[ "$pathspec" == *'*'* ]]; then
    first="$(find "$dir" -name '*-00001-of-*.gguf' 2>/dev/null | sort | head -1)"
    [[ -z "$first" ]] && first="$(find "$dir" -name '*.gguf' 2>/dev/null | sort | head -1)"
    printf '%s' "$first"
  else
    printf '%s/%s' "$dir" "$pathspec"
  fi
}

module_main() {
  log_step "Model browser (Hugging Face search)"
  _mm_ensure_tools

  local dir; dir="$(cfg_get MODEL_DIR "$INVOKING_HOME/models")"
  dir="$(ui_input "Directory to store models" "$dir")" || return 0
  [[ -z "$dir" ]] && return 0
  cfg_set MODEL_DIR "$dir"; cfg_save

  local repo quant pathspec bytes
  while :; do
    repo="$(_mm_pick_repo)" || { log_info "Cancelled."; return 0; }
    if quant="$(_mm_pick_quant "$repo")"; then break; fi
    # no quants / back → search again
  done
  IFS=$'\t' read -r pathspec bytes <<<"$quant"

  local need; need="$(awk -v b="$bytes" 'BEGIN{printf "%d", (b/1073741824)+2}')"
  require_space "$dir" "${need:-3}" "model download"

  _mm_download "$repo" "$pathspec" "$dir"

  local model; model="$(_mm_resolve "$dir" "$pathspec")"
  if [[ -z "$model" || ! -e "$model" ]]; then
    log_warn "Download finished but the .gguf path could not be resolved under ${dir}."
    return 1
  fi
  cfg_set LLAMA_MODEL "$model"; cfg_save
  log_ok "Model ready: ${model}"
  log_info "Next: configure runtime →  sudo ${SCRIPT_PATH##*/} configure"
}

module_uninstall() {
  log_step "Model files"
  local dir; dir="$(cfg_get MODEL_DIR "$INVOKING_HOME/models")"
  log_warn "Models can be large; not deleting automatically. Remove manually:  rm -rf ${dir}"
}
