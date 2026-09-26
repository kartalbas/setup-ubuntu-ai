#!/usr/bin/env bash
# package-engine.sh — build the llama.cpp engine PORTABLE and tar it for reuse on other
# machines via `deploy.sh --engine <tarball>`. Upload the tarball to a GitHub
# Release (or scp it) — never commit it (it is large and goes stale).
#
# Portable = runtime CPU dispatch (no -march=native), so it runs on any
# x86-64-v2+ CPU; relocatable = an $ORIGIN RPATH, so it runs from any path.
# The GPU arch is still fixed (sm_120 by default): the target must share it.
# The build uses its own tree (build-portable/) — never the live build/.
#
# Usage: ./package-engine.sh [--sm 120] [--dir ~/llama] [--ref REV] [--out .]
#   --ref  commit/tag/branch to package (default: what the checkout has now)
# Run as your normal user; needs the CUDA toolkit (`sudo ./setup.sh drivers`)
# and a checkout (`sudo ./setup.sh build` creates one).
set -euo pipefail

SM=120; DIR="$HOME/llama"; REF=""; OUT="$PWD"
while (( $# )); do
  case "$1" in
    --sm)   SM="${2:?}"; shift 2 ;;   --sm=*)  SM="${1#*=}"; shift ;;
    --dir)  DIR="${2:?}"; shift 2 ;;  --dir=*) DIR="${1#*=}"; shift ;;
    --ref)  REF="${2:?}"; shift 2 ;;  --ref=*) REF="${1#*=}"; shift ;;
    --out)  OUT="${2:?}"; shift 2 ;;  --out=*) OUT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//;s/^set -.*//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

NVCC="$(command -v nvcc || true)"; NVCC="${NVCC:-/usr/local/cuda/bin/nvcc}"
[[ -x "$NVCC" ]] || { echo "nvcc not found — run 'sudo ./setup.sh drivers' first." >&2; exit 1; }
[[ -d "$DIR/.git" ]] || { echo "no checkout at $DIR — run 'sudo ./setup.sh build' first." >&2; exit 1; }
if [[ -n "$REF" ]]; then
  git -C "$DIR" fetch --tags origin
  git -C "$DIR" -c advice.detachedHead=false checkout --detach "$REF"
fi
COMMIT="$(git -C "$DIR" rev-parse --short HEAD)"
BUILD="$DIR/build-portable"

echo "▶ Configure ${COMMIT} (portable CPU dispatch, sm_${SM})…"
rm -rf "$BUILD"
cmake -S "$DIR" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_UI=ON -DLLAMA_USE_PREBUILT_UI=ON -DLLAMA_UI_GZIP=OFF -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
  -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON -DGGML_BACKEND_DL=ON \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$SM" -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_CUDA_COMPILER="$NVCC"

echo "▶ Build ($(nproc) jobs)…"
cmake --build "$BUILD" --config Release -j "$(nproc)"
"$BUILD/bin/llama-server" --version >/dev/null || { echo "built binary won't run here" >&2; exit 1; }

# Ship only the binaries + libraries, stored as build/bin/ — what the target's
# build step expects.
TARBALL="$OUT/${DIR##*/}-sm${SM}-${COMMIT}.tar.zst"
echo "▶ Packaging ${BUILD}/bin → $TARBALL"
if command -v zstd >/dev/null; then
  tar --zstd -cf "$TARBALL" -C "$DIR" --transform 's,^build-portable/,build/,' build-portable/bin
else
  TARBALL="${TARBALL%.zst}.gz"
  tar -czf "$TARBALL" -C "$DIR" --transform 's,^build-portable/,build/,' build-portable/bin
fi
rm -rf "$BUILD"
echo "✓ $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo "  Upload to a GitHub Release, then on the target:"
echo "    sudo ./deploy.sh <profile> --engine <url-or-path-to-this-tarball>"
