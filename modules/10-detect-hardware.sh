# shellcheck shell=bash
# modules/10-detect-hardware.sh — classify the machine and print a report.
# shellcheck source=/dev/null

_print_report() {
  printf '\n%s%s──────── Hardware report ────────%s\n' "$C_BOLD" "$C_CYAN" "$C_RST"
  printf '  %-14s %s\n' "GPU vendor"  "$(cfg_get HW_VENDOR)"
  printf '  %-14s %s\n' "GPU model"   "$(cfg_get HW_MODEL)"
  [[ -n "$(cfg_get HW_GFX)" ]]     && printf '  %-14s %s\n' "GFX target"  "$(cfg_get HW_GFX)"
  [[ -n "$(cfg_get HW_SM)" ]]      && printf '  %-14s sm_%s\n' "CUDA arch" "$(cfg_get HW_SM)"
  [[ -n "$(cfg_get HW_VRAM_GB)" ]] && printf '  %-14s %s GiB\n' "VRAM"     "$(cfg_get HW_VRAM_GB)"
  case "$(cfg_get HW_LINK)" in
    thunderbolt) printf '  %-14s %s\n' "GPU link"   "Thunderbolt / USB4 (PCIe tunnelled, authorized)" ;;
    pci)         printf '  %-14s %s\n' "GPU link"   "direct PCIe (OcuLink / slot)" ;;
  esac
  printf '  %-14s %s\n' "CPU"        "$(cfg_get HW_CPU)"
  printf '  %-14s %s GiB\n' "System RAM" "$(cfg_get HW_RAM_GB)"
  printf '  %-14s %s\n' "Inference"   "$(case "$(cfg_get HW_VENDOR)" in
                                          nvidia) echo 'CUDA backend (llama.cpp GGML_CUDA)';;
                                          amd)    echo 'Vulkan backend (llama.cpp GGML_VULKAN)';;
                                          *)      echo 'unknown';; esac)"
  printf '%s%s─────────────────────────────────%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RST"

  if have lspci; then
    log_debug "Display controllers seen by lspci:"
    lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | sed 's/^/    /' >&2 || true
  fi
}

module_main() {
  log_step "Detecting hardware"
  # A Thunderbolt/USB4-attached eGPU is invisible to lspci until the dock is
  # authorized; an OcuLink/slot card is already on the bus. Bring whichever is
  # present online *before* scanning, so detection is transport-agnostic.
  ensure_egpu_online
  narrate "Reading lspci device IDs and /proc/cpuinfo to pick the right driver + backend."
  detect_hardware

  if [[ "$(cfg_get HW_VENDOR)" == "unknown" ]]; then
    log_warn "No supported GPU auto-detected."
    local v
    v="$(ui_menu "Select GPU vendor" "Auto-detection failed. Choose your GPU vendor manually:" \
          nvidia "NVIDIA (CUDA backend)" \
          amd    "AMD (Vulkan backend)" \
          skip   "Skip / decide later")" || v="skip"
    case "$v" in
      nvidia) cfg_set HW_VENDOR nvidia; cfg_set HW_MODEL "NVIDIA GPU (manual)" ;;
      amd)    cfg_set HW_VENDOR amd;    cfg_set HW_MODEL "AMD GPU (manual)" ;;
    esac
  fi

  cfg_save
  _print_report
  log_ok "Hardware profile saved to ${CONFIG_FILE}."
}
