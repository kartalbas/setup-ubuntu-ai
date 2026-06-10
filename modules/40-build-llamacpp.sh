# shellcheck shell=bash
# modules/40-build-llamacpp.sh — build llama.cpp from source with the backend
# that matches the GPU: CUDA (sm_120) for NVIDIA, Vulkan for AMD.
# Builds in the invoking user's home so rebuilds need no sudo.
# shellcheck source=/dev/null

LLAMACPP_REPO="https://github.com/ggml-org/llama.cpp"

_lc_backend() {
  case "$(cfg_get HW_VENDOR)" in
    nvidia) echo cuda ;;
    amd)    echo vulkan ;;
    *)      ui_menu "Backend" "GPU vendor unknown — pick a llama.cpp backend:" \
              cuda "NVIDIA CUDA" vulkan "AMD/Intel Vulkan" cpu "CPU only" ;;
  esac
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

_lc_cmake_flags() {
  local backend="$1"
  local -a f=( -S "$LC_DIR" -B "$LC_DIR/build" -DCMAKE_BUILD_TYPE=Release )
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
  local bin="$LC_DIR/build/bin/llama-server"

  # Resolve an absolute nvcc so CMake finds it when building as the user.
  if [[ "$backend" == cuda ]]; then
    LC_NVCC="$(command -v nvcc 2>/dev/null || true)"
    [[ -z "$LC_NVCC" && -x /usr/local/cuda/bin/nvcc ]] && LC_NVCC=/usr/local/cuda/bin/nvcc
    [[ -n "$LC_NVCC" ]] && log_info "Using CUDA compiler: $LC_NVCC"
  fi

  log_info "Backend: ${backend}   Source dir: ${LC_DIR}"

  if [[ -x "$bin" && "$(cfg_get LLAMACPP_BACKEND)" == "$backend" && $force -eq 0 ]]; then
    log_ok "llama.cpp already built ($backend) → $bin"
    ui_yesno "Pull latest and rebuild?" || return 0
  fi

  require_space "$INVOKING_HOME" 5 "llama.cpp build"
  _lc_install_deps "$backend" || { log_warn "Dependencies incomplete; aborting build."; return 1; }

  # Clone or update as the human (home-owned tree).
  if [[ -d "$LC_DIR/.git" ]]; then
    narrate "Updating existing checkout."
    run_as_user git -C "$LC_DIR" pull --ff-only || log_warn "git pull failed; building current checkout."
  else
    narrate "Cloning llama.cpp."
    run_as_user git clone "$LLAMACPP_REPO" "$LC_DIR"
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
