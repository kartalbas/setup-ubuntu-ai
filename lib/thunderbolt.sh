# shellcheck shell=bash
# lib/thunderbolt.sh — bring an external GPU online no matter how it is attached.
#
# An eGPU reaches the PCIe bus one of two ways:
#   • OcuLink / a slot riser — a *direct* PCIe link. The card is on the bus the
#     instant the machine powers on; lspci sees it with zero help from us.
#   • Thunderbolt 4 / USB4    — PCIe is *tunnelled* over the TB fabric. The
#     tunnel (and therefore the GPU's PCI device) only materialises once the
#     `bolt` daemon AUTHORIZES the dock. On a `user`/`secure` security level a
#     never-before-seen dock stays dark and lspci shows nothing at all.
#
# detect_hardware() works off lspci, so on a Thunderbolt box we must authorize
# the dock *before* scanning. ensure_egpu_online() does that, and is a no-op on
# OcuLink — so the rest of the installer stays transport-agnostic and picks up
# whichever link is actually present (not just direct PCIe).
[[ -n "${_THUNDERBOLT_SH_LOADED:-}" ]] && return 0
_THUNDERBOLT_SH_LOADED=1

# _tb_domains_present — true if the kernel exposes a Thunderbolt/USB4 fabric.
_tb_domains_present() {
  local d
  for d in /sys/bus/thunderbolt/devices/domain*; do
    [[ -e "$d" ]] && return 0
  done
  return 1
}

# gpu_pci_addr — PCI address (0000:bb:dd.f) of the GPU we care about. Prefers a
# *removable* card (the eGPU on a hotplug port) over a soldered/internal one, so
# the link classification describes the external dock and not a laptop iGPU.
# Empty if no NVIDIA/AMD display device is on the bus yet.
gpu_pci_addr() {
  local first="" bdf rem
  while read -r bdf; do
    [[ -n "$bdf" ]] || continue
    [[ -z "$first" ]] && first="$bdf"
    rem="$(cat "/sys/bus/pci/devices/${bdf}/removable" 2>/dev/null || true)"
    [[ "$rem" == "removable" ]] && { printf '%s' "$bdf"; return 0; }
  done < <(lspci -D -nn 2>/dev/null | grep -E '\[030[02]\]' | grep -iE '\[10de:|\[1002:' | awk '{print $1}')
  printf '%s' "$first"
}

# gpu_link_kind [PCI_ADDR] — classify how the GPU is attached: "thunderbolt"
# (PCIe tunnelled over TB/USB4), "pci" (direct OcuLink/slot link) or "unknown".
# Robust + portable: walk the device's sysfs ancestry and look for a PCIe root
# port that lspci names as Thunderbolt/USB4 — that bridge IS the tunnel.
gpu_link_kind() {
  local addr="${1:-}"
  [[ -n "$addr" ]] || { echo "unknown"; return 0; }
  [[ "$addr" == *:*:* ]] || addr="0000:${addr}"      # accept short BDF too
  local path; path="$(readlink -f "/sys/bus/pci/devices/${addr}" 2>/dev/null || true)"
  [[ -n "$path" ]] || { echo "unknown"; return 0; }

  local lspci_all; lspci_all="$(lspci -nn 2>/dev/null || true)"
  local -a segs; IFS='/' read -ra segs <<<"$path"
  local s bdf
  for s in "${segs[@]}"; do
    # Only consider real PCI bus addresses in the path (0000:00:07.3 …).
    [[ "$s" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] || continue
    bdf="${s#0000:}"                                  # lspci -nn prints short BDF
    if grep -iE "^${bdf} " <<<"$lspci_all" | grep -qiE 'thunderbolt|usb4'; then
      echo "thunderbolt"; return 0
    fi
  done
  echo "pci"
}

# tb_authorize_all — authorize (and persistently enroll) every *connected*
# Thunderbolt/USB4 peripheral so its tunnelled PCIe devices appear on the bus.
# `enroll --policy auto` makes the dock auto-authorize on every future boot, so
# `restore` on a fresh machine only pays this cost once. Best-effort: a failure
# here is warned about, never fatal.
tb_authorize_all() {
  have boltctl || return 0
  local uuids; uuids="$(boltctl list 2>/dev/null | sed -n 's/.*uuid:[[:space:]]*//p')"
  [[ -n "$uuids" ]] || { log_debug "No Thunderbolt peripherals enumerated."; return 0; }

  local uuid status
  while read -r uuid; do
    [[ -n "$uuid" ]] || continue
    status="$(boltctl info "$uuid" 2>/dev/null | sed -n 's/.*status:[[:space:]]*//p' | head -1)"
    case "$status" in
      authorized)
        log_debug "Thunderbolt ${uuid} already authorized." ;;
      connected|authorizing|auth-error*)
        narrate "Authorizing Thunderbolt device ${uuid} so its PCIe tunnel (the eGPU) comes online."
        if run_quiet boltctl enroll --policy auto "$uuid" \
           || run_quiet boltctl authorize "$uuid"; then
          log_ok "Authorized Thunderbolt device ${uuid}."
        else
          log_warn "Could not authorize Thunderbolt device ${uuid} (security policy / no DMA protection?)."
        fi ;;
      *)
        log_debug "Thunderbolt ${uuid} status='${status:-?}' — leaving alone." ;;
    esac
  done <<<"$uuids"
  return 0
}

