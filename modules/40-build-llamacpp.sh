# shellcheck shell=bash
# modules/40-build-llamacpp.sh — build the llama.cpp engine (upstream or a
# fork such as PrismML's) from source with the backend that matches the GPU:
# CUDA for NVIDIA, Vulkan for AMD. Runs as the invoking user, in ~/llama.
#
# The source is pinned by LLAMACPP_REF (branch, tag or commit; empty = the
# remote's default branch). A build never touches the engine the service runs:
# it is compiled in build-next/, verified, and only then swapped in as build/;
# the previous engine stays as build-prev/ (`build --rollback` swaps it back).
# Binaries carry an $ORIGIN RPATH, so a build tree works under any name/path.
# shellcheck source=/dev/null

LC_STAMP=".setup-ubuntu-ai-build"   # "rev=… flags=…" of the tree's build

_lc_backend() {
  case "$(cfg_get HW_VENDOR)" in
    nvidia) echo cuda ;;
    amd)    echo vulkan ;;
    *)      ui_menu "Backend" "GPU vendor unknown — pick a llama.cpp backend:" \
              cuda "NVIDIA CUDA" vulkan "AMD/Intel Vulkan" cpu "CPU only" ;;
  esac
}

# _lc_cuda_arch — CUDA arch to compile for: HW_SM, else the GPU's compute
# capability from nvidia-smi; empty lets llama.cpp detect it (native).
_lc_cuda_arch() {
  local sm; sm="$(cfg_get HW_SM)"
  if [[ -z "$sm" ]] && have nvidia-smi; then
    sm="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -dc '0-9')"
  fi
  printf '%s' "$sm"
}

# _lc_nvcc — absolute path of nvcc: CMake runs as the user, whose PATH
# usually lacks /usr/local/cuda/bin.
_lc_nvcc() {
  local nvcc; nvcc="$(command -v nvcc 2>/dev/null || true)"
  [[ -z "$nvcc" && -x /usr/local/cuda/bin/nvcc ]] && nvcc=/usr/local/cuda/bin/nvcc
  printf '%s' "$nvcc"
}

_lc_install_deps() {
  narrate "Installing build tools (compiler, cmake, ccache, curl dev)."
  apt_install build-essential cmake git ccache pkg-config libcurl4-openssl-dev || return 1
  case "$LC_BACKEND" in
    cuda)
      if [[ -z "$LC_NVCC" ]]; then
        log_error "nvcc not found — run 'sudo ${SCRIPT_PATH##*/} drivers' first to install the CUDA toolkit."
        return 1
      fi
      if [[ -n "$LC_SM" ]] && ! "$LC_NVCC" --list-gpu-arch 2>/dev/null | grep -q "compute_${LC_SM}"; then
        log_error "${LC_NVCC} cannot compile for sm_${LC_SM} — install a newer CUDA toolkit."
        return 1
      fi
      ;;
    vulkan)
      narrate "Installing Vulkan build deps (loader headers + shader compiler)."
      if ! apt_install libvulkan-dev glslc spirv-headers glslang-tools; then
        log_warn "glslc unavailable via apt; using glslang-tools fallback."
        apt_install libvulkan-dev spirv-headers glslang-tools || return 1
      fi
      ;;
  esac
}

# _lc_turbo_intended REPO — true if this build is meant to run the TurboQuant /
# VBR KV cache: either the buun-llama-cpp fork (which provides it) or extra args
# that already request a turbo/vbr cache type. Gates the CUDA-version guard below.
_lc_turbo_intended() {
  local repo="$1" extra; extra="$(cfg_get LLAMA_EXTRA_ARGS)"
  [[ "$repo" == *buun-llama-cpp* ]] && return 0
  [[ "$extra" == *turbo* || "$extra" == *vbr* ]] && return 0
  return 1
}

