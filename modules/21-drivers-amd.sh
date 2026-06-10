# shellcheck shell=bash
# modules/21-drivers-amd.sh — AMD VULKAN ONLY (no ROCm). Mesa RADV + loader +
# tools + firmware. Targets Strix Halo (gfx1151) but works for any RDNA card.
# shellcheck source=/dev/null

_MESA_FLOOR="24.2"   # RADV support floor for gfx1151 / Strix Halo

_amd_mesa_version() {
  local v=""
  if have vulkaninfo; then
    v="$(vulkaninfo --summary 2>/dev/null | grep -ioE 'Mesa [0-9.]+' | head -1 | grep -oE '[0-9.]+')"
  fi
  [[ -z "$v" ]] && v="$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')"
  echo "$v"
}

_amd_check_mesa() {
  local v; v="$(_amd_mesa_version)"
  if [[ -z "$v" ]]; then log_warn "Could not determine Mesa version."; return 0; fi
  if ver_ge "$v" "$_MESA_FLOOR"; then
    log_ok "Mesa ${v} ≥ ${_MESA_FLOOR} — new enough for gfx1151 (Strix Halo)."
  else
    log_warn "Mesa ${v} is older than ${_MESA_FLOOR}; RADV may not support gfx1151 well."
    if ui_yesno "Add the kisak-mesa PPA to get a newer Mesa? (third-party PPA)"; then
      apt_install software-properties-common
      run add-apt-repository -y ppa:kisak/kisak-mesa
      _APT_UPDATED=0
      run apt-get upgrade -y mesa-vulkan-drivers libvulkan1 || true
    fi
  fi
}

_amd_groups() {
  narrate "Granting '${INVOKING_USER}' access to the GPU render nodes (video, render groups)."
  run usermod -aG video,render "$INVOKING_USER" || true
}

_amd_verify() {
  if ! have vulkaninfo; then log_warn "vulkaninfo not found; install vulkan-tools."; return 0; fi
  log_info "Vulkan devices:"
  if vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName|RADV|gfx1151' | sed 's/^/    /' >&2; then
    log_ok "Vulkan is reporting a GPU."
  else
    log_warn "vulkaninfo did not list a GPU — a reboot or re-login may be needed for group changes."
  fi
}

module_main() {
  log_step "AMD Vulkan drivers (Mesa RADV — no ROCm)"
  narrate "Installing the Vulkan stack only, exactly as configured for this project."

  apt_install mesa-vulkan-drivers libvulkan1 vulkan-tools libvulkan-dev \
              libdrm2 mesa-utils linux-firmware

  _amd_check_mesa
  _amd_groups
  _amd_verify

  cfg_set AMD_VULKAN_OK 1; cfg_save
  log_ok "AMD Vulkan stack ready."
  [[ "$(cfg_get HW_GFX)" == "gfx1151" ]] && \
    log_info "Tip: set the GPU VRAM / unified-memory split with  sudo ${SCRIPT_PATH##*/} vram <GiB>"
}

module_uninstall() {
  log_step "Removing AMD Vulkan extras"
  log_warn "Mesa/Vulkan is part of your desktop graphics stack — only removing the dev/tools extras."
  apt_wait_locks
  run apt-get purge -y vulkan-tools libvulkan-dev 2>/dev/null || true
  run apt-get autoremove -y || true
  cfg_del AMD_VULKAN_OK; cfg_save
  log_ok "Removed Vulkan dev/tools (core Mesa left intact)."
}