# _tb_wait_for_gpu [TIMEOUT_S] — let the kernel enumerate the freshly-tunnelled
# PCIe devices after authorization, nudging a bus rescan if native hotplug is
# slow. Returns 0 as soon as a GPU is visible.
_tb_wait_for_gpu() {
  local timeout="${1:-12}" waited=0
  have udevadm && run_quiet udevadm settle --timeout=5 || true
  while (( waited < timeout )); do
    [[ -n "$(gpu_pci_addr)" ]] && return 0
    sleep 1; waited=$((waited+1))
    if (( waited == 3 )) && [[ "${DRY_RUN:-0}" != "1" && -w /sys/bus/pci/rescan ]]; then
      log_debug "No GPU yet — nudging a PCI bus rescan."
      echo 1 >/sys/bus/pci/rescan 2>/dev/null || true
    fi
  done
  return 1
}

# ensure_egpu_online — make sure the external GPU is on the bus regardless of
# transport, so the lspci-based detection that follows actually sees it. No-op
# on OcuLink/slot links (already on the bus); authorizes the dock on TB/USB4.
# Honours TB_AUTHORIZE (auto|no). Always returns 0 — detection handles a still-
# missing GPU on its own.
ensure_egpu_online() {
  if ! _tb_domains_present; then
    log_debug "No Thunderbolt fabric — direct PCIe link (OcuLink/slot); nothing to authorize."
    return 0
  fi

  local mode; mode="$(cfg_get TB_AUTHORIZE auto)"
  if [[ "${mode,,}" == "no" || "$mode" == "0" || "${mode,,}" == "false" ]]; then
    log_warn "TB_AUTHORIZE=${mode} — skipping Thunderbolt authorization; a TB-attached eGPU may stay invisible."
    return 0
  fi

  if ! have boltctl; then
    log_warn "Thunderbolt fabric present but 'boltctl' is missing — install the 'bolt' package so a TB eGPU dock can be authorized."
    return 0
  fi

  narrate "Thunderbolt/USB4 fabric detected — making sure the eGPU dock is authorized before scanning."
  tb_authorize_all
  if [[ -n "$(gpu_pci_addr)" ]]; then
    log_ok "GPU visible on the bus (Thunderbolt link authorized)."
  elif _tb_wait_for_gpu 12; then
    log_ok "GPU appeared after authorizing the Thunderbolt dock."
  else
    log_warn "No GPU on the bus yet after authorizing Thunderbolt — check the dock is powered and the cable seated."
  fi
  return 0
}