# _lc_cuda_turbo_guard — the TurboQuant/VBR KV codecs emit GIBBERISH on
# CUDA 13.0 and 13.2 (per the buun-llama-cpp authors). Catch such a toolkit
# BEFORE a long build that would otherwise compile fine and then silently
# produce garbage at inference time. Other versions are not known to be bad —
# validate them (e.g. llama-perplexity with f16 vs turbo KV) before trusting.
_lc_cuda_turbo_guard() {
  local ver
  ver="$("$LC_NVCC" --version 2>/dev/null | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p' | head -1)"
  if [[ -z "$ver" ]]; then
    log_warn "Could not read the CUDA version for the TurboQuant guard; proceeding."
    return 0
  fi
  case "$ver" in
    13.0|13.2)
      log_error "CUDA ${ver} makes the TurboQuant/VBR KV codecs output gibberish."
      [[ -n "${NONINTERACTIVE:-}" ]] && return 1
      ui_yesno "Continue building anyway (inference output may be garbage)?" || return 1 ;;
    *)
      log_ok "CUDA ${ver} is not a known-bad version for the TurboQuant KV codecs (13.0, 13.2 are)." ;;
  esac
  return 0
}

# _lc_cmake_flags — configure flags (without -S/-B) for $LC_BACKEND. The web
# UI is embedded (the server answers on / as well as /v1); without npm the
# build fetches llama.cpp's prebuilt, checksum-verified UI bundle instead of
# building it. It is embedded uncompressed: a gzip-only UI answers 415 to every
# client that does not send "Accept-Encoding: gzip" (probes, some proxies).
# The $ORIGIN RPATH keeps a tree relocatable (build-next/ → build/, deploy.sh --engine).
_lc_cmake_flags() {
  local -a f=( -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_UI=ON -DLLAMA_USE_PREBUILT_UI=ON
               -DLLAMA_UI_GZIP=OFF -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON )
  case "$LC_BACKEND" in
    cuda)   f+=( -DGGML_CUDA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON )
            [[ -n "$LC_SM" ]]   && f+=( -DCMAKE_CUDA_ARCHITECTURES="$LC_SM" )
            [[ -n "$LC_NVCC" ]] && f+=( -DCMAKE_CUDA_COMPILER="$LC_NVCC" ) ;;
    vulkan) f+=( -DGGML_VULKAN=ON ) ;;
  esac
  printf '%s\n' "${f[@]}"
}

# _lc_stamp REV FLAGS... — identifies a build: source commit + configure flags.
_lc_stamp() {
  local rev="$1"; shift
  printf 'rev=%s flags=%s\n' "$rev" "$(printf '%s\n' "$@" | sha256sum | cut -c1-16)"
}

_lc_git()   { run_as_user git -C "$LC_DIR" "$@"; }        # state changes (echoed)
_lc_git_q() { as_user git -C "$LC_DIR" "$@" 2>/dev/null; } # read-only queries

# _lc_sync_source — make LC_DIR a checkout of LC_REPO at LC_REF and print the
# commit. init + fetch (not clone) also works in a directory that already holds
# a staged prebuilt build/ (git refuses to clone into a non-empty directory),
# and switching LLAMACPP_REPO just repoints origin — nothing is deleted.
_lc_sync_source() {
  local rev origin
  if [[ ! -d "$LC_DIR/.git" ]]; then
    narrate "Creating a checkout of ${LC_REPO} in ${LC_DIR}."
    { run_as_user mkdir -p "$LC_DIR" && _lc_git init -q && _lc_git remote add origin "$LC_REPO"; } || return 1
  else
    origin="$(_lc_git_q remote get-url origin)"
    if [[ "$origin" != "$LC_REPO" ]]; then
      log_warn "Repointing ${LC_DIR} from ${origin:-no origin} to ${LC_REPO}."
      if [[ -n "$origin" ]]; then _lc_git remote set-url origin "$LC_REPO" || return 1
      else _lc_git remote add origin "$LC_REPO" || return 1; fi
    fi
  fi
  narrate "Fetching ${LC_REPO}."
  _lc_git fetch --tags --force origin || { log_error "git fetch from ${LC_REPO} failed."; return 1; }
  if [[ -n "$LC_REF" ]]; then
    rev="$(_lc_git_q rev-parse --verify --quiet "origin/${LC_REF}^{commit}" \
           || _lc_git_q rev-parse --verify --quiet "${LC_REF}^{commit}")"
    [[ -n "$rev" ]] || { log_error "LLAMACPP_REF '${LC_REF}' is no branch, tag or commit of ${LC_REPO}."; return 1; }
  else
    _lc_git remote set-head origin --auto >/dev/null || true
    rev="$(_lc_git_q rev-parse --verify --quiet 'origin/HEAD^{commit}')"
    [[ -n "$rev" ]] || { log_error "Cannot resolve the default branch of ${LC_REPO}."; return 1; }
  fi
  if [[ "$(_lc_git_q rev-parse HEAD)" != "$rev" ]]; then
    _lc_git -c advice.detachedHead=false checkout --detach "$rev" \
      || { log_error "Cannot check out ${rev} (local changes in ${LC_DIR}?)."; return 1; }
  fi
  printf '%s' "$rev"
}

