#!/usr/bin/env bash
# setup-ubuntu-ai — modular, verbose, user-friendly local AI-inference installer.
#
#   sudo ./setup.sh [COMMAND] [FLAGS]
#
# Run with no command for the interactive menu, or drive it one deliberate
# step at a time with the verbs below. See ./setup.sh --help.

# ---- locate ourselves (must happen before anything else, for sudo re-exec) -
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(dirname -- "$SCRIPT_PATH")"
declare -ga SCRIPT_ARGS=("$@")
export REPO_ROOT SCRIPT_PATH

# ---- source the library (order matters) ------------------------------------
for _lib in log core fs config ui version distro privilege apt state hardware; do
  # shellcheck source=/dev/null
  . "$REPO_ROOT/lib/${_lib}.sh"
done

VERSION="1.0.0"
VERB=""
declare -ga VERB_ARGS=()

usage() {
  cat >&2 <<EOF
${C_BOLD}setup-ubuntu-ai${C_RST} v${VERSION} — local AI inference installer (NVIDIA / AMD)

${C_BOLD}USAGE${C_RST}
  sudo ./setup.sh [COMMAND] [FLAGS]

${C_BOLD}COMMANDS${C_RST} (run them in this order, one at a time, or use the menu)
  detect           Identify the GPU and save the hardware profile
  drivers          Install the driver stack (NVIDIA CUDA, or AMD Vulkan)
  vram <GiB>       AMD Strix Halo only: set the unified-memory / GTT split
  power [WATTS]    NVIDIA only: cap GPU power (TDP), re-applied on every boot
  build [--force]  Build llama.cpp from source (CUDA or Vulkan backend)
  model            Download / select a GGUF model (interactive)
  configure        Set context size, GPU layers, host/port, extra args
  service [sub]    Install llama-server as an auto-starting systemd daemon
                   sub = install|uninstall|enable|disable|restart|status
  doctor           Read-only health check of the whole stack
  status           Show detected hardware, config and service state
  uninstall [what] Reverse a step (drivers|llamacpp|service|all)
  resume           Continue a guided run interrupted by a reboot
  restore          Rebuild the whole stack unattended from config (A→Z):
                   drivers, llama.cpp, the exact model, runtime + service
  menu             Open the interactive menu (default when no command given)

${C_BOLD}FLAGS${C_RST}
  --dry-run        Show every command without changing anything
  -y, --yes        Assume "yes" for all prompts (unattended)
  --quiet          Suppress the verbose ▶ command echo
  --no-ui          Plain text menus instead of whiptail
  --log-level L    debug | info | warn | error   (default: info)
  --config PATH    Use an alternate config file
  -h, --help       This help
  -V, --version    Print version

${C_BOLD}EXAMPLES${C_RST}
  sudo ./setup.sh detect
  sudo ./setup.sh drivers
  sudo ./setup.sh build
  sudo ./setup.sh model
  sudo ./setup.sh configure
  sudo ./setup.sh service install
  sudo ./setup.sh --dry-run            # explore the menu, change nothing
EOF
}

