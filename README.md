# setup-ubuntu-ai

A modular, **verbose**, user-friendly Bash installer that takes a fresh Ubuntu
machine to a running, auto-starting local LLM server — adapting automatically to
your GPU.

Supported hardware:

| GPU | Backend | Notes |
|-----|---------|-------|
| **NVIDIA RTX 50-series** (Blackwell, `sm_120`) — e.g. RTX 5090 (32 GB), **RTX 5080 (16 GB)** | CUDA | open kernel driver `nvidia-driver-595-open` + CUDA toolkit |
| **AMD Ryzen AI Max+ 395 "Strix Halo"** (Radeon 8060S, `gfx1151`) | **Vulkan only** (no ROCm) | Mesa RADV; settable unified-memory / VRAM split |

It also degrades gracefully for other NVIDIA/AMD GPUs (manual vendor pick; the
CUDA arch is read from the card).

> ⭐ **Highlight — a 27B model with its full 262k context and vision on a 16 GB
> RTX 5080.** [Ternary Bonsai 2 27B](#bonsai-2-27b-on-a-16-gb-rtx-5080) is
> PrismML's ternary (−1/0/+1) version of Qwen3.8-27B: 7.2 GB of weights instead
> of 54 GB, which leaves room for the model's full context (5.5-bit KV cache, as
> good as f16 in our measurements) and the image encoder on the same card —
> ~88 tok/s, one command: `sudo ./deploy.sh bonsai2-27b`.

## Design principles

- **Verbose by default.** Every state-changing command is echoed in full
  (`▶ apt-get install …`) before it runs, real tool output streams live, and
  every file edit is shown as a `diff`. Nothing important happens behind a
  spinner.
- **Step-by-step.** Each phase is its own command — run them one at a time, in
  your own order. A `menu` and a `guided` flow exist too.
- **Idempotent & reversible.** Re-running a step is safe, every step has an
  `uninstall`, and system files are backed up (timestamped `.bak`) before they
  are edited. An engine build is swapped in only once it works, and
  `build --rollback` brings the previous one back.
- **Survives reboots.** The reboots that NVIDIA Secure-Boot/MOK and the AMD VRAM
  change require are handled with a `resume` checkpoint (an unattended
  `restore` resumes unattended); the service starts on every boot.

## Quick start

```bash
git clone <this-repo> setup-ubuntu-ai
cd setup-ubuntu-ai
chmod +x setup.sh

# Explore safely first — shows every command, changes nothing:
sudo ./setup.sh --dry-run

# Or open the interactive menu:
sudo ./setup.sh
```

## Step-by-step usage

```bash
sudo ./setup.sh detect              # 1. identify the GPU, save the profile
sudo ./setup.sh drivers             # 2. NVIDIA CUDA stack, or AMD Vulkan stack
sudo ./setup.sh vram 64             # 2b. AMD Strix Halo only: 64 GiB GPU memory
sudo ./setup.sh power 350           # 2c. NVIDIA only: cap GPU at 350W (persistent)
sudo ./setup.sh build               # 3. build the engine (CUDA or Vulkan)
sudo ./setup.sh model               # 4. download a GGUF model (+ vision projector)
sudo ./setup.sh configure           # 5. context, GPU layers, host/port, API key
sudo ./setup.sh service install     # 6. install as an auto-starting daemon

sudo ./setup.sh doctor              # health-check anytime
sudo ./setup.sh status              # what's installed / configured
sudo ./setup.sh build --rollback    # back to the previous engine build
sudo ./setup.sh uninstall all       # reverse it
```

## Reproducible restore — one config, the whole stack

The config file is the **single source of truth**. Once you've configured a
machine, the same `config.conf` rebuilds it from scratch on a fresh Ubuntu —
**no artifacts are committed to this repo**, and nothing is prepared by hand.

```bash
# On a brand-new Ubuntu 26.04, with your config.conf in place:
sudo ./setup.sh restore
```

