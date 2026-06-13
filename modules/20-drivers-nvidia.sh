# shellcheck shell=bash
# modules/20-drivers-nvidia.sh — NVIDIA open driver + CUDA toolkit for Blackwell.
# Open kernel modules are REQUIRED for RTX 50-series (Blackwell). Handles Secure
# Boot, nouveau blacklisting, persistence daemon, and the CUDA compiler.
# shellcheck source=/dev/null

NVIDIA_DEFAULT_PKG="nvidia-driver-595-open"

_nv_pick_pkg() {
  local pkg; pkg="$(cfg_get NVIDIA_DRIVER_PKG)"
  if [[ -z "$pkg" ]] && have ubuntu-drivers; then
    # Prefer the distro-recommended *-open metapackage.
    pkg="$(ubuntu-drivers devices 2>/dev/null | awk '/recommended/ && /-open/ {print $3; exit}')"
    [[ -z "$pkg" ]] && pkg="$(ubuntu-drivers devices 2>/dev/null | awk '/nvidia-driver-[0-9]+-open/ {print $3; exit}')"
  fi
  echo "${pkg:-$NVIDIA_DEFAULT_PKG}"
}

_nv_already() {
  local pkg="$1"
  pkg_installed "$pkg" && have nvidia-smi && nvidia-smi -L >/dev/null 2>&1
}

_nv_secureboot_preflight() {
  have mokutil || { log_debug "mokutil absent; assuming no Secure Boot."; return 0; }
  if ! mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    log_ok "Secure Boot disabled — kernel modules load unsigned."
    return 0
  fi
  log_warn "Secure Boot is ENABLED."
  narrate "Blackwell needs the open kernel module; under Secure Boot a module must be signed & enrolled."

  # Unattended (restore): honour the strategy already in the config instead of
  # prompting. 'canonical' needs no console — Ubuntu's pre-signed
  # linux-modules-nvidia are trusted via Canonical's CA in the shim db — so the
  # whole driver step runs hands-off. (A 'mok' strategy still needs a physical
  # console at reboot; no script can avoid that.)
  local c
  if [[ -n "${NONINTERACTIVE:-}" ]]; then
    c="$(cfg_get NVIDIA_MOK_STRATEGY canonical)"
    log_info "Non-interactive: using Secure Boot strategy from config → ${c}"
  else
    c="$(ui_menu "Secure Boot" "Secure Boot is enabled. How should kernel-module signing be handled?" \
          canonical "Use Ubuntu's pre-signed modules — recommended, no console needed" \
          mok       "Enroll a MOK key now — requires PHYSICAL CONSOLE at reboot" \
          disable   "I'll disable Secure Boot in BIOS myself" \
          abort     "Abort the driver install")" || c=abort
  fi
  case "$c" in
    canonical) cfg_set NVIDIA_MOK_STRATEGY canonical
               narrate "Preferring Canonical-signed linux-modules-nvidia over a DKMS build." ;;
    mok)       cfg_set NVIDIA_MOK_STRATEGY mok; cfg_set NVIDIA_MOK_PENDING 1 ;;
    disable)   ui_msg "Reboot into your firmware, turn Secure Boot OFF, then run:\n  sudo ${SCRIPT_PATH##*/} drivers" "Disable Secure Boot"; return 1 ;;
    abort)     log_warn "Driver install aborted by user (Secure Boot)."; return 1 ;;
  esac
  cfg_save
}

_nv_blacklist_nouveau() {
  local f=/etc/modprobe.d/blacklist-nouveau.conf
  local content=$'# Added by setup-ubuntu-ai\nblacklist nouveau\noptions nouveau modeset=0\n'
  if [[ -f "$f" ]] && ! lsmod | grep -q '^nouveau'; then
    log_ok "nouveau already blacklisted."
    return 0
  fi
  narrate "Blacklisting the nouveau driver so the NVIDIA module owns the GPU."
  backup_file "$f"
  show_diff "$f" <<<"$content" || true
  printf '%s' "$content" | atomic_write "$f"
  run update-initramfs -u
}

_nv_enable_persistenced() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^nvidia-persistenced'; then
    narrate "Enabling nvidia-persistenced for stable headless clocks & lower latency."
    run systemctl enable --now nvidia-persistenced || log_warn "Could not start nvidia-persistenced yet (needs the driver loaded)."
  fi
}

