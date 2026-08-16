#!/usr/bin/env bash
# deploy.sh — one command to install a full setup-ubuntu-ai profile on a fresh
# machine. It places the chosen config profile (re-homed to this machine's user),
# sets/creates the API key, optionally drops a PREBUILT engine to skip the long
# source build, then runs `setup.sh restore` to do everything A→Z, unattended:
# drivers + CUDA → build (or reuse prebuilt) → model download → configure → service.
#
# Usage:
#   sudo ./deploy.sh <profile> [--key KEY] [--engine SRC]
#
#   <profile>    profile name or path — "qwen3.8-27b-turbo" resolves to
#                config.qwen3.8-27b-turbo.conf (a full path also works).
#   --key KEY    API key to write into the config. If omitted: keep the profile's
#                value, or generate a random one when it is REPLACE_WITH_YOUR_API_KEY.
#   --engine SRC Reuse a PREBUILT engine instead of a ~40-min source build. SRC is
#                a tarball of the build/ tree (.tar.zst/.tar.gz), a local
#                buun-llama-cpp checkout, a host:path for rsync, or an http(s) URL.
#                SAFE ONLY on a CPU- and GPU-arch-compatible target (same x86
#                instruction set + same CUDA sm_*). If the binary will not run
#                here, `restore` auto-falls-back to a clean source build — a
#                mismatched prebuilt can never silently poison the service.
#
# Examples:
#   sudo ./deploy.sh qwen3.8-27b-turbo --key MYKEY
#   sudo ./deploy.sh qwen3.8-27b-turbo --engine otherbox:~/buun-llama-cpp   # twin
#   sudo ./deploy.sh qwen3.8-27b-turbo --engine engine-sm120.tar.zst
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo -- "$0" "$@"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_DST=/etc/setup-ubuntu-ai/config.conf

die()  { echo "deploy: $*" >&2; exit 1; }
info() { echo "▶ $*"; }

PROFILE=""; KEY=""; ENGINE=""
while (( $# )); do
  case "$1" in
    --key)      KEY="${2:?--key needs a value}"; shift 2 ;;
    --key=*)    KEY="${1#*=}"; shift ;;
    --engine)   ENGINE="${2:?--engine needs a value}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    -h|--help)  sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//;s/^set -.*//'; exit 0 ;;
    -*)         die "unknown flag: $1 (try --help)" ;;
    *)          if [[ -z "$PROFILE" ]]; then PROFILE="$1"; else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[[ -n "$PROFILE" ]] || die "usage: sudo ./deploy.sh <profile> [--key KEY] [--engine SRC]"

# Resolve the profile file (name → config.<name>.conf, or an explicit path).
SRC_CONF=""
for c in "$PROFILE" "$REPO_ROOT/$PROFILE" "$REPO_ROOT/config.${PROFILE}.conf"; do
  [[ -f "$c" ]] && { SRC_CONF="$c"; break; }
done
[[ -n "$SRC_CONF" ]] || die "profile not found: '$PROFILE' (looked for config.${PROFILE}.conf)"
info "Profile: $SRC_CONF"

# The human behind sudo — used to re-home hard-coded paths and own the files.
TGT_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
TGT_HOME="$(getent passwd "$TGT_USER" | cut -d: -f6)"; TGT_HOME="${TGT_HOME:-/root}"
info "Target user: $TGT_USER   home: $TGT_HOME"

# Place the config: re-home any /home/<x> or /root path prefix to THIS machine.
install -d -m 755 "$(dirname "$CONF_DST")"
tmp="$(mktemp)"
sed -E "s#(/home/[^/\" ]+|/root)#${TGT_HOME}#g" "$SRC_CONF" > "$tmp"

# API key: explicit --key wins; else generate one if the profile still has the
# placeholder (a set key in the profile is left as-is).
if [[ -n "$KEY" ]]; then
  esc="$(printf '%s' "$KEY" | sed -e 's/[&#\\]/\\&/g')"
  sed -i "s#REPLACE_WITH_YOUR_API_KEY#${esc}#g" "$tmp"
elif grep -q REPLACE_WITH_YOUR_API_KEY "$tmp"; then
  KEY="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 44)"
  sed -i "s#REPLACE_WITH_YOUR_API_KEY#${KEY}#g" "$tmp"
  info "Generated API key: ${KEY}"
fi
install -m 640 "$tmp" "$CONF_DST"; rm -f "$tmp"
info "Wrote ${CONF_DST}"

# Optional prebuilt engine → staged into LLAMACPP_DIR; build step reuses it.
if [[ -n "$ENGINE" ]]; then
  LC_DIR="$(sed -nE 's/^LLAMACPP_DIR="?([^"]+)"?.*/\1/p' "$CONF_DST" | head -1)"
  [[ -n "$LC_DIR" ]] || die "config has no LLAMACPP_DIR to stage the engine into"
  info "Staging prebuilt engine into ${LC_DIR} from: ${ENGINE}"
  install -d -m 755 "$LC_DIR"
  case "$ENGINE" in
    *.tar.zst)          tar --zstd -xf "$ENGINE" -C "$LC_DIR" ;;
    *.tar.gz|*.tgz)     tar -xzf "$ENGINE" -C "$LC_DIR" ;;
    *.tar)              tar -xf "$ENGINE" -C "$LC_DIR" ;;
    http://*|https://*) command -v curl >/dev/null || { apt-get update -qq; apt-get install -y curl; }
                        curl -fSL "$ENGINE" -o "${tmp2:=$(mktemp --suffix=.tar)}"
                        { tar --zstd -xf "$tmp2" -C "$LC_DIR" 2>/dev/null \
                          || tar -xzf "$tmp2" -C "$LC_DIR" 2>/dev/null \
                          || tar -xf "$tmp2" -C "$LC_DIR"; }; rm -f "$tmp2" ;;
    *:*)                command -v rsync >/dev/null || { apt-get update -qq; apt-get install -y rsync; }
                        rsync -a --info=progress2 "${ENGINE%/}/" "$LC_DIR/" ;;
    *)                  [[ -d "$ENGINE" ]] || die "engine source not found: $ENGINE"
                        command -v rsync >/dev/null || { apt-get update -qq; apt-get install -y rsync; }
                        rsync -a "${ENGINE%/}/" "$LC_DIR/" ;;
  esac
  chown -R "$TGT_USER":"$TGT_USER" "$LC_DIR"
  if grep -q '^LLAMACPP_PREBUILT=' "$CONF_DST"; then
    sed -i 's/^LLAMACPP_PREBUILT=.*/LLAMACPP_PREBUILT="1"/' "$CONF_DST"
  else
    echo 'LLAMACPP_PREBUILT="1"' >> "$CONF_DST"
  fi
  info "Engine staged. The build step will reuse it if the binary runs on this CPU."
fi

# Everything else — drivers, (build|reuse), model, configure, service — A→Z.
info "Running: setup.sh restore  (unattended, may take a while)…"
"$REPO_ROOT/setup.sh" restore

echo
info "Done."
info "Manage:  systemctl status llama-server   ·   journalctl -u llama-server -f"
[[ -n "$KEY" ]] && info "API key: ${KEY}"
