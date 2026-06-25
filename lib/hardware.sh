# shellcheck shell=bash
# lib/hardware.sh — GPU / CPU detection. Classifies the machine into one of the
# supported profiles and records HW_* keys in config.
[[ -n "${_HARDWARE_SH_LOADED:-}" ]] && return 0
_HARDWARE_SH_LOADED=1

# Representative PCI IDs (vendor:device). We match both the numeric ID and the
# human-readable lspci string, plus /proc/cpuinfo for the Strix Halo APU.
_NVIDIA_VENDOR='10de'
_AMD_VENDOR='1002'

_lspci_lines() {
  if have lspci; then lspci -nn 2>/dev/null; else echo ""; fi
}

# detect_hardware — sets globals + CFG keys: HW_VENDOR HW_MODEL HW_GFX HW_SM
# HW_VRAM_GB HW_LINK. Returns 0 always (falls back to 'unknown' / manual pick).
# NOTE: this is read-only; bringing a Thunderbolt eGPU onto the bus first is the
# job of ensure_egpu_online() (lib/thunderbolt.sh), called by the detect step.
detect_hardware() {
  local pci cpu
  pci="$(_lspci_lines)"
  cpu="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"

  HW_VENDOR="unknown"; HW_MODEL="Unrecognized GPU"; HW_GFX=""; HW_SM=""; HW_VRAM_GB=""; HW_LINK=""

  # --- NVIDIA RTX 50-series / Blackwell (all sm_120) ---
  # The whole consumer Blackwell family shares CUDA arch sm_120; only the model
  # name and VRAM differ. Match specific known cards first (for accurate VRAM
  # before the driver/nvidia-smi exists), then any GB20x / RTX 50xx generically.
  if grep -qiE "\[${_NVIDIA_VENDOR}:2b85\]|RTX 5090|GB202" <<<"$pci"; then
    HW_VENDOR="nvidia"; HW_MODEL="NVIDIA GeForce RTX 5090 (Blackwell, sm_120)"
    HW_SM="120"; HW_VRAM_GB="32"
  elif grep -qiE "\[${_NVIDIA_VENDOR}:2c02\]|RTX 5080" <<<"$pci"; then
    HW_VENDOR="nvidia"; HW_MODEL="NVIDIA GeForce RTX 5080 (Blackwell, sm_120)"
    HW_SM="120"; HW_VRAM_GB="16"
  elif grep -qiE "GB20[0-9]|RTX 50[0-9]{2}" <<<"$pci"; then
    # Other RTX 50-series (5070 Ti/5070/…): same CUDA arch, VRAM via nvidia-smi.
    HW_VENDOR="nvidia"
    HW_MODEL="$(grep -iE 'VGA|3D' <<<"$pci" | grep -iE "${_NVIDIA_VENDOR}|NVIDIA" | head -1 | sed 's/.*: //')" || true
    HW_MODEL="${HW_MODEL:-NVIDIA GeForce RTX 50-series (Blackwell)} (sm_120)"
    HW_SM="120"; HW_VRAM_GB=""
  elif grep -qiE "VGA.*${_NVIDIA_VENDOR}|3D controller.*${_NVIDIA_VENDOR}|NVIDIA Corporation" <<<"$pci"; then
    # Some other NVIDIA card — supported via the same CUDA path, arch unknown.
    HW_VENDOR="nvidia"
    HW_MODEL="$(grep -iE "${_NVIDIA_VENDOR}|NVIDIA" <<<"$pci" | grep -iE 'VGA|3D' | head -1 | sed 's/.*: //')"
    HW_MODEL="${HW_MODEL:-NVIDIA GPU (generic)}"
    HW_SM=""; HW_VRAM_GB=""
  # --- AMD Ryzen AI Max+ 395 "Strix Halo" / Radeon 8060S (gfx1151) ---
  elif grep -qiE "Radeon 8060S|Strix Halo|\[${_AMD_VENDOR}:1586\]" <<<"$pci" \
       || grep -qiE 'Ryzen AI Max\+? *395|Ryzen AI Max' <<<"$cpu"; then
    HW_VENDOR="amd"; HW_MODEL="AMD Ryzen AI Max+ 395 — Radeon 8060S (gfx1151, RDNA3.5)"
    HW_GFX="gfx1151"
  # --- some other AMD Radeon (Vulkan path still applies) ---
  elif grep -qiE "VGA.*${_AMD_VENDOR}|Display.*${_AMD_VENDOR}|Advanced Micro Devices.*\[AMD/ATI\]" <<<"$pci"; then
    HW_VENDOR="amd"
    HW_MODEL="$(grep -iE 'VGA|Display|3D' <<<"$pci" | grep -i 'AMD/ATI' | head -1 | sed 's/.*: //')"
    HW_MODEL="${HW_MODEL:-AMD Radeon GPU (generic)}"
  fi

  # If nvidia-smi is already present, trust it for an accurate VRAM figure.
  # On a laptop/host with BOTH an internal dGPU and an external eGPU, more than
  # one NVIDIA card is listed — match the one we actually picked (the eGPU, by
  # PCI bus id) instead of blindly taking the first, which would size models to
  # the wrong card's VRAM.
  if [[ "$HW_VENDOR" == "nvidia" ]] && have nvidia-smi; then
    local mib="" want; want="$(gpu_pci_addr)"; want="${want#0000:}"   # e.g. 31:00.0
    if [[ -n "$want" ]]; then
      mib="$(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null \
             | awk -v w="${want^^}" 'index(toupper($0), w) {print $NF; exit}' | tr -dc '0-9')"
    fi
    # Fall back to the first GPU when the bus id could not be matched.
    [[ -z "$mib" ]] && mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')"
    [[ -n "$mib" ]] && HW_VRAM_GB="$(( (mib + 512) / 1024 ))"
  fi

  # How is the GPU attached — Thunderbolt-tunnelled or a direct PCIe link
  # (OcuLink / slot)? Best-effort; only meaningful once a GPU is on the bus.
  if [[ "$HW_VENDOR" == "nvidia" || "$HW_VENDOR" == "amd" ]]; then
    HW_LINK="$(gpu_link_kind "$(gpu_pci_addr)")"
  fi

  HW_CPU="$cpu"
  HW_RAM_GB="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')"

  cfg_set HW_VENDOR  "$HW_VENDOR"
  cfg_set HW_MODEL   "$HW_MODEL"
  cfg_set HW_GFX     "$HW_GFX"
  cfg_set HW_SM      "$HW_SM"
  cfg_set HW_VRAM_GB "$HW_VRAM_GB"
  cfg_set HW_LINK    "$HW_LINK"
  cfg_set HW_CPU     "$HW_CPU"
  cfg_set HW_RAM_GB  "$HW_RAM_GB"
  log_debug "Detected vendor=$HW_VENDOR model=$HW_MODEL gfx=$HW_GFX sm=$HW_SM vram=$HW_VRAM_GB link=$HW_LINK"
  return 0
}

# gpu_budget_gb — usable VRAM budget for model sizing.
gpu_budget_gb() {
  case "$(cfg_get HW_VENDOR)" in
    nvidia) cfg_get HW_VRAM_GB 32; echo ;;
    amd)    # Strix Halo unified memory: prefer a configured UMA/GTT split,
            # else assume ~half of system RAM is GPU-usable.
            local uma; uma="$(cfg_get AMD_UMA_GB)"
            if [[ -n "$uma" ]]; then echo "$uma"
            else echo "$(( $(cfg_get HW_RAM_GB 32) / 2 ))"; fi ;;
    *)      echo 0 ;;
  esac
}
