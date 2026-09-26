#!/usr/bin/env bash
# deploy.sh — one command to install a setup-ubuntu-ai profile on a machine.
# It places the chosen profile as /etc/setup-ubuntu-ai/config.conf (absolute
# paths re-homed to this machine's user), sets the API key, optionally stages a
# PREBUILT engine to skip the source build, then runs `setup.sh restore` to do
# everything A→Z, unattended: drivers + CUDA → engine → model (+ vision) →
# configure → service.
#
# Usage:
#   sudo ./deploy.sh <profile> [--key KEY] [--engine SRC]
#
#   <profile>    profile name or path — "bonsai2-27b" resolves to
#                config.bonsai2-27b.conf (a full path also works).
#   --key KEY    API key clients must send (Authorization: Bearer KEY). Without
#                it, the key of the currently installed config is kept — a
#                redeploy never locks existing clients out. On a fresh machine
#                a random key is generated and printed once.
#   --engine SRC Reuse a PREBUILT engine instead of a source build. SRC is a
#                tarball of the build/ tree (.tar.zst/.tar.gz, see
#                package-engine.sh), a checkout with a build/ (local path or
#                host:path for rsync), or an http(s) URL of a tarball. Safe only
#                on a CPU- and GPU-arch-compatible target: if the binary does
#                not run here, `restore` builds from source instead.
#
# Examples:
#   sudo ./deploy.sh bonsai2-27b
#   sudo ./deploy.sh bonsai2-27b --key MYKEY
#   sudo ./deploy.sh bonsai2-27b --engine otherbox:~/llama
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_DST=/etc/setup-ubuntu-ai/config.conf
PLACEHOLDER=REPLACE_WITH_YOUR_API_KEY
ARGS=("$@")

die()  { echo "deploy: $*" >&2; exit 1; }
info() { echo "▶ $*"; }
usage() { sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//;s/^set -.*//'; }

PROFILE=""; KEY=""; ENGINE=""
while (( $# )); do
  case "$1" in
    --key)      KEY="${2:?--key needs a value}"; shift 2 ;;
    --key=*)    KEY="${1#*=}"; shift ;;
    --engine)   ENGINE="${2:?--engine needs a value}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown flag: $1 (try --help)" ;;
    *)          if [[ -z "$PROFILE" ]]; then PROFILE="$1"; else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[[ -n "$PROFILE" ]] || die "usage: sudo ./deploy.sh <profile> [--key KEY] [--engine SRC]"
[[ $EUID -eq 0 ]] || exec sudo -- "$0" "${ARGS[@]}"

# conf_value FILE KEY — the value of KEY="…" in a config file (last one wins).
conf_value() { sed -nE "s/^$2=\"?([^\"]*)\"?\$/\1/p" "$1" 2>/dev/null | tail -1; }

# set_conf_value FILE KEY VALUE — replace KEY's line, or append it. The value
# travels via the environment, so any character is safe (no sed escaping).
set_conf_value() {
  K="$2" V="$3" awk '
    index($0, ENVIRON["K"] "=") == 1 { if (!done) print ENVIRON["K"] "=\"" ENVIRON["V"] "\""; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["K"] "=\"" ENVIRON["V"] "\"" }' "$1" >"$1.new" && mv "$1.new" "$1"
}

# installed_key — the API key of the config currently in place, if any.
# Configs from before LLAMA_API_KEY existed carried it inline in the args.
installed_key() {
  [[ -f "$CONF_DST" ]] || return 0
  local k; k="$(conf_value "$CONF_DST" LLAMA_API_KEY)"
  [[ -n "$k" ]] || k="$(conf_value "$CONF_DST" LLAMA_EXTRA_ARGS | sed -nE 's/(^|.* )--api-key ([^ ]+).*/\2/p')"
  [[ "$k" == "$PLACEHOLDER" ]] || printf '%s' "$k"
}

# Resolve the profile file (name → config.<name>.conf, or an explicit path).
SRC_CONF=""
for c in "$PROFILE" "$REPO_ROOT/$PROFILE" "$REPO_ROOT/config.${PROFILE}.conf"; do
  [[ -f "$c" ]] && { SRC_CONF="$c"; break; }
done
[[ -n "$SRC_CONF" ]] || die "profile not found: '$PROFILE' (looked for config.${PROFILE}.conf)"
info "Profile: $SRC_CONF"

# The human behind sudo — used to re-home absolute paths and own the files.
TGT_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
TGT_HOME="$(getent passwd "$TGT_USER" | cut -d: -f6)"; TGT_HOME="${TGT_HOME:-/root}"
info "Target user: $TGT_USER   home: $TGT_HOME"

