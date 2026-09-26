# shellcheck shell=bash
# modules/30-amd-vram.sh — set the AMD Strix Halo unified-memory / GTT budget
# that the GPU may borrow from system RAM. Applied via GRUB cmdline + a
# modprobe.d drop-in; requires a reboot.
#
# We CANNOT change the firmware UMA carve-out (a BIOS setting) from Linux — this
# raises the GTT ceiling so llama.cpp/Vulkan can allocate large models.
# shellcheck source=/dev/null

_PAGES_PER_GIB=262144   # 1 GiB / 4096-byte page

_vram_pick_gib() {
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then
    [[ "$arg" =~ ^[0-9]+$ ]] || die "vram: expected an integer number of GiB (got '$arg')."
    echo "$arg"; return 0
  fi
  local ram cap; ram="$(cfg_get HW_RAM_GB 0)"
  cap=$(( ram > 8 ? ram - 8 : ram ))
  local -a opts=()
  local p
  for p in 16 24 32 48 64 96 112; do (( p <= cap )) && opts+=( "$p" "${p} GiB" ); done
  (( ${#opts[@]} )) || opts=( "$cap" "${cap} GiB (max)" )
  ui_menu "AMD unified-memory budget" \
    "System RAM: ${ram} GiB. Choose how much the GPU may use (leaving ≥8 GiB for the host):" \
    "${opts[@]}"
}

_vram_apply_grub() {
  local params="$1" grub=/etc/default/grub
  if [[ ! -f "$grub" ]]; then
    log_warn "No ${grub} (systemd-boot?). Writing modprobe drop-in only; set kernel args manually."
    return 1
  fi
  backup_file "$grub"
  local cur val tok cleaned="" new content
  cur="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub" | head -1)"
  val="${cur#GRUB_CMDLINE_LINUX_DEFAULT=}"; val="${val%\"}"; val="${val#\"}"
  for tok in $val; do
    case "$tok" in
      amdgpu.gttsize=*|amdgpu.vramlimit=*|ttm.pages_limit=*|ttm.page_pool_size=*|amdttm.*) continue ;;
      *) cleaned+="${cleaned:+ }$tok" ;;
    esac
  done
  new="GRUB_CMDLINE_LINUX_DEFAULT=\"${cleaned:+$cleaned }${params}\""
  content="$(awk -v repl="$new" '
    /^GRUB_CMDLINE_LINUX_DEFAULT=/ {print repl; found=1; next}
    {print}
    END {if (!found) print repl}' "$grub")"
  show_diff "$grub" <<<"$content" || true
  printf '%s\n' "$content" | atomic_write "$grub"
  run update-grub
  return 0
}

_vram_apply_modprobe() {
  local pages="$1" f=/etc/modprobe.d/amdgpu-uma.conf
  # In-kernel module is 'ttm'; AMD's DKMS variant is 'amdttm' — cover both.
  local content
  content="$(printf '# Added by setup-ubuntu-ai — AMD unified-memory (GTT) budget\noptions ttm pages_limit=%s page_pool_size=%s\noptions amdttm pages_limit=%s page_pool_size=%s\n' "$pages" "$pages" "$pages" "$pages")"
  backup_file "$f"
  show_diff "$f" <<<"$content" || true
  printf '%s' "$content" | atomic_write "$f"
  run update-initramfs -u
}

module_main() {
  log_step "AMD GPU VRAM / unified-memory split"
  if [[ "$(cfg_get HW_VENDOR)" != "amd" ]]; then
    log_warn "This action applies to AMD APUs (Strix Halo). Detected vendor: $(cfg_get HW_VENDOR)."
    ui_yesno "Continue anyway?" || return 0
  fi

  local gib; gib="$(_vram_pick_gib "${1:-}")" || { log_info "Cancelled."; return 0; }
  [[ -n "$gib" ]] || { log_info "Cancelled."; return 0; }
  local pages=$(( gib * _PAGES_PER_GIB ))
  local mib=$(( gib * 1024 ))

  narrate "Allowing the GPU to borrow up to ${gib} GiB of system RAM (${pages} pages of 4 KiB)."
  local params="amdgpu.gttsize=${mib} ttm.pages_limit=${pages} ttm.page_pool_size=${pages}"

  _vram_apply_grub "$params" || true
  _vram_apply_modprobe "$pages"

  cfg_set AMD_UMA_GB "$gib"; cfg_set AMD_VRAM_APPLIED 1; cfg_save
  log_ok "Unified-memory budget set to ${gib} GiB (effective after reboot)."
  offer_reboot "apply the ${gib} GiB GPU memory budget" "build"
}

module_uninstall() {
  log_step "Reverting AMD VRAM split"
  run rm -f /etc/modprobe.d/amdgpu-uma.conf
  if [[ -f /etc/default/grub ]]; then
    backup_file /etc/default/grub
    local content
    content="$(sed -E 's/ ?(amdgpu\.gttsize|amdgpu\.vramlimit|ttm\.pages_limit|ttm\.page_pool_size)=[0-9]+//g' /etc/default/grub)"
    printf '%s\n' "$content" | atomic_write /etc/default/grub
    run update-grub
  fi
  run update-initramfs -u || true
  cfg_del AMD_UMA_GB; cfg_del AMD_VRAM_APPLIED; cfg_save
  log_ok "Reverted (reboot to take effect)."
}