parse_args() {
  local positional=()
  # Globals below are consumed by the dynamically-sourced lib/*.sh files (which
  # the linter cannot follow), so silence the unused-variable warning.
  # shellcheck disable=SC2034
  while (( $# )); do
    case "$1" in
      --dry-run)      DRY_RUN=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      --quiet)        QUIET=1 ;;
      --no-ui)        NO_UI=1 ;;
      --log-level)    LOG_LEVEL="${2:?--log-level needs a value}"; shift ;;
      --log-level=*)  LOG_LEVEL="${1#*=}" ;;
      --config)       CONFIG_FILE="${2:?--config needs a path}"; shift ;;
      --config=*)     CONFIG_FILE="${1#*=}" ;;
      -h|--help)      usage; exit 0 ;;
      -V|--version)   echo "$VERSION"; exit 0 ;;
      --)             shift; while (( $# )); do positional+=("$1"); shift; done; break ;;
      -*)             die "Unknown flag: $1 (try --help)" ;;
      *)              positional+=("$1") ;;
    esac
    shift
  done
  if (( ${#positional[@]} )); then
    VERB="${positional[0]}"
    VERB_ARGS=("${positional[@]:1}")
  fi
}

# MODULE_RC holds the exit status of the last run_module/run_module_fn call.
# run_module itself ALWAYS returns 0 so a failed step returns control to the
# menu/dispatch instead of tripping the orchestrator's own errexit.
MODULE_RC=0

# run_module NAME [ARGS...] — source a module in an isolated subshell and call
# its module_main, capturing the result in MODULE_RC. run_module itself ALWAYS
# returns 0 so a failed step returns control to the menu instead of tripping the
# orchestrator's own errexit. (Note: bash disables errexit inside a subshell on
# the left of `||`, so modules use explicit error handling, not `set -e`.)
run_module() {
  local mod="$1"; shift
  local f="$REPO_ROOT/modules/${mod}.sh"
  [[ -f "$f" ]] || die "Module not found: ${mod}"
  MODULE_RC=0
  # shellcheck source=/dev/null
  ( . "$f"; module_main "$@" ) || MODULE_RC=$?
  cfg_load
  (( MODULE_RC == 0 )) || log_warn "Step '${mod}' did not complete (exit ${MODULE_RC}). See ${LOG_FILE}."
  return 0
}

# run_module_fn NAME FUNC [ARGS...] — call a specific function in a module
# (e.g. module_uninstall) instead of module_main.
run_module_fn() {
  local mod="$1" fn="$2"; shift 2
  local f="$REPO_ROOT/modules/${mod}.sh"
  [[ -f "$f" ]] || die "Module not found: ${mod}"
  MODULE_RC=0
  # shellcheck source=/dev/null
  ( . "$f"; "$fn" "$@" ) || MODULE_RC=$?
  cfg_load
  return 0
}

ensure_hw_detected() {
  local v; v="$(cfg_get HW_VENDOR)"
  if [[ -z "$v" || "$v" == "unknown" ]]; then
    run_module 10-detect-hardware
  fi
}

dispatch_drivers() {
  ensure_hw_detected
  case "$(cfg_get HW_VENDOR)" in
    nvidia) run_module 20-drivers-nvidia ;;
    amd)    run_module 21-drivers-amd ;;
    *)      log_error "Cannot install drivers: GPU vendor is unknown. Run 'detect' first."; MODULE_RC=1 ;;
  esac
  return 0
}

_driver_summary() {
  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    local v; v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
    echo "NVIDIA ${v:-present}"
  elif have nvidia-smi; then
    echo "package installed, but driver not loaded (reboot needed?)"
  elif have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; then
    echo "Vulkan present"
  else
    echo "not installed"
  fi
}

cmd_status() {
  ensure_hw_detected
  printf '\n%s%s── System ──%s\n' "$C_BOLD" "$C_CYAN" "$C_RST"
  printf '  Distro      : %s\n' "$DISTRO_PRETTY"
  printf '  CPU         : %s\n' "$(cfg_get HW_CPU '?')"
  printf '  RAM         : %s GiB\n' "$(cfg_get HW_RAM_GB '?')"
  printf '  GPU vendor  : %s\n' "$(cfg_get HW_VENDOR '?')"
  printf '  GPU model   : %s\n' "$(cfg_get HW_MODEL '?')"
  printf '  GPU budget  : %s GiB\n' "$(gpu_budget_gb)"
  printf '\n%s%s── Stack ──%s\n' "$C_BOLD" "$C_CYAN" "$C_RST"
  printf '  Driver      : %s\n' "$(_driver_summary)"
  printf '  llama.cpp   : %s (backend: %s)\n' \
    "$([[ -x "$(cfg_get LLAMACPP_BIN "$INVOKING_HOME/llama.cpp/build/bin/llama-server")" ]] && echo built || echo 'not built')" \
    "$(cfg_get LLAMACPP_BACKEND '?')"
  printf '  Model       : %s\n' "$(cfg_get LLAMA_MODEL '(none selected)')"
  local svc; svc="$(systemctl is-enabled llama-server 2>/dev/null || true)"
  [[ -z "$svc" || "$svc" == "not-found" ]] && svc="not installed"
  printf '  Service     : %s\n' "$svc"
  local pl; pl="$(cfg_get NVIDIA_POWER_LIMIT_W)"
  [[ -n "$pl" ]] && printf '  Power limit : %sW (enforced on boot)\n' "$pl"
  echo
}