# Build the config: re-home any /home/<x> or /root path prefix to THIS machine.
tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.new"' EXIT
sed -E "s#(/home/[^/\" ]+|/root)#${TGT_HOME}#g" "$SRC_CONF" >"$tmp"

# API key: --key wins; else keep the installed one; else the profile's own
# (unless it is the placeholder); else generate one. Profiles that still carry
# the key inline in LLAMA_EXTRA_ARGS get it moved to LLAMA_API_KEY.
KEY_ORIGIN="given with --key"
if [[ -z "$KEY" ]]; then KEY="$(installed_key)"; KEY_ORIGIN="kept from the installed config"; fi
if [[ -z "$KEY" ]]; then
  KEY="$(conf_value "$tmp" LLAMA_API_KEY)"; KEY_ORIGIN="from the profile"
  [[ "$KEY" == "$PLACEHOLDER" ]] && KEY=""
fi
if [[ -z "$KEY" ]]; then
  KEY="$(head -c 33 /dev/urandom | base64 | tr '+/' '-_')"; KEY_ORIGIN="generated"
fi
[[ "$KEY" =~ ^[^[:space:]\"]+$ ]] || die "the API key must not contain whitespace or quotes"
set_conf_value "$tmp" LLAMA_API_KEY "$KEY"
extra="$(conf_value "$tmp" LLAMA_EXTRA_ARGS)"
if [[ " $extra " == *" --api-key "* ]]; then
  set_conf_value "$tmp" LLAMA_EXTRA_ARGS "$(sed -E 's/(^| )--api-key [^ ]+//' <<<"$extra")"
fi
info "API key: ${KEY_ORIGIN}"

install -d -m 755 "$(dirname "$CONF_DST")"
if [[ -f "$CONF_DST" ]]; then
  bak="${CONF_DST}.bak.$(date +%Y%m%d-%H%M%S)"
  install -m 600 "$CONF_DST" "$bak" && info "Backed up the previous config → ${bak}"
fi
install -m 600 "$tmp" "$CONF_DST"
info "Wrote ${CONF_DST}"

# Optional prebuilt engine → staged as <engine dir>/build; the build step
# reuses it when the binary runs here.
if [[ -n "$ENGINE" ]]; then
  LC_DIR="$(conf_value "$CONF_DST" LLAMACPP_DIR)"; LC_DIR="${LC_DIR:-$TGT_HOME/llama}"
  info "Staging prebuilt engine into ${LC_DIR}/build from: ${ENGINE}"
  install -d -m 755 "$LC_DIR"
  rm -rf "$LC_DIR/build"
  case "$ENGINE" in
    *.tar.zst)          tar --zstd -xf "$ENGINE" -C "$LC_DIR" ;;
    *.tar.gz|*.tgz)     tar -xzf "$ENGINE" -C "$LC_DIR" ;;
    *.tar)              tar -xf "$ENGINE" -C "$LC_DIR" ;;
    http://*|https://*) command -v curl >/dev/null || { apt-get update -qq; apt-get install -y curl; }
                        dl="$(mktemp --suffix=.tar)"
                        curl -fSL "$ENGINE" -o "$dl"
                        { tar --zstd -xf "$dl" -C "$LC_DIR" 2>/dev/null \
                          || tar -xzf "$dl" -C "$LC_DIR" 2>/dev/null \
                          || tar -xf "$dl" -C "$LC_DIR"; }; rm -f "$dl" ;;
    *:*)                command -v rsync >/dev/null || { apt-get update -qq; apt-get install -y rsync; }
                        rsync -a --info=progress2 "${ENGINE%/}/build/" "$LC_DIR/build/" ;;
    *)                  [[ -d "$ENGINE/build" ]] || die "engine source not found: $ENGINE/build"
                        command -v rsync >/dev/null || { apt-get update -qq; apt-get install -y rsync; }
                        rsync -a "${ENGINE%/}/build/" "$LC_DIR/build/" ;;
  esac
  [[ -x "$LC_DIR/build/bin/llama-server" ]] || die "no build/bin/llama-server in ${ENGINE}"
  chown -R "$TGT_USER":"$TGT_USER" "$LC_DIR"
  set_conf_value "$CONF_DST" LLAMACPP_PREBUILT 1
  info "Engine staged. The build step reuses it if the binary runs on this machine."
fi

# Everything else — drivers, engine, model, configure, service — A→Z.
info "Running: setup.sh restore  (unattended, may take a while)…"
"$REPO_ROOT/setup.sh" restore

echo
info "Done."
info "Manage:  systemctl status llama-server   ·   journalctl -u llama-server -f"
if [[ "$KEY_ORIGIN" == generated ]]; then
  info "Generated API key (clients send it as 'Authorization: Bearer <key>'): ${KEY}"
fi