`restore` walks the full chain **unattended** — drivers → engine → model →
runtime → service → doctor — reading every decision from the config:

- **GPU profile / driver** — `HW_*`, `NVIDIA_DRIVER_PKG`, `NVIDIA_POWER_LIMIT_W`.
- **Engine** — `LLAMACPP_REPO` (default: upstream `ggml-org/llama.cpp`, or a
  fork) and `LLAMACPP_REF`, a branch, tag or commit that pins the build (empty =
  the remote's default branch); built in `~/llama`.
- **Exact model** — `MODEL_REPO` + `MODEL_FILE` are downloaded straight from
  Hugging Face; `MODEL_MMPROJ_FILE` adds the vision projector (image input).
  The interactive `model` browser saves these for you the first time.
- **Runtime** — `LLAMA_CTX`, `LLAMA_NGL`, `LLAMA_HOST/PORT`, `LLAMA_EXTRA_ARGS`
  (KV-cache type, samplers…) and `LLAMA_API_KEY`.
- **Chat template** — when `CHAT_TEMPLATE_FIXUP="1"`, the template is
  **regenerated from the downloaded GGUF**: the embedded chat template is
  extracted and its `raise_exception(…)` validation guards are neutralised. This
  fixes agentic clients (OpenCode, etc.) that legitimately send consecutive
  same-role turns and otherwise hit *"roles must alternate"* with some models
  (Mistral/Devstral), while keeping all tool-call handling intact. The file is
  derived at `/etc/setup-ubuntu-ai/<model>-template.jinja`, never committed.

A ready-made profile ships in [`config.bonsai2-27b.conf`](config.bonsai2-27b.conf);
[`deploy.sh`](#one-command-on-a-fresh-machine--deploysh) places it and runs
`restore` for you.

### Moving to a new machine (same external GPU)

`restore` is built for exactly this: the **same external eGPU on a different
host**. Hardware is re-detected on the new box, and any absolute paths the
config carried from the old host (e.g. `/home/<old-user>/models`) are
automatically **re-homed** to the new machine's user — so a different username
is fine. Every phase re-runs, so stale state flags are harmless.

The only thing to carry to the new machine is `config.conf` (and, for gated
models, an `hf auth login` as your user). A NVIDIA Secure-Boot/MOK enrolment
still requires a reboot; continue with `sudo ./setup.sh resume` afterwards (or
use Ubuntu's pre-signed modules to avoid the console step).

## Bonsai 2 27B on a 16 GB RTX 5080

**The headline:** a 27B-class model with its **full 262k context** and
**vision** inside a 16 GB card.

### The model

[Ternary Bonsai 2 27B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)
(PrismML, Apache-2.0) is Qwen3.8-27B with its weights rewritten as **ternary**
values (−1, 0, +1) in a Hadamard-rotated basis with one FP16 scale per 128
weights: **7.2 GB** (`PQ2_0` packing) instead of 54 GB. PrismML reports 98.2 %
of the FP16 average on a 20-benchmark suite (coding 81.6 vs 82.2, math 96.6 vs
97.1, tool use 77.6 vs 79.7) — but only **~75 % on long-horizon agent runs**
(SWE-bench Verified 60.8 vs 80.6, Terminal-Bench 2.1 52.8 vs 69.7). These are
vendor numbers; measured here, see below.

### The engine

Upstream llama.cpp cannot run these files yet: the `PQ2_0`/`PTQ1_0` weight
types and the activation-side Hadamard transform live in PrismML's fork. The
profile builds **PrismML's own engine** —
[PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp), branch
`prism`, the runtime their Bonsai-demo installs too — pinned by `LLAMACPP_REF`,
in `~/llama`. Once the kernels land upstream, only `LLAMACPP_REPO` changes.

### Why a 5.5-bit KV cache

The weights take 6.4 GiB of the 15.8 GiB CUDA can use; the rest holds the KV
cache, the vision encoder and the compute buffers — which reserve an f16
working copy of the KV for attention at full depth. Measured (wikitext-2
perplexity, 4 × 2048 tokens; the engine Hadamard-rotates a quantized K cache
automatically):

| KV cache | Bits/value | Perplexity | Max context with vision |
|---|---:|---:|---:|
| `f16` | 16 | 8.622 | — |
| `q8_0` | 8.5 | 8.624 | 188k |
| **`q5_0`** | **5.5** | **8.620** | **262k (full)** |
| `q4_0` | 4.5 | 8.668 | 262k |

`q5_0` measures as good as `f16` and fits the model's full native context, so
the profile uses it.

### Where the 16 GB go (measured, 262,144 tokens)

| Item | VRAM |
|---|---:|
| Weights (`PQ2_0`) | 6,540 MiB |
| KV cache, `q5_0`, 262,144 tokens × 21.5 KB | 5,632 MiB |
| Compute buffers (incl. the f16 working copy at full depth) | 1,370 MiB |
| Vision encoder (mmproj 600 MiB + its compute buffer 248 MiB) | 848 MiB |
| Recurrent state, CUDA context | ~570 MiB |
| **Loaded / peak at a 241k-token prompt plus an image** | **14,962 / 15,094 MiB** |

### The runtime recipe

`LLAMA_EXTRA_ARGS` in the profile:

```
--flash-attn on --parallel 1 --cache-type-k q5_0 --cache-type-v q5_0 --no-mmap \
--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0
```

- **`q5_0` K and V** — the 5.5-bit KV cache; a quantized KV cache needs flash
  attention.
- **`--parallel 1`** — the hybrid model's recurrent state grows with every slot.
- **`--no-mmap`** — the weights live in VRAM, not also in the page cache.
- **Samplers** — the Qwen3.8 / PrismML thinking-mode recommendation.

Derived from other keys and added at render time (never stored, so they cannot
go stale): `--mmproj` (vision), `--alias` (the model id the API reports: the
GGUF file name, not its path) and the API-key credential.

### Measured — RTX 5080, CUDA 13.4, engine `bdc23b56b`

- **Correctness:** perplexity 8.622 with f16 KV — PrismML's reference is
  8.623 — and 8.620 with the profile's `q5_0` KV.
- **Speed:** ~88 tok/s generation at short context (vs ~56 tok/s for
  Qwen3.8-27B IQ4_XS before), ~22 tok/s at 240k; ~950 tok/s prompt processing.
- **Long context + vision:** a needle in a 241k-token haystack plus an image in
  the same request — both answered correctly.
- **Config-editing accuracy** ([`benchmarks/config_edit_bench.py`](benchmarks/config_edit_bench.py),
  surgical edits in a 366-field JSON and a 205-field YAML, every other leaf
  preserved): **3/3 exact** each — the same as the IQ4_XS model before.

### CUDA toolkit versions

The profile's engine is validated on CUDA 13.4 (perplexity above). Engines with
TurboQuant KV codecs (`turbo*`/VBR cache types, e.g. the buun-llama-cpp fork)
produce **gibberish on CUDA 13.0 and 13.2** — the `build` step refuses those
toolkits for them. After any toolkit change, repeat the perplexity check
(`f16` vs the quantized KV type) before trusting the output.

### One command on a fresh machine — `deploy.sh`

[`deploy.sh`](deploy.sh) places a profile (paths re-homed to this machine's
user), sets the API key, then runs `restore`:

```bash
git clone <this-repo> setup-ubuntu-ai && cd setup-ubuntu-ai
sudo ./deploy.sh bonsai2-27b              # drivers → engine → model → service, A→Z
sudo ./deploy.sh bonsai2-27b --key MYKEY  # or with an explicit API key
```

Without `--key`, a redeploy **keeps the key of the installed config** (clients
keep working); on a fresh machine a random key is generated and printed once.

**Skip the source build on a compatible box** with `--engine`: reuse a prebuilt
engine instead of compiling. Safe only when the target shares the CPU
instruction set **and** the GPU arch (`sm_*`) — e.g. the same board with an RTX
5070 Ti (Blackwell `sm_120`); if the binary won't run here, `restore` builds
from source instead.

```bash
# from a working twin (same CPU + sm_120):
sudo ./deploy.sh bonsai2-27b --engine otherbox:~/llama
# or from a portable release tarball you built once:
sudo ./deploy.sh bonsai2-27b --engine llama-sm120-<commit>.tar.zst
```

Build that tarball with [`package-engine.sh`](package-engine.sh): runtime CPU
dispatch (no `-march=native`, runs on any x86-64-v2+ CPU), an `$ORIGIN` RPATH
(runs from any path), its own build tree (never touches the live engine).
**Upload it to a GitHub Release, never commit it into git.**

### Use it from OpenCode (agentic coding + images)

Client configs ship in [`opencode.example.json`](opencode.example.json) (LAN /
localhost) and [`opencode.remote.example.json`](opencode.remote.example.json)
(through the [platform ingress](#public-access--the-platform-ingress)). Copy one to `~/.config/opencode/opencode.json`, set
the API key and the address. Bonsai 2 is a **reasoning** model, so the config
sets `interleaved.field = "reasoning_content"` and `reasoning: true`, plus
`tool_call: true` for agentic tool use and `attachment: true` with image input
for screenshots. The server ignores the model name clients send, so existing
configs with an older model id keep working; the id `/v1/models` reports is
the GGUF file name.

## Public access — the platform ingress

The public door is a platform ingress in front of the machine (e.g. a
Kubernetes ingress controller at `https://llm.example.com`): it terminates TLS,
can put a login in front, and forwards to this machine's llama-server on its
LAN address, port 8080. The host runs no reverse proxy and no TLS of its own —
ports 80/443 belong to the ingress. What the host provides (checked by
`sudo ./setup.sh doctor`):

- `llama-server.service` binds `0.0.0.0:8080` — reachable on the LAN address,
  plain HTTP;
- `GET /health` answers `200 {"status":"ok"}` once the model is loaded, without
  a key;
- the OpenAI-compatible API under `/v1/…` and llama.cpp's web UI under `/`;
- streaming (SSE) over plain HTTP; llama-server's own read/write timeout is
  3600 s;
- the service starts on boot and restarts on failure (`Restart=on-failure`).

With `LLAMA_API_KEY` set, clients send `Authorization: Bearer <key>` through
the ingress for everything under `/v1/…`.

## Engine builds — pinned, staged, reversible

- The engine lives in `~/llama`, whichever llama.cpp fork `LLAMACPP_REPO`
  names.
- `LLAMACPP_REF` pins the source; without it the build tracks the remote's
  default branch. Switching `LLAMACPP_REPO` just repoints the checkout.
- A build compiles in `build-next/`, is verified (the binary must actually run
  on this CPU), and only then swapped in as `build/`; the running server keeps
  going and picks the new engine up on its next restart. The previous engine
  stays as `build-prev/` — `sudo ./setup.sh build --rollback` swaps it back.
- An unchanged source is not rebuilt; a changed one rebuilds incrementally
  (the previous tree is recycled).

## API key

`LLAMA_API_KEY` in the config (root-only, mode 600) is rendered into
`/etc/setup-ubuntu-ai/api-key` (root-only) and handed to the service as a
**systemd credential** (`LoadCredential=` + `--api-key-file`): it never appears
on a command line, in the environment, in a diff or in a log. Clients send
`Authorization: Bearer <key>`; without it every endpoint but `/health` answers
401.

## Flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Print every command, change nothing |
| `-y, --yes` | Assume "yes" (unattended) |
| `--quiet` | Suppress the `▶` command echo |
| `--no-ui` | Plain text menus instead of whiptail |
| `--log-level debug` | Echo even more detail |
| `--config PATH` | Alternate config file |

## What goes where

| Path | Purpose |
|------|---------|
| `~/llama` | engine source checkout (owned by you; upstream or a fork) |
| `~/llama/build`, `build-prev` | the running engine, and the previous one for `--rollback` |
| `~/models` | downloaded GGUF models and vision projectors |
| `/etc/setup-ubuntu-ai/config.conf` | persisted state (**the source of truth** — carry this to reproduce a machine; root-only) |
| `/etc/setup-ubuntu-ai/api-key` | the API key the service loads as a credential (root-only) |
| `/etc/setup-ubuntu-ai/llama-server.env` | service runtime settings (generated from the config) |
| `/etc/setup-ubuntu-ai/<model>-template.jinja` | chat template regenerated from the GGUF (when `CHAT_TEMPLATE_FIXUP=1`) |
| `/etc/systemd/system/llama-server.service` | the daemon |
| `/var/log/setup-ubuntu-ai/install.log` | full transcript |

The **llama-server** runs as your user and binds **`0.0.0.0`** by default — it is
reachable from your LAN, which the platform ingress needs; keep an API key set.

## Important notes

- **NVIDIA + Secure Boot.** The open module must be signed. The installer offers
  Ubuntu's pre-signed modules (no console needed), MOK enrollment (needs a
  physical/IPMI console at the next reboot), or disabling Secure Boot. After a
  required reboot, continue with `sudo ./setup.sh resume`.
- **NVIDIA power limit (TDP).** `power <WATTS>` caps the GPU's sustained power
  draw and installs `nvidia-powerlimit.service` so the cap is re-applied on every
  boot — before llama-server starts. Useful for thermals or limited PSU cabling —
  e.g. an RTX 5090 (600W) fed by only 3× 8-pin (~450W budget) should be capped to
  **350–400W** for safety margin. A software cap limits *sustained* draw; it does
  not replace correct, fully-seated cabling.
- **AMD VRAM split.** `vram <GiB>` raises the GTT / unified-memory ceiling the
  GPU can borrow (via GRUB `ttm.pages_limit` + a modprobe drop-in). The firmware
  UMA carve-out itself is a BIOS setting and is not changed from Linux. Requires
  a reboot.
- **eGPU transport (OcuLink *or* Thunderbolt).** The external GPU is brought
  onto the bus automatically, whichever way it is attached. **OcuLink** (or a
  slot riser) is a direct PCIe link — the card is on the bus at power-on, so
  nothing special happens. **Thunderbolt 4 / USB4** tunnels PCIe, and the dock
  must be *authorized* by `bolt` before its GPU appears in `lspci`; on a fresh
  box with a `user`/`secure` TB security level it would otherwise stay invisible.
  `detect` (and `restore`) run `boltctl enroll --policy auto` on the connected
  dock first — installing the `bolt` package if needed — so the same config
  rebuilds the stack over either link. The detected transport is shown in the
  hardware report and `status` as **GPU link**. Set `TB_AUTHORIZE="no"` in the
  config to opt out of automatic authorization.
- **Models** are downloaded with the Hugging Face CLI (`hf` / `huggingface-cli`,
  installed via `pipx`). Gated models need `hf auth login` as your user first.

## Repository layout

```
setup.sh                  entry point (verbs + menu + dispatch)
deploy.sh                 place a profile, set the API key, run restore
package-engine.sh         portable, relocatable engine tarball for deploy.sh --engine
lib/                      shared helpers (logging, config, ui, apt, runtime rendering, …)
modules/                  one file per phase (NN-name.sh, exposes module_main)
services/                 systemd unit template
config.bonsai2-27b.conf   RTX 5080 + Bonsai 2 27B: 262k context, vision
opencode*.json            OpenCode client configs (local / remote)
benchmarks/               config-editing accuracy benchmark
tests/run.sh              behavioural tests (unprivileged sandbox, no GPU needed)
```

The `model` step is a **live Hugging Face search** — type a query, pick a repo
from the results, then pick from its actual available quantisations (with file
sizes) and, if the repo has one, a vision projector. No hard-coded model list.

## Requirements

Ubuntu 24.04+ (tested target 26.04), `sudo`, internet access. `whiptail`,
`pciutils`, `curl`, `gnupg`, `git` are installed automatically if missing (plus
`bolt` on Thunderbolt/USB4 machines, to authorize a TB-attached eGPU dock).

## Tests

```bash
tests/run.sh    # no root, no GPU: modules run in a sandbox with stubs
```

## Field notes: RTX 5090 in an AG03 OcuLink eGPU dock

Hard-won, real-world experience from this exact build (RTX 5090 in an **AG03
OcuLink eGPU dock**, driven over OcuLink/PCIe). Save yourself the weekend.

### The crash

Under sustained inference load the GPU threw **`Xid 79 — "GPU has fallen off the
bus"`** after ~3–5 minutes, every time, needing a reboot to recover
(`Xid 154 — "Node Reboot Required"`). Core temp was fine (~67 °C; it throttles
~83 °C), so it was **not thermal**.

### What it was NOT (each tested and ruled out)

- **The model** — crashed on two different GGUFs.
- **The context size** — crashed at both 128k and 256k.
- **The OcuLink data cable** — swapped it; the PCIe link trained cleanly to
  **Gen4 x4 under load** and it *still* crashed. (x4 is normal for OcuLink; the
  link being healthy right up to the fall-off pointed away from the data path.)

### Root cause: GPU power delivery

A power-draw **sag (400 W → 342 W) was logged in the seconds before each
fall-off** — a brownout, not a data-link fault. The dock's power path could not
hold a 400 W-capped 5090 under sustained load. Current heating a marginal /
under-seated **12V-2×6** connector over a few minutes is exactly the "runs fine,
then dies after a while under load" signature.

### The fix: a dedicated external PSU

Feed the GPU's 12V-2×6 from its **own PSU** (here a Corsair **SF1000**) instead
of relying on the dock. After this: an **8-minute sustained 400 W soak with zero
Xid** (peak 64 °C, 411 W), then stable under real workloads.

### Gotcha that will cost you an hour — the standalone PSU won't power on

A loose ATX PSU stays **OFF** until `PS_ON` is pulled to ground. Connecting only
the two PCIe / 12V-2×6 cables is **not enough** — the PSU never starts, its fan
doesn't spin, and the **GPU LEDs stay dark** on PC power-on. (Confirm the card is
fine: it lights up when drawing from the dock instead.) To start it:

- Connect the **24-pin** header and **bridge `PS_ON` (green) to any ground
  (black)** — a ~€5 jumper / "paperclip" adapter, or literally a paperclip.
- **Power-on order: external PSU first, then the PC.**
- **Fully seat the 12V-2×6** at the GPU until it clicks — an under-seated
  connector is the classic melt / brownout cause.

### Two PSUs on one outlet — safe

Both PSUs on the **same grounded** power strip (a proper 16 A strip, not a thin
travel one) is fine and in fact **preferred**: they share a ground reference
through PE. A 5090 system draws ~600–800 W; a 230 V / 16 A circuit supplies
~3680 W, so you are far from the limit. Minor inrush when both PSUs start
together is harmless on a normal B16 breaker. The non-negotiable is a genuinely
**earthed** outlet/strip.

### Software mitigation (not a substitute for the above)

`sudo ./setup.sh power 400` caps sustained draw and re-applies it on every boot.
It *reduces* brownout odds but does **not** fix marginal cabling or an
underpowered dock — the dedicated PSU and a fully-seated 12V-2×6 are the real
fix.