# _lc_tree_at TREE PATH — true if CMake build tree TREE was configured at PATH;
# only then can it be rebuilt incrementally there (its cache records the path).
_lc_tree_at() {
  [[ "$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "$1/CMakeCache.txt" 2>/dev/null)" == "$2" ]]
}

# _lc_build_next STAMP FLAGS... — configure, compile and verify build-next/.
# Recycles build-prev/ (created as build-next/ by an earlier run) so rebuilds
# stay incremental; --force or a tree configured elsewhere starts clean.
_lc_build_next() {
  local stamp="$1"; shift
  local next="$LC_DIR/build-next" prev="$LC_DIR/build-prev"
  if [[ ! -d "$next" && -d "$prev" ]] && _lc_tree_at "$prev" "$next"; then
    run_as_user mv "$prev" "$next" || return 1
  fi
  if [[ -d "$next" ]] && { (( LC_FORCE )) || ! _lc_tree_at "$next" "$next"; }; then
    narrate "Starting from a clean build tree."
    run_as_user rm -rf "$next" || return 1
  fi
  narrate "Configuring the build (${LC_BACKEND})."
  if ! run_as_user cmake -S "$LC_DIR" -B "$next" "$@"; then
    log_error "CMake configuration failed (see the output above)."
    return 1
  fi
  narrate "Compiling with $(nproc) jobs — this can take a while; output is shown live."
  if ! run_as_user cmake --build "$next" --config Release -j "$(nproc)"; then
    log_error "Compilation failed (see the output above)."
    return 1
  fi
  if ! llama_bin_runs "$next/bin/llama-server"; then
    log_error "The new llama-server does not run; the current engine stays in place."
    return 1
  fi
  printf '%s\n' "$stamp" | as_user tee "$next/$LC_STAMP" >/dev/null
}

# _lc_activate — swap build-next/ in as build/; the old build/ becomes
# build-prev/. A running server keeps the files it has open and uses the new
# engine from its next restart on.
_lc_activate() {
  local cur="$LC_DIR/build" next="$LC_DIR/build-next" prev="$LC_DIR/build-prev"
  if [[ -d "$prev" ]]; then run_as_user rm -rf "$prev" || return 1; fi
  if [[ -d "$cur" ]]; then run_as_user mv "$cur" "$prev" || return 1; fi
  run_as_user mv "$next" "$cur"
}

# _lc_rollback — swap build-prev/ back in as build/ (the current engine becomes
# build-prev/, so rolling back twice restores it).
_lc_rollback() {
  local cur="$LC_DIR/build" prev="$LC_DIR/build-prev" tmp="$LC_DIR/build-rollback"
  [[ -d "$prev" ]] || { log_error "No previous engine to roll back to (${prev} is missing)."; return 1; }
  { run_as_user mv "$cur" "$tmp" && run_as_user mv "$prev" "$cur" && run_as_user mv "$tmp" "$prev"; } || return 1
}

# _lc_built_rev TREE — the commit a tree was built from (from its stamp).
_lc_built_rev() { sed -n 's/^rev=\([^ ]*\).*/\1/p' "$1/$LC_STAMP" 2>/dev/null; }

# _lc_record BIN REV — remember which engine the service runs.
_lc_record() {
  cfg_set LLAMACPP_BIN "$1"
  cfg_set LLAMACPP_BACKEND "$LC_BACKEND"
  cfg_set LLAMACPP_REPO "$LC_REPO"
  if [[ -n "$2" ]]; then cfg_set LLAMACPP_BUILT_REV "$2"; else cfg_del LLAMACPP_BUILT_REV; fi
  cfg_save
}

