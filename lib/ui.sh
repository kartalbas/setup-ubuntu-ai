# shellcheck shell=bash
# lib/ui.sh — interactive prompts. Uses whiptail (arrows/Enter/Esc/numbers)
# when available, otherwise a plain-bash fallback. Whiptail is used ONLY for
# choosing things — never to hide running work (that streams live).
#
# All selection values are returned on stdout; a non-zero exit means the user
# cancelled / pressed Esc, which callers treat as "go back".
[[ -n "${_UI_SH_LOADED:-}" ]] && return 0
_UI_SH_LOADED=1

_use_whiptail() { [[ -z "${NO_UI:-}" ]] && have whiptail; }

# ui_menu TITLE TEXT  TAG1 ITEM1 [TAG2 ITEM2 ...]  -> prints chosen TAG
ui_menu() {
  local title="$1" text="$2"; shift 2
  if _use_whiptail; then
    whiptail --title "$title" --notags --menu "$text" 24 86 14 "$@" 3>&1 1>&2 2>&3
    return $?
  fi
  # ---- fallback ----
  printf '\n%s== %s ==%s\n%s\n' "$C_BOLD" "$title" "$C_RST" "$text" >&2
  local -a tags=() labels=()
  while (( $# )); do tags+=("$1"); labels+=("$2"); shift 2; done
  local i
  for i in "${!tags[@]}"; do printf '  %2d) %s\n' $((i+1)) "${labels[i]}" >&2; done
  local reply
  read -rp "Select a number (Enter to cancel): " reply >&2 || return 1
  [[ -z "$reply" ]] && return 1
  if ! [[ "$reply" =~ ^[0-9]+$ ]] || (( reply<1 || reply>${#tags[@]} )); then
    log_warn "Invalid choice"; return 1
  fi
  printf '%s' "${tags[reply-1]}"
}

# ui_menu_tagged TITLE TEXT  TAG1 ITEM1 [TAG2 ITEM2 ...]  -> prints chosen TAG
# Like ui_menu, but KEEPS the tag column visible. whiptail draws the tag and
# item as two auto-aligned columns, so numeric/lettered tags (1, 2, … G, Q)
# produce a tidy, ordered, left-aligned menu. Use this for the main menu.
ui_menu_tagged() {
  local title="$1" text="$2"; shift 2
  if _use_whiptail; then
    # Size the list to the item count (cap so it always fits an 80x24 terminal).
    local n=$(( $# / 2 )); local lh=$(( n > 16 ? 16 : n ))
    whiptail --title "$title" --menu "$text" 24 76 "$lh" "$@" 3>&1 1>&2 2>&3
    return $?
  fi
  # ---- fallback: "  TAG) label", tag right-padded for alignment ----
  printf '\n%s%s%s\n%s%s%s\n' "$C_BOLD$C_CYAN" "$title" "$C_RST" "$C_DIM" "$text" "$C_RST" >&2
  local -a tags=() labels=()
  while (( $# )); do tags+=("$1"); labels+=("$2"); shift 2; done
  local i
  for i in "${!tags[@]}"; do
    if [[ -z "${labels[i]}" ]]; then printf '\n' >&2; continue; fi   # spacer row
    printf '   %s%3s%s  %s\n' "$C_BOLD" "${tags[i]}" "$C_RST" "${labels[i]}" >&2
  done
  local reply
  read -rp "$(printf '\n%sChoose%s (Enter to cancel): ' "$C_BOLD" "$C_RST")" reply >&2 || return 1
  [[ -z "$reply" ]] && return 1
  printf '%s' "$reply"
}

# ui_yesno TEXT [TITLE]  -> exit 0 = yes, non-zero = no
ui_yesno() {
  local text="$1" title="${2:-Confirm}"
  if [[ -n "${ASSUME_YES:-}" ]]; then log_debug "auto-yes: $text"; return 0; fi
  if _use_whiptail; then
    whiptail --title "$title" --yesno "$text" 14 86
    return $?
  fi
  local reply
  read -rp "$(printf '%s [y/N]: ' "$text")" reply >&2 || return 1
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

# ui_input TEXT DEFAULT [TITLE]  -> prints entered value
ui_input() {
  local text="$1" def="$2" title="${3:-Input}"
  if _use_whiptail; then
    whiptail --title "$title" --inputbox "$text" 12 86 "$def" 3>&1 1>&2 2>&3
    return $?
  fi
  local reply
  read -rp "$(printf '%s [%s]: ' "$text" "$def")" reply >&2 || return 1
  printf '%s' "${reply:-$def}"
}

# ui_password TEXT [TITLE]  -> prints entered secret (no echo)
ui_password() {
  local text="$1" title="${2:-Password}"
  if _use_whiptail; then
    whiptail --title "$title" --passwordbox "$text" 12 86 3>&1 1>&2 2>&3
    return $?
  fi
  local reply
  read -rsp "$(printf '%s: ' "$text")" reply >&2 || return 1
  echo >&2
  printf '%s' "$reply"
}

# ui_msg TEXT [TITLE]  — informational box / message
ui_msg() {
  local text="$1" title="${2:-Notice}"
  if _use_whiptail; then
    whiptail --title "$title" --msgbox "$text" 16 86
  else
    printf '\n%s%s%s\n%s\n' "$C_BOLD" "$title" "$C_RST" "$text" >&2
    [[ -n "${ASSUME_YES:-}" ]] || read -rp "Press Enter to continue… " _ >&2 || true
  fi
}

# ui_pause — wait for the user (skipped under --yes).
ui_pause() {
  [[ -n "${ASSUME_YES:-}" ]] && return 0
  read -rp "$(printf '%sPress Enter to continue…%s ' "$C_DIM" "$C_RST")" _ >&2 || true
}
