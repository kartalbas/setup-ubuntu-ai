# shellcheck shell=bash
# modules/50-model-manager.sh — pick and download the model.
# Interactive: search the Hugging Face Hub → pick a repo → pick a quantisation
# (real .gguf files, with sizes) → optionally a vision projector (mmproj) →
# download. Unattended (restore): fetch exactly MODEL_REPO / MODEL_FILE /
# MODEL_MMPROJ_FILE from the config. No hard-coded model list.
# shellcheck source=/dev/null

HF_API="https://huggingface.co/api"

_mm_ensure_tools() {
  have jq    || { narrate "Installing jq (parses the Hugging Face search API)."; apt_install jq; }
  have curl  || apt_install curl
  if run_as_user bash -lc 'command -v hf' >/dev/null 2>&1; then
    log_ok "Hugging Face CLI present (hf)."
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
    else "$HOME/.local/bin/hf" "$@"; fi' _ "$@"
}

_human_gib() { awk -v b="${1:-0}" 'BEGIN{ if(b<=0){print "?"} else {printf "%.1f", b/1073741824} }'; }

# _mm_search QUERY -> prints "repo_id<TAB>downloads" lines.
# Restricted to llama.cpp-usable models: GGUF format + text-generation pipeline
# (this drops embedding and reranker repos that llama-server can't serve as
# chat models).
_mm_search() {
  local q="$1"
  curl -fsG "$HF_API/models" \
       --data-urlencode "search=$q" \
       --data-urlencode "filter=gguf" \
       --data-urlencode "pipeline_tag=text-generation" \
       --data "sort=downloads" --data "direction=-1" --data "limit=30" 2>/dev/null \
    | jq -r '.[] | [.id, (.downloads // 0)] | @tsv' 2>/dev/null
}