cmd_uninstall() {
  local what="${1:-}"
  [[ -z "$what" ]] && {
    what="$(ui_menu "Uninstall" "What should I remove?" \
      drivers "GPU drivers" power "GPU power limit" llamacpp "llama.cpp build" service "llama-server service" all "Everything")" || return 0
  }
  case "$what" in
    drivers)  ensure_hw_detected
              if [[ "$(cfg_get HW_VENDOR)" == nvidia ]]; then
                run_module_fn 20-drivers-nvidia module_uninstall
              else
                run_module_fn 21-drivers-amd module_uninstall
              fi ;;
    power)    run_module_fn 35-power-limit module_uninstall ;;
    llamacpp) run_module_fn 40-build-llamacpp module_uninstall ;;
    service)  run_module_fn 60-service-llama module_uninstall ;;
    all)      run_module_fn 60-service-llama module_uninstall || true
              run_module_fn 40-build-llamacpp module_uninstall || true
              log_warn "GPU drivers left in place (remove manually if desired)." ;;
    *)        die "Unknown uninstall target: $what" ;;
  esac
}

cmd_resume() {
  local from; from="$(state_get RESUME_FROM)"
  if [[ -z "$from" || "$(state_get RESUME_PENDING 0)" != "1" ]]; then
    log_info "Nothing to resume."; return 0
  fi
  log_step "Resuming guided setup after reboot (from: ${from})"
  resume_cleanup
  guided_all "$from"
}

# _restore_rehome — make a config carried from another machine portable. The
# config may embed absolute paths under a different user's home (e.g. another
# mini-PC's /home/<other>); rewrite that home prefix to THIS machine's home so
# the model dir, llama.cpp dir and binary land in the right place. The GPU is
# the same external eGPU, so only the host-side paths move. No-op when the home
# already matches. Detected/derived keys (HW_*, LLAMA_MODEL, LLAMACPP_BIN) are
# re-set by the steps themselves, so this just keeps the *roots* correct.
_restore_rehome() {
  local new_home="$INVOKING_HOME" old_home="" k v
  for k in LLAMA_MODEL LLAMACPP_DIR MODEL_DIR LLAMACPP_BIN; do
    v="$(cfg_get "$k")"
    if [[ "$v" =~ ^(/home/[^/]+|/root) ]]; then old_home="${BASH_REMATCH[1]}"; break; fi
  done
  [[ -z "$old_home" || "$old_home" == "$new_home" ]] && return 0
  log_warn "Config paths reference ${old_home}; remapping to ${new_home} for this machine."
  for k in LLAMA_MODEL LLAMACPP_DIR LLAMACPP_BIN MODEL_DIR; do
    v="$(cfg_get "$k")"; [[ -n "$v" ]] && cfg_set "$k" "${v/#$old_home/$new_home}"
  done
  cfg_save
}

# cmd_restore — config-driven, unattended rebuild of the whole stack. The
# config file is the single source of truth: hardware profile, driver package,
# model coordinates (MODEL_REPO/MODEL_FILE) and runtime args all come from it,
# and the chat template is regenerated from the downloaded GGUF. Nothing model-
# specific is committed to the repo. Designed to run on a FRESH machine with the
# same external GPU: hardware is re-detected, paths are re-homed to the new
# user, and stale state flags (CUDA_OK/SERVICE_INSTALLED) are harmless because
# every phase re-runs unconditionally. A NVIDIA Secure-Boot/MOK reboot still
# pauses the run; continue with `resume` afterwards.
cmd_restore() {
  log_step "Restore: rebuild the whole stack from config (A→Z, unattended)"
  if [[ -z "$(cfg_get MODEL_REPO)" || -z "$(cfg_get MODEL_FILE)" ]]; then
    die "No MODEL_REPO/MODEL_FILE in ${CONFIG_FILE}. Run 'sudo ${0##*/} model' once to capture them (or add them by hand), then retry."
  fi
  _restore_rehome
  log_info "Target    : user=${INVOKING_USER} home=${INVOKING_HOME}"
  log_info "Model     : $(cfg_get MODEL_REPO) :: $(cfg_get MODEL_FILE)"
  log_info "Model dir : $(cfg_get MODEL_DIR "$INVOKING_HOME/models")"
  log_info "Context   : $(cfg_get LLAMA_CTX 8192) tokens, ngl=$(cfg_get LLAMA_NGL 999)"
  log_info "Template  : chat-template fixup=$(cfg_get CHAT_TEMPLATE_FIXUP 0)"
  ASSUME_YES=1 NONINTERACTIVE=1
  guided_all detect
}

