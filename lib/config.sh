# shellcheck shell=bash
# lib/config.sh — persisted KEY="value" config, the single source of cross-
# module / cross-reboot state. Shell- and systemd-EnvironmentFile-sourceable.
[[ -n "${_CONFIG_SH_LOADED:-}" ]] && return 0
_CONFIG_SH_LOADED=1

CONFIG_FILE="${CONFIG_FILE:-/etc/setup-ubuntu-ai/config.conf}"
declare -gA CFG=()

# cfg_load — read CONFIG_FILE into the CFG associative array.
cfg_load() {
  CFG=()
  [[ -f "$CONFIG_FILE" ]] || return 0
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k//[[:space:]]/}"
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    v="${v%\"}"; v="${v#\"}"          # strip surrounding quotes
    CFG["$k"]="$v"
  done <"$CONFIG_FILE"
  log_debug "Loaded ${#CFG[@]} config keys from $CONFIG_FILE"
}

cfg_get()  { printf '%s' "${CFG[$1]:-${2-}}"; }
cfg_has()  { [[ -n "${CFG[$1]:-}" ]]; }
cfg_set()  { CFG["$1"]="$2"; }
cfg_del()  { unset 'CFG[$1]'; }

# cfg_save — write CFG back to CONFIG_FILE (sorted, quoted), atomically.
cfg_save() {
  ensure_dir "$(dirname "$CONFIG_FILE")" 0755
  local k
  {
    echo "# Managed by setup-ubuntu-ai — edit with care."
    echo "# Written $(date -Iseconds)"
    for k in $(printf '%s\n' "${!CFG[@]}" | sort); do
      printf '%s="%s"\n' "$k" "${CFG[$k]}"
    done
  } | atomic_write "$CONFIG_FILE"
  log_debug "Saved ${#CFG[@]} config keys to $CONFIG_FILE"
}

# cfg_set_save KEY VALUE — convenience: set one key and persist immediately.
cfg_set_save() { cfg_set "$1" "$2"; cfg_save; }
