# shellcheck shell=bash
# modules/00-preflight.sh — gatekeeper checks + bootstrap of the few tools the
# suite itself needs (whiptail, pciutils, curl, gnupg).
# shellcheck source=/dev/null

module_main() {
  log_step "Preflight checks"

  # The one UI dependency — install whiptail so the menus work.
  if [[ -z "${NO_UI:-}" ]] && ! have whiptail; then
    narrate "Installing whiptail (drives the interactive arrow-key menus)."
    apt_install whiptail || log_warn "Could not install whiptail; using text menus."
  fi

  # Tools every later step relies on.
  local boot=()
  have lspci || boot+=(pciutils)
  have curl  || boot+=(curl)
  have gpg   || boot+=(gnupg)
  have git   || boot+=(git)
  # Thunderbolt/USB4 box? 'bolt' (boltctl) is needed to authorize a TB-attached
  # eGPU dock so its tunnelled PCIe GPU shows up. OcuLink/slot links need nothing.
  if _tb_domains_present && ! have boltctl; then
    narrate "Thunderbolt fabric detected — installing 'bolt' to authorize the eGPU dock."
    boot+=(bolt)
  fi
  if (( ${#boot[@]} )); then
    narrate "Installing base tools: ${boot[*]}"
    apt_install "${boot[@]}"
  else
    log_ok "Base tools present (lspci, curl, gpg, git)."
  fi

  # Network reachability (needed for driver repos + model downloads).
  if curl -fsS --max-time 8 https://huggingface.co >/dev/null 2>&1; then
    log_ok "Network reachable (huggingface.co)."
  else
    log_warn "Cannot reach huggingface.co — driver repos / model downloads may fail."
  fi

  # Disk headroom.
  local free; free="$(free_gib /)"; free="${free:-0}"
  if (( free < 20 )); then
    log_warn "Only ${free} GiB free on / — llama.cpp builds and GGUF models need space."
  else
    log_ok "Disk headroom on /: ${free} GiB free."
  fi

  # Privilege.
  if (( EUID == 0 )); then log_ok "Running as root."; else log_warn "Not root — some steps will re-invoke sudo."; fi

  log_ok "Preflight complete."
}