# guided_all [START_VERB] — walk the phases in order, skipping completed steps.
guided_all() {
  local start="${1:-detect}" started=0
  local phases=(detect drivers power build model configure service doctor)
  ensure_hw_detected
  for p in "${phases[@]}"; do
    [[ "$started" == 0 && "$p" != "$start" ]] && continue
    started=1
    log_step "Guided step: ${p}"
    case "$p" in
      detect)    run_module 10-detect-hardware ;;
      drivers)   dispatch_drivers
                 if (( MODULE_RC != 0 )); then
                   log_warn "Driver step did not finish; stopping guided run here."
                   return 0
                 fi ;;
      power)     # Only when a cap is configured (NVIDIA); pass it explicitly so
                 # the step stays non-interactive. Skipped otherwise.
                 if [[ -n "$(cfg_get NVIDIA_POWER_LIMIT_W)" ]]; then
                   run_module 35-power-limit "$(cfg_get NVIDIA_POWER_LIMIT_W)"
                 else
                   log_info "No power limit configured — skipping."
                 fi ;;
      build)     run_module 40-build-llamacpp ;;
      model)     run_module 50-model-manager ;;
      configure) run_module 55-configure-runtime ;;
      service)   run_module 60-service-llama install ;;
      doctor)    run_module 90-doctor ;;
    esac
    # Stop the guided chain on a hard failure of a prerequisite step.
    if (( MODULE_RC != 0 )) && [[ "$p" == build || "$p" == model ]]; then
      log_warn "Step '${p}' failed; stopping guided run. Fix it, then re-run 'resume' or the menu."
      return 0
    fi
  done
  log_ok "Guided setup complete."
  return 0
}

# _menu_done MOD-or-marker — quick "is this step already done?" probe so the menu
# can show a ✓ / · status hint next to each step. Best-effort and read-only.
_menu_status() {
  case "$1" in
    detect)    [[ -n "$(cfg_get HW_VENDOR)" && "$(cfg_get HW_VENDOR)" != unknown ]] ;;
    drivers)   { have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; } || \
               { have vulkaninfo && vulkaninfo --summary >/dev/null 2>&1; } ;;
    power)     [[ -n "$(cfg_get NVIDIA_POWER_LIMIT_W)" ]] ;;
    build)     [[ -x "$(cfg_get LLAMACPP_BIN "$INVOKING_HOME/llama.cpp/build/bin/llama-server")" ]] ;;
    model)     [[ -n "$(cfg_get LLAMA_MODEL)" ]] ;;
    configure) [[ -n "$(cfg_get LLAMA_CTX)" ]] ;;
    service)   systemctl is-enabled llama-server >/dev/null 2>&1 ;;
    *)         return 1 ;;
  esac
}

# Build "✓"/"·" hint (green check if the step looks complete, dim dot if not).
_menu_hint() { if _menu_status "$1"; then printf '%s✓%s' "$C_GRN" "$C_RST"; else printf '%s·%s' "$C_DIM" "$C_RST"; fi; }

