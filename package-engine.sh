#!/usr/bin/env bash
# package-engine.sh — build the buun-llama-cpp engine PORTABLE and tar it for
# reuse on other machines via `deploy.sh --engine <tarball>`. Upload the tarball
# to a GitHub Release (or scp it) — do NOT commit it into git (it is ~0.5 GB and
# goes stale every rebuild).
#
# "Portable" = runtime CPU dispatch (no -march=native), so the binary runs on any
# x86-64-v2+ CPU instead of only the build host's microarch — this is what avoids
# the SIGILL crash a naively-copied `-march=native` build would cause elsewhere.
# The GPU arch is still fixed (sm_120 by default): the target must share it.
#
# Usage: ./package-engine.sh [--sm 120] [--dir ~/buun-llama-cpp] [--out .]
# Run as your normal user (needs the CUDA toolkit, i.e. nvcc, already installed —
# `sudo ./setup.sh drivers` provides it).
set -euo pipefail

REPO_URL="https://github.com/spiritbuun/buun-llama-cpp"
SM=120; DIR="$HOME/buun-llama-cpp"; OUT="$PWD"
while (( $# )); do
  case "$1" in
    --sm)   SM="${2:?}"; shift 2 ;;   --sm=*)  SM="${1#*=}"; shift ;;
    --dir)  DIR="${2:?}"; shift 2 ;;  --dir=*) DIR="${1#*=}"; shift ;;
    --out)  OUT="${2:?}"; shift 2 ;;  --out=*) OUT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//;s/^set -.*//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

command -v nvcc >/dev/null || { export PATH=/usr/local/cuda/bin:$PATH; }
command -v nvcc >/dev/null || { echo "nvcc not found — run 'sudo ./setup.sh drivers' first." >&2; exit 1; }

echo "▶ Checkout: $DIR"
if [[ -d "$DIR/.git" ]]; then git -C "$DIR" pull --ff-only || echo "  (pull failed; building current checkout)"; else git clone "$REPO_URL" "$DIR"; fi
COMMIT="$(git -C "$DIR" rev-parse --short HEAD)"

echo "▶ Configure (portable CPU dispatch, sm_${SM})…"
rm -rf "$DIR/build"
cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
  -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON -DGGML_BACKEND_DL=ON \
  -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$SM" -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_CUDA_COMPILER="$(command -v nvcc)"

echo "▶ Build ($(nproc) jobs)…"
cmake --build "$DIR/build" --config Release -j "$(nproc)"

"$DIR/build/bin/llama-server" --version >/dev/null || { echo "built binary won't run here" >&2; exit 1; }

TARBALL="$OUT/buun-engine-sm${SM}-${COMMIT}.tar.zst"
echo "▶ Packaging build/ → $TARBALL"
if command -v zstd >/dev/null; then
  tar --zstd -cf "$TARBALL" -C "$DIR" build
else
  TARBALL="${TARBALL%.zst}.gz"; tar -czf "$TARBALL" -C "$DIR" build
fi
echo "✓ $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo "  Upload to a GitHub Release, then on the target:"
echo "    sudo ./deploy.sh <profile> --engine <url-or-path-to-this-tarball>"
