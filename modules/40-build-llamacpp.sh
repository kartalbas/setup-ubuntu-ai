# shellcheck shell=bash
# modules/40-build-llamacpp.sh — build llama.cpp from source with the backend
# that matches the GPU: CUDA (sm_120) for NVIDIA, Vulkan for AMD.
# Builds in the invoking user's home so rebuilds need no sudo.
# shellcheck source=/dev/null

# Default upstream source. Overridable per-config with LLAMACPP_REPO (e.g. the
# spiritbuun/buun-llama-cpp fork that adds the TurboQuant/VBR KV cache),
# and LLAMACPP_REF to pin a branch/tag/commit for reproducibility.
LLAMACPP_REPO_DEFAULT="https://github.com/ggml-org/llama.cpp"

_lc_backend() {
  case "$(cfg_get HW_VENDOR)" in
    nvidia) echo cuda ;;
    amd)    echo vulkan ;;
    *)      ui_menu "Backend" "GPU vendor unknown — pick a llama.cpp backend:" \
              cuda "NVIDIA CUDA" vulkan "AMD/Intel Vulkan" cpu "CPU only" ;;
  esac
}

# _lc_bin_runs BIN — true if the binary actually executes on THIS machine. A
# build carried over from another host can be present yet crash instantly with
# SIGILL: GGML_NATIVE bakes the build host's instruction set (e.g. AVX-512) into
# the binary, so it dies on a CPU that lacks those extensions. The executable
# bit alone can't catch that — only running it can.
_lc_bin_runs() {
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  # A zero-byte or truncated stub from an aborted build is still +x, and the
  # shell will happily "run" an empty file as an empty script that exits 0 — so
  # `--version` alone reports success on a broken binary. Require genuine ELF
  # magic first (systemd's execve rejects the stub with "Exec format error",
  # status 203; mirror that stricter check here).
  [[ -s "$1" ]] || return 1
  [[ "$(LC_ALL=C head -c4 -- "$1" 2>/dev/null)" == $'\177ELF' ]] || return 1
  "$1" --version >/dev/null 2>&1
}

# _lc_relocate_prebuilt DIR — rewrite the engine's baked build-tree RPATH to
# $ORIGIN so the binary finds its own .so relative to itself, whatever home path
# it was built under. A prebuilt copied from a different-home machine otherwise
# dies with "libllama-server-impl.so: cannot open shared object file" (CMake
# bakes the absolute build path as RPATH). Makes deploy.sh --engine relocatable.
_lc_relocate_prebuilt() {
  local dir="$1/build/bin" f n=0
  [[ -d "$dir" ]] || return 0
  have patchelf || apt_install patchelf || { log_warn "patchelf unavailable — cannot make the prebuilt engine relocatable."; return 0; }
  while IFS= read -r f; do
    # $ORIGIN is a literal token resolved by the dynamic loader, not the shell.
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null && n=$((n+1))
  done < <(find "$dir" -maxdepth 1 -type f \( -name 'llama-server' -o -name '*.so*' \))
  (( n > 0 )) && log_info "Made prebuilt engine relocatable (RPATH → \$ORIGIN, ${n} files)."
}

_lc_install_deps() {
  local backend="$1"
  narrate "Installing build tools (compiler, cmake, ccache, curl dev)."
  apt_install build-essential cmake git ccache pkg-config libcurl4-openssl-dev
  case "$backend" in
    cuda)
      if ! have nvcc; then export PATH=/usr/local/cuda/bin:$PATH; fi
      if ! have nvcc; then
        log_warn "nvcc not found. Run 'sudo ${SCRIPT_PATH##*/} drivers' first to install CUDA."
        ui_yesno "Continue without CUDA (will fail)?" || return 1
      elif ! nvcc --list-gpu-arch 2>/dev/null | grep -q compute_120; then
        log_warn "Installed nvcc does not list sm_120 — the Blackwell build may fail (need CUDA ≥12.8)."
        ui_yesno "Continue building anyway?" || return 1
      fi
      ;;
    vulkan)
      narrate "Installing Vulkan build deps (loader headers + shader compiler)."
      if ! apt_install libvulkan-dev glslc spirv-headers glslang-tools; then
        log_warn "glslc unavailable via apt; using glslang-tools fallback."
        apt_install libvulkan-dev spirv-headers glslang-tools
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
# CUDA 13.0 and 13.2; only 13.1 and 13.3 are known-good (per the buun-llama-cpp
# authors). Catch a bad toolkit BEFORE a long build that would otherwise compile
# fine and then silently produce garbage at inference time. Returns non-zero to
# abort in non-interactive runs; interactive runs may override.
_lc_cuda_turbo_guard() {
  local ver
  ver="$(${LC_NVCC:-nvcc} --version 2>/dev/null | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p' | head -1)"
  if [[ -z "$ver" ]]; then
    log_warn "Could not read the CUDA version for the TurboQuant guard; proceeding."
    return 0
  fi
  case "$ver" in
    13.0|13.2)
      log_error "CUDA ${ver} makes the TurboQuant/VBR KV codecs output gibberish — use CUDA 13.1 or 13.3."
      [[ -n "${NONINTERACTIVE:-}" ]] && return 1
      ui_yesno "Continue building anyway (inference output may be garbage)?" || return 1 ;;
    *)
      log_ok "CUDA ${ver} is compatible with TurboQuant KV cache." ;;
  esac
  return 0
}