module_main() {
  log_step "Build llama.cpp"
  local a rollback=0
  LC_FORCE=0
  for a in "$@"; do
    case "$a" in
      --force)    LC_FORCE=1 ;;
      --rollback) rollback=1 ;;
      *)          log_error "Unknown build option: ${a} (use --force or --rollback)"; return 1 ;;
    esac
  done

  LC_BACKEND="$(_lc_backend)" || return 0
  [[ -z "$LC_BACKEND" ]] && { log_info "Cancelled."; return 0; }
  LC_REPO="$(cfg_get LLAMACPP_REPO "$LLAMACPP_REPO_DEFAULT")"
  LC_REF="$(cfg_get LLAMACPP_REF)"
  LC_DIR="$(llamacpp_dir)"
  LC_SM=""; LC_NVCC=""
  local bin="$LC_DIR/build/bin/llama-server"

  if (( rollback )); then
    _lc_rollback || return 1
    _lc_record "$bin" "$(_lc_built_rev "$LC_DIR/build")"
    log_ok "Rolled back to the previous engine (${bin})."
    llama_unit_installed && log_info "Restart the service to run it:  sudo systemctl restart ${LLAMA_SERVICE}"
    return 0
  fi

  if [[ "$LC_BACKEND" == cuda ]]; then
    LC_SM="$(_lc_cuda_arch)"
    LC_NVCC="$(_lc_nvcc)"
    [[ -n "$LC_NVCC" ]] && log_info "Using CUDA compiler: ${LC_NVCC}"
    if [[ -n "$LC_NVCC" ]] && _lc_turbo_intended "$LC_REPO"; then
      _lc_cuda_turbo_guard || { log_error "Aborting: known-bad CUDA toolkit for the TurboQuant KV cache."; return 1; }
    fi
  fi
  log_info "Backend: ${LC_BACKEND}${LC_SM:+ (sm_${LC_SM})}   Source: ${LC_REPO}${LC_REF:+ @ ${LC_REF}}   Dir: ${LC_DIR}"

  # Prebuilt engine staged by deploy.sh --engine: trust it only if it actually
  # runs on this CPU — anything else falls through to a real source build.
  if is_true "$(cfg_get LLAMACPP_PREBUILT)" && (( LC_FORCE == 0 )); then
    if llama_bin_runs "$bin"; then
      log_ok "Prebuilt engine runs on this machine → skipping the source build (${bin})."
      _lc_record "$bin" ""
      return 0
    fi
    log_warn "LLAMACPP_PREBUILT is set, but ${bin} does not run here — building from source."
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] would fetch ${LC_REPO}${LC_REF:+ @ ${LC_REF}} into ${LC_DIR}, build it in build-next/ and swap it in as build/."
    return 0
  fi

  require_space "$LC_DIR" 10 "llama.cpp build"
  _lc_install_deps || { log_warn "Dependencies incomplete; aborting build."; return 1; }

  local rev stamp
  rev="$(_lc_sync_source)" || return 1
  local -a flags; mapfile -t flags < <(_lc_cmake_flags)
  stamp="$(_lc_stamp "$rev" "${flags[@]}")"
  if (( LC_FORCE == 0 )) && [[ "$(cat "$LC_DIR/build/$LC_STAMP" 2>/dev/null)" == "$stamp" ]] \
     && llama_bin_runs "$bin"; then
    log_ok "Engine is up to date (${rev:0:9}) → ${bin}"
    _lc_record "$bin" "$rev"
    return 0
  fi

  _lc_build_next "$stamp" "${flags[@]}" || return 1
  _lc_activate || return 1
  _lc_record "$bin" "$rev"
  log_ok "Built ${LC_REPO##*/} ${rev:0:9} (${LC_BACKEND}) → ${bin}"
  "$bin" --version 2>&1 | head -3 | sed 's/^/    /' >&2 || true
  if llama_unit_installed; then
    log_info "Restart the service to run the new engine:  sudo systemctl restart ${LLAMA_SERVICE}"
  fi
  return 0
}

module_uninstall() {
  log_step "Removing the llama.cpp engine"
  local dir; dir="$(llamacpp_dir)"
  if ui_yesno "Delete the whole source + build tree at ${dir}?"; then
    run rm -rf "$dir"
    cfg_del LLAMACPP_BIN; cfg_del LLAMACPP_BACKEND; cfg_del LLAMACPP_BUILT_REV; cfg_save
    log_ok "Removed ${dir}."
  else
    log_info "Kept ${dir}."
  fi
}