# _mm_tree REPO -> "path<TAB>bytes" for every .gguf file in the repo.
_mm_tree() {
  curl -fsG "$HF_API/models/${1}/tree/main" --data "recursive=true" 2>/dev/null \
    | jq -r '.[] | select(.type=="file") | select(.path|endswith(".gguf"))
             | [.path, (.lfs.size // .size // 0)] | @tsv' 2>/dev/null
}

# _mm_is_mmproj PATH — vision projectors are helpers, not standalone models.
_mm_is_mmproj() { [[ "${1,,}" == *mmproj* || "${1,,}" == *projector* ]]; }

# _mm_list_gguf REPO -> loadable model weights ("path<TAB>bytes").
_mm_list_gguf() {
  local p s
  while IFS=$'\t' read -r p s; do
    if [[ -n "$p" ]] && ! _mm_is_mmproj "$p"; then printf '%s\t%s\n' "$p" "$s"; fi
  done < <(_mm_tree "$1")
}

# _mm_list_mmproj REPO -> vision projectors ("path<TAB>bytes").
_mm_list_mmproj() {
  local p s
  while IFS=$'\t' read -r p s; do
    if [[ -n "$p" ]] && _mm_is_mmproj "$p"; then printf '%s\t%s\n' "$p" "$s"; fi
  done < <(_mm_tree "$1")
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

# _mm_pick_mmproj REPO — offer the repo's vision projectors, if it has any.
# Prints the chosen path, or nothing for text-only; returns 1 when cancelled.
_mm_pick_mmproj() {
  local files p s
  files="$(_mm_list_mmproj "$1")"
  [[ -n "$files" ]] || return 0
  local -a items=()
  while IFS=$'\t' read -r p s; do
    [[ -n "$p" ]] && items+=( "$p" "${p##*/}   $(_human_gib "$s") GB" )
  done <<<"$files"
  items+=( __none "Text only (no vision)" )
  local sel
  sel="$(ui_menu "Vision (image input)" "This model ships vision projectors (mmproj). Enable image input?" "${items[@]}")" || return 1
  [[ "$sel" == __none ]] || printf '%s' "$sel"
}

_mm_download() {
  local repo="$1" pathspec="$2" dir="$3"
  narrate "Downloading ${pathspec} from ${repo} into ${dir} (resumable; Ctrl-C is safe)."
  # hf prints the local path on stdout — keep stdout for our own results.
  if [[ "$pathspec" == *'*'* ]]; then
    _hf download "$repo" --include "$pathspec" --local-dir "$dir" >&2
  else
    _hf download "$repo" "$pathspec" --local-dir "$dir" >&2
  fi
}

# _mm_resolve DIR PATHSPEC — the local path llama-server should load. For a
# sharded model ("<prefix>-*-of-*.gguf") that is the first shard of THAT model.
_mm_resolve() {
  local dir="$1" pathspec="$2"
  if [[ "$pathspec" == *'*'* ]]; then
    compgen -G "${dir}/${pathspec/-\*-of-\*.gguf/-00001-of-*.gguf}" | head -1
  else
    printf '%s/%s' "$dir" "$pathspec"
  fi
}

# _mm_fetch REPO PATHSPEC DIR — download unless present; prints the local path.
_mm_fetch() {
  local repo="$1" spec="$2" dir="$3" path
  path="$(_mm_resolve "$dir" "$spec")"
  if [[ -n "$path" && -e "$path" ]]; then
    log_ok "Already present: ${path}"
  else
    _mm_download "$repo" "$spec" "$dir" || return 1
    path="$(_mm_resolve "$dir" "$spec")"
  fi
  [[ -n "$path" && -e "$path" ]] || { log_warn "Download finished but ${spec} is not under ${dir}."; return 1; }
  printf '%s' "$path"
}

# _mm_require_space REPO DIR PATHSPEC... — room for the files not on disk yet
# (sizes from the Hub listing; skipped when the listing is unavailable).
_mm_require_space() {
  local repo="$1" dir="$2"; shift 2
  local tree spec path p s need=0
  tree="$(_mm_tree "$repo")"
  for spec in "$@"; do
    path="$(_mm_resolve "$dir" "$spec")"
    [[ -n "$path" && -e "$path" ]] && continue
    while IFS=$'\t' read -r p s; do
      # shellcheck disable=SC2053  # spec may be a shard glob — match it as one
      [[ -n "$p" && "$p" == $spec ]] && need=$(( need + s ))
    done <<<"$tree"
  done
  (( need > 0 )) || return 0
  require_space "$dir" "$(( need / 1073741824 + 2 ))" "model download"
}

# _mm_from_config — download exactly what the config names (MODEL_REPO +
# MODEL_FILE, plus MODEL_MMPROJ_FILE for vision) and record the local paths
# the runtime loads (LLAMA_MODEL, LLAMA_MMPROJ). Returns 1 if the coordinates
# are missing or a download yields nothing.
_mm_from_config() {
  local repo file mmproj dir model proj=""
  repo="$(cfg_get MODEL_REPO)"; file="$(cfg_get MODEL_FILE)"; mmproj="$(cfg_get MODEL_MMPROJ_FILE)"
  dir="$(cfg_get MODEL_DIR "$INVOKING_HOME/models")"
  [[ -n "$repo" && -n "$file" ]] || return 1
  log_info "Model from config: ${repo} :: ${file}${mmproj:+ (vision: ${mmproj})}"
  ensure_dir "$dir" 0755 "$INVOKING_USER"
  _mm_require_space "$repo" "$dir" "$file" ${mmproj:+"$mmproj"}
  model="$(_mm_fetch "$repo" "$file" "$dir")" || return 1
  cfg_set LLAMA_MODEL "$model"
  if [[ -n "$mmproj" ]]; then
    proj="$(_mm_fetch "$repo" "$mmproj" "$dir")" || return 1
    cfg_set LLAMA_MMPROJ "$proj"
  else
    cfg_del LLAMA_MMPROJ
  fi
  cfg_save
  log_ok "Model ready: ${model}${proj:+ (vision: ${proj})}"
}

module_main() {
  log_step "Model (Hugging Face)"
  _mm_ensure_tools

  # Non-interactive restore, or unattended run with coordinates already saved:
  # fetch exactly what the config names and skip the interactive browser.
  if [[ -n "${NONINTERACTIVE:-}" || -n "${ASSUME_YES:-}" ]] && [[ -n "$(cfg_get MODEL_REPO)" ]]; then
    if _mm_from_config; then
      log_info "Next: configure runtime →  sudo ${SCRIPT_PATH##*/} configure"
      return 0
    fi
    [[ -n "${NONINTERACTIVE:-}" ]] && { log_warn "Cannot restore the model from the config; aborting the non-interactive model step."; return 1; }
    log_warn "Config-driven download unavailable; falling back to the interactive browser."
  fi

  local dir; dir="$(cfg_get MODEL_DIR "$INVOKING_HOME/models")"
  dir="$(ui_input "Directory to store models" "$dir")" || return 0
  [[ -z "$dir" ]] && return 0
  cfg_set MODEL_DIR "$dir"; cfg_save

  local repo quant pathspec mmproj
  while :; do
    repo="$(_mm_pick_repo)" || { log_info "Cancelled."; return 0; }
    if quant="$(_mm_pick_quant "$repo")"; then break; fi
    # no quants / back → search again
  done
  IFS=$'\t' read -r pathspec _ <<<"$quant"
  mmproj="$(_mm_pick_mmproj "$repo")" || { log_info "Cancelled."; return 0; }

  # Capture provenance so `restore` can re-fetch exactly this model.
  cfg_set MODEL_REPO "$repo"
  cfg_set MODEL_FILE "$pathspec"
  if [[ -n "$mmproj" ]]; then cfg_set MODEL_MMPROJ_FILE "$mmproj"; else cfg_del MODEL_MMPROJ_FILE; fi
  cfg_save

  _mm_from_config || return 1
  log_info "Next: configure runtime →  sudo ${SCRIPT_PATH##*/} configure"
}

module_uninstall() {
  log_step "Model files"
  local dir; dir="$(cfg_get MODEL_DIR "$INVOKING_HOME/models")"
  log_warn "Models can be large; not deleting automatically. Remove manually:  rm -rf ${dir}"
}