main_menu() {
  ensure_hw_detected
  while :; do
    local hw model; hw="$(cfg_get HW_VENDOR unknown)"; model="$(cfg_get HW_MODEL 'unknown GPU')"

    # Ordered pipeline steps as (action,label) pairs. The label leads with the
    # plain-English action, then a short "what it does" after an em dash.
    local -a actions=() labels=()
    _add() { actions+=("$1"); labels+=("$2 — $3"); }

    _add detect    "Detect hardware"   "scan this machine's GPU, CPU and RAM"
    if [[ "$hw" == nvidia ]]; then
      _add drivers "Install GPU drivers" "NVIDIA driver + CUDA toolkit (Blackwell)"
      _add power   "Set power limit"     "cap GPU watts, re-applied on every boot"
    elif [[ "$hw" == amd ]]; then
      _add drivers "Install GPU drivers" "AMD Vulkan stack (Mesa RADV, no ROCm)"
      _add vram    "Set VRAM split"      "size the unified-memory / GTT budget"
    else
      _add drivers "Install GPU drivers" "GPU driver stack for the detected card"
    fi
    _add build     "Build llama.cpp"   "compile the inference engine from source"
    _add model     "Download a model"  "search & fetch a GGUF from Hugging Face"
    _add configure "Configure runtime" "context size, GPU layers, host & port"
    _add service   "Install service"   "run llama-server, auto-start on boot"
    _add doctor    "Health check"      "diagnose the whole stack, read-only"

    # Render: numeric tags for the ordered steps (auto-aligned two columns),
    # with a ✓/· completion hint; lettered tags for the tools below a spacer.
    local -a items=(); local i
    for i in "${!actions[@]}"; do
      items+=( "$((i+1))" "$(_menu_hint "${actions[i]}") ${labels[i]}" )
    done
    items+=( "" "" )                                            # spacer row
    items+=( "A" "Run ALL steps in order (guided setup)" )
    items+=( "S" "Show status (hardware, config, service)" )
    items+=( "Q" "Quit" )

    local choice
    choice="$(ui_menu_tagged "AI Inference Setup  ·  ${model}" \
      "Steps run top-to-bottom. Pick a number, or A/S/Q:" "${items[@]}")" || break

    case "$choice" in
      A)        guided_all; continue ;;
      S)        cmd_status; ui_pause; continue ;;
      Q|""|" ") break ;;
      *) if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#actions[@]} )); then
           case "${actions[choice-1]}" in
             detect)    run_module 10-detect-hardware ;;
             drivers)   dispatch_drivers ;;
             vram)      run_module 30-amd-vram ;;
             power)     run_module 35-power-limit ;;
             build)     run_module 40-build-llamacpp ;;
             model)     run_module 50-model-manager ;;
             configure) run_module 55-configure-runtime ;;
             service)   run_module 60-service-llama ;;
             doctor)    run_module 90-doctor ;;
           esac
         else
           log_warn "Pick a step number (1–${#actions[@]}) or A/S/Q."
         fi ;;
    esac
  done
  log_info "Bye."
}

main() {
  parse_args "${SCRIPT_ARGS[@]}"
  ensure_root
  # Create the log directory for real (even under --dry-run): the transcript is
  # always wanted and writing it changes nothing the user cares about.
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  _logfile START "==== setup-ubuntu-ai v${VERSION} : ${VERB:-menu} ${VERB_ARGS[*]} ===="
  detect_distro
  assert_supported
  cfg_load

  case "${VERB:-menu}" in
    detect)     run_module 10-detect-hardware ;;
    drivers)    dispatch_drivers ;;
    vram)       run_module 30-amd-vram "${VERB_ARGS[@]}" ;;
    power)      run_module 35-power-limit "${VERB_ARGS[@]}" ;;
    build)      run_module 40-build-llamacpp "${VERB_ARGS[@]}" ;;
    model)      run_module 50-model-manager ;;
    configure)  run_module 55-configure-runtime ;;
    service)    run_module 60-service-llama "${VERB_ARGS[@]}" ;;
    doctor)     run_module 90-doctor ;;
    preflight)  run_module 00-preflight ;;
    status)     cmd_status ;;
    uninstall)  cmd_uninstall "${VERB_ARGS[@]}" ;;
    resume)     cmd_resume ;;
    restore)    cmd_restore ;;
    menu)       main_menu ;;
    *)          die "Unknown command: ${VERB} (try --help)" ;;
  esac
}

main