_nv_install_cuda() {
  if have nvcc && nvcc --list-gpu-arch 2>/dev/null | grep -q 'compute_120'; then
    log_ok "CUDA toolkit already present and supports sm_120."
    cfg_set CUDA_OK 1; cfg_save; return 0
  fi
  narrate "Installing the CUDA toolkit (nvcc) — needed to compile llama.cpp for Blackwell (sm_120, CUDA ≥12.8)."
  local arch=x86_64 base="https://developer.download.nvidia.com/compute/cuda/repos"
  local distro="ubuntu${DISTRO_VER//./}"
  if ! curl -fsI "${base}/${distro}/${arch}/cuda-keyring_1.1-1_all.deb" >/dev/null 2>&1; then
    log_warn "No CUDA repo for ${distro}; falling back to ubuntu2404 (forward-compatible)."
    distro="ubuntu2404"
  fi
  local deb="/tmp/cuda-keyring_1.1-1_all.deb"
  run curl -fsSL -o "$deb" "${base}/${distro}/${arch}/cuda-keyring_1.1-1_all.deb"
  run dpkg -i "$deb"
  _APT_UPDATED=0
  apt_install cuda-toolkit

  # Put nvcc on PATH for every shell.
  local prof=/etc/profile.d/cuda.sh
  local content=$'export PATH=/usr/local/cuda/bin:$PATH\nexport LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}\n'
  show_diff "$prof" <<<"$content" || true
  printf '%s' "$content" | atomic_write "$prof"
  export PATH=/usr/local/cuda/bin:$PATH

  if have nvcc && nvcc --list-gpu-arch 2>/dev/null | grep -q 'compute_120'; then
    log_ok "CUDA toolkit installed; sm_120 supported."
    cfg_set CUDA_OK 1
  else
    log_warn "CUDA installed but sm_120 not listed by nvcc — the llama.cpp CUDA build may need a newer toolkit."
    cfg_set CUDA_OK 0
  fi
  cfg_save
}

_nv_enroll_mok() {
  [[ "$(cfg_get NVIDIA_MOK_STRATEGY)" == "mok" ]] || return 0
  if have update-secureboot-policy; then
    narrate "Enrolling a DKMS signing key (you'll set a one-time password)."
    run update-secureboot-policy --enroll-key || true
  fi
  ui_msg "MOK ENROLLMENT — PHYSICAL CONSOLE REQUIRED AT NEXT REBOOT:
  1. Reboot the machine.
  2. A blue 'MOK Manager' screen appears (not over SSH!).
  3. Choose 'Enroll MOK' → Continue → enter the password you just set → reboot.
Until you do this, the NVIDIA module will not load under Secure Boot." "Action needed at reboot"
}

module_main() {
  log_step "NVIDIA driver + CUDA (Blackwell)"
  local pkg; pkg="$(_nv_pick_pkg)"
  log_info "Driver package: ${pkg}"

  if _nv_already "$pkg"; then
    log_ok "NVIDIA driver already installed and responding:"
    nvidia-smi -L >&2 || true
    _nv_install_cuda
    return 0
  fi

  _nv_secureboot_preflight || { log_warn "Stopping NVIDIA install before changes."; return 0; }

  cfg_set NVIDIA_DRIVER_PKG "$pkg"; cfg_save
  apt_install "$pkg"
  _nv_blacklist_nouveau
  _nv_enable_persistenced
  _nv_install_cuda
  _nv_enroll_mok

  if nvidia-smi -L >/dev/null 2>&1; then
    log_ok "NVIDIA driver active:"; nvidia-smi -L >&2 || true
  else
    log_warn "Driver installed but the kernel module isn't loaded yet — a reboot is required."
    offer_reboot "load the NVIDIA kernel module" "drivers"
  fi
}

module_uninstall() {
  log_step "Removing NVIDIA driver + CUDA"
  local pkg; pkg="$(cfg_get NVIDIA_DRIVER_PKG "$NVIDIA_DEFAULT_PKG")"
  run systemctl disable --now nvidia-persistenced 2>/dev/null || true
  apt_wait_locks
  run apt-get purge -y "$pkg" 'cuda-toolkit*' 'nvidia-*' 2>/dev/null || true
  run apt-get autoremove -y || true
  run rm -f /etc/modprobe.d/blacklist-nouveau.conf /etc/profile.d/cuda.sh
  run update-initramfs -u || true
  cfg_del CUDA_OK; cfg_del NVIDIA_MOK_PENDING; cfg_save
  log_ok "NVIDIA stack removed (reboot to fully unload)."
}
