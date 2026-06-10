# shellcheck shell=bash
# lib/version.sh — dotted-version comparison helpers.
[[ -n "${_VERSION_SH_LOADED:-}" ]] && return 0
_VERSION_SH_LOADED=1

# ver_ge A B  -> success if A >= B   (numeric, dot-separated; extra parts = 0)
ver_ge() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  local hi
  hi="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
  [[ "$hi" == "$a" ]]
}

# ver_lt A B  -> success if A < B
ver_lt() { ! ver_ge "$1" "$2"; }