_lc_cmake_flags() {
  local backend="$1"
  # Headless inference appliance: build llama-server's API only, NOT the
  # embedded browser Web UI. Upstream's UI step needs node/npm (or a build-time
  # Hugging Face asset download) and is a frequent source of breakage on master;
  # we never serve the UI, so switch it off for a self-contained, robust build.
  local -a f=( -S "$LC_DIR" -B "$LC_DIR/build" -DCMAKE_BUILD_TYPE=Release
               -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF )
  case "$backend" in
    cuda)
      f+=( -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="${LC_SM:-120}" -DGGML_CUDA_FA_ALL_QUANTS=ON )
      # The build runs as the invoking user, whose PATH usually lacks
      # /usr/local/cuda/bin — pin the compiler so CMake can find nvcc.
      [[ -n "${LC_NVCC:-}" ]] && f+=( -DCMAKE_CUDA_COMPILER="$LC_NVCC" ) ;;
    vulkan) f+=( -DGGML_VULKAN=ON ) ;;
    cpu)    : ;;
  esac
  printf '%s\n' "${f[@]}"
}

module_main() {
  log_step "Build llama.cpp"
  local force=0 a
  for a in "$@"; do [[ "$a" == "--force" ]] && force=1; done

  local backend; backend="$(_lc_backend)" || return 0
  [[ -z "$backend" ]] && { log_info "Cancelled."; return 0; }
  LC_DIR="$(cfg_get LLAMACPP_DIR "$INVOKING_HOME/llama.cpp")"
  LC_SM="$(cfg_get HW_SM 120)"
  LC_REPO="$(cfg_get LLAMACPP_REPO "$LLAMACPP_REPO_DEFAULT")"
  LC_REF="$(cfg_get LLAMACPP_REF)"
  local bin="$LC_DIR/build/bin/llama-server"
  local clean=$force   # wipe the build/ tree before configuring (see below)

  # Resolve an absolute nvcc so CMake finds it when building as the user.
  if [[ "$backend" == cuda ]]; then
    LC_NVCC="$(command -v nvcc 2>/dev/null || true)"
    [[ -z "$LC_NVCC" && -x /usr/local/cuda/bin/nvcc ]] && LC_NVCC=/usr/local/cuda/bin/nvcc
    [[ -n "$LC_NVCC" ]] && log_info "Using CUDA compiler: $LC_NVCC"
  fi

  # Guard a TurboQuant build against the CUDA versions that silently break it.
  if [[ "$backend" == cuda ]] && _lc_turbo_intended "$LC_REPO"; then
    _lc_cuda_turbo_guard || { log_error "Aborting: CUDA toolkit incompatible with TurboQuant KV cache."; return 1; }
  fi

  log_info "Backend: ${backend}   Repo: ${LC_REPO}   Source dir: ${LC_DIR}"

  # Prebuilt engine: when LLAMACPP_PREBUILT is set (deploy.sh's --engine path
  # dropped a ready-made build/ into LC_DIR), trust it and skip the ~40-minute
  # source compile. Only honoured when the binary ACTUALLY runs on this CPU — a
  # stub or a wrong-microarch binary (would SIGILL) falls through to a real build,
  # so a prebuilt from an incompatible host can never silently poison the service.
  if [[ -n "$(cfg_get LLAMACPP_PREBUILT)" || -n "${LLAMACPP_PREBUILT:-}" ]] && (( force == 0 )); then
    _lc_relocate_prebuilt "$LC_DIR"
    if _lc_bin_runs "$bin"; then
      log_ok "Prebuilt engine present and runs here → skipping source build ($bin)."
      cfg_set LLAMACPP_BIN "$bin"; cfg_set LLAMACPP_BACKEND "$backend"; cfg_save
      return 0
    fi
    log_warn "LLAMACPP_PREBUILT set but ${bin} does not run on this CPU — falling back to a source build."
  fi

  if [[ -x "$bin" && "$(cfg_get LLAMACPP_BACKEND)" == "$backend" && $force -eq 0 ]]; then
    if _lc_bin_runs "$bin"; then
      log_ok "llama.cpp already built ($backend) → $bin"
      ui_yesno "Pull latest and rebuild?" || return 0
    else
      # Present but won't execute → almost always a build carried from another
      # machine (GGML_NATIVE compiled in CPU instructions this host lacks).
      # Don't trust it; rebuild on THIS CPU — and from a clean tree, since the
      # carried-over build/ also holds the old host's CMake cache and stale
      # generated assets.
      log_warn "Existing llama-server won't run on this CPU (built on another machine?) — rebuilding clean from source."
      clean=1
    fi
  fi

  require_space "$INVOKING_HOME" 5 "llama.cpp build"
  _lc_install_deps "$backend" || { log_warn "Dependencies incomplete; aborting build."; return 1; }

  # Clone or update as the human (home-owned tree). If an existing checkout
  # points at a DIFFERENT remote than the configured one (e.g. upstream on disk
  # but the config now wants the buun fork), re-clone from scratch rather than
  # trying to pull one repo's history onto another.
  if [[ -d "$LC_DIR/.git" ]]; then
    local cur_origin
    cur_origin="$(run_as_user git -C "$LC_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$cur_origin" && "$cur_origin" != "$LC_REPO" ]]; then
      log_warn "Checkout at ${LC_DIR} tracks ${cur_origin}, but config wants ${LC_REPO} — re-cloning."
      run_as_user rm -rf "$LC_DIR"
      narrate "Cloning ${LC_REPO}."
      run_as_user git clone "$LC_REPO" "$LC_DIR"
      clean=1
    else
      narrate "Updating existing checkout."
      run_as_user git -C "$LC_DIR" pull --ff-only || log_warn "git pull failed; building current checkout."
    fi
  else
    narrate "Cloning ${LC_REPO}."
    run_as_user git clone "$LC_REPO" "$LC_DIR"
  fi

  # Optionally pin a branch/tag/commit for reproducible builds.
  if [[ -n "$LC_REF" ]]; then
    narrate "Checking out ref ${LC_REF}."
    run_as_user git -C "$LC_DIR" fetch --all --tags --quiet 2>/dev/null || true
    run_as_user git -C "$LC_DIR" checkout "$LC_REF" || log_warn "Could not check out ref ${LC_REF}; building the default branch."
  fi

  # A forced or moved-machine rebuild starts from a clean build/ tree: the
  # carried-over directory holds the previous host's CMakeCache (wrong compiler
  # paths) and half-generated assets that make a reconfigure fail.
  if (( clean )) && [[ -d "$LC_DIR/build" ]]; then
    narrate "Removing the stale build/ tree for a clean reconfigure."
    run_as_user rm -rf "$LC_DIR/build"
  fi

  # Configure + compile, output streaming live (no hidden progress bar).
  local -a flags; mapfile -t flags < <(_lc_cmake_flags "$backend")
  narrate "Configuring the build (${backend})."
  if ! run_as_user cmake "${flags[@]}"; then
    log_error "CMake configuration failed (see the output above)."
    [[ "$backend" == cuda ]] && log_error "If it can't find the CUDA compiler, run 'sudo ${SCRIPT_PATH##*/} drivers' first."
    return 1
  fi
  narrate "Compiling with $(nproc) jobs — this can take several minutes; output is shown live."
  if ! run_as_user cmake --build "$LC_DIR/build" --config Release -j "$(nproc)"; then
    log_error "Compilation failed (see the output above)."
    return 1
  fi

  cfg_set LLAMACPP_DIR "$LC_DIR"
  cfg_set LLAMACPP_BIN "$bin"
  cfg_set LLAMACPP_BACKEND "$backend"
  cfg_set LLAMACPP_REPO "$LC_REPO"
  [[ -n "$LC_REF" ]] && cfg_set LLAMACPP_REF "$LC_REF"
  cfg_save
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] skipping post-build verification of ${bin}."
    return 0
  fi
  [[ -x "$bin" ]] || die "Build finished but $bin is missing."
  log_ok "Built llama.cpp ($backend): $bin"
  "$bin" --version 2>&1 | head -3 | sed 's/^/    /' >&2 || true
}

module_uninstall() {
  log_step "Removing llama.cpp build"
  local dir; dir="$(cfg_get LLAMACPP_DIR "$INVOKING_HOME/llama.cpp")"
  if ui_yesno "Delete the whole source + build tree at ${dir}?"; then
    run rm -rf "$dir"
    cfg_del LLAMACPP_DIR; cfg_del LLAMACPP_BIN; cfg_del LLAMACPP_BACKEND; cfg_save
    log_ok "Removed ${dir}."
  else
    log_info "Kept ${dir}."
  fi
}
