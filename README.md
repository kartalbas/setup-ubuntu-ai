# setup-ubuntu-ai

A modular, **verbose**, user-friendly Bash installer that takes a fresh Ubuntu
machine to a running, auto-starting local LLM server — adapting automatically to
your GPU.

Supported hardware:

| GPU | Backend | Notes |
|-----|---------|-------|
| **NVIDIA RTX 50-series** (Blackwell, `sm_120`) — e.g. RTX 5090 (32 GB), **RTX 5080 (16 GB)** | CUDA | open kernel driver `nvidia-driver-595-open` + CUDA toolkit |
| **AMD Ryzen AI Max+ 395 "Strix Halo"** (Radeon 8060S, `gfx1151`) | **Vulkan only** (no ROCm) | Mesa RADV; settable unified-memory / VRAM split |

It also degrades gracefully for other NVIDIA/AMD GPUs (manual vendor pick).

> ⭐ **Highlight — Qwen3.6-27B at 100k context on a 16 GB RTX 5080.** This model
> was effectively *not* runnable at long context on a 16 GB card; people bought a
> 24 GB GPU (RTX 4090 / 5090) just to get the context. With the **TurboQuant**
> KV-cache profile this installer ships, it now fits — engine built for you,
> one config, `sudo ./setup.sh restore`. See
> [**Run Qwen3.6-27B at 100k on a 16 GB RTX 5080**](#run-qwen36-27b-at-100k-context-on-a-16-gb-rtx-5080--turboquant-kv-cache).

## Design principles

- **Verbose by default.** Every state-changing command is echoed in full
  (`▶ apt-get install …`) before it runs, real tool output streams live, and
  every file edit is shown as a `diff` with a timestamped backup. Nothing
  important happens behind a spinner.
- **Step-by-step.** Each phase is its own command — run them one at a time, in
  your own order. A `menu` and a `guided` flow exist too.
- **Idempotent & reversible.** Re-running a step is safe; every step has an
  `uninstall`, file edits are backed up, and a failed step auto-rolls-back.
- **Survives reboots.** The reboots that NVIDIA Secure-Boot/MOK and the AMD VRAM
  change require are handled with a `resume` checkpoint.

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
sudo ./setup.sh build               # 3. compile llama.cpp (CUDA or Vulkan)
sudo ./setup.sh model               # 4. download a GGUF model (interactive)
sudo ./setup.sh configure           # 5. context size, GPU layers, host/port
sudo ./setup.sh service install     # 6. install as an auto-starting daemon

sudo ./setup.sh doctor              # health-check anytime
sudo ./setup.sh status              # what's installed / configured
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

A ready-made profile ships in [`config.example.conf`](config.example.conf) — the
verified **RTX 5080 + Devstral-Small-2-24B @ 64k** setup. It's optional; copy it,
set your own API key, and restore:

```bash
sudo cp config.example.conf /etc/setup-ubuntu-ai/config.conf
sudoedit /etc/setup-ubuntu-ai/config.conf      # set REPLACE_WITH_YOUR_API_KEY
sudo ./setup.sh restore
```

`restore` walks the full chain **unattended** — drivers → llama.cpp → model →
runtime → service → doctor — reading every decision from the config:

- **GPU profile / driver** — `HW_*`, `NVIDIA_DRIVER_PKG`, `NVIDIA_POWER_LIMIT_W`.
- **Exact model** — `MODEL_REPO` + `MODEL_FILE` are downloaded straight from
  Hugging Face (the interactive `model` browser saves these for you the first
  time you pick a model, so a later `restore` re-fetches the identical file).
- **Runtime** — `LLAMA_CTX`, `LLAMA_NGL`, `LLAMA_HOST/PORT`, `LLAMA_EXTRA_ARGS`
  (flash-attention, KV-cache type, API key…).
- **Chat template** — when `CHAT_TEMPLATE_FIXUP="1"`, the template is
  **regenerated from the downloaded GGUF**: the embedded chat template is
  extracted and its `raise_exception(…)` validation guards are neutralised. This
  fixes agentic clients (OpenCode, etc.) that legitimately send consecutive
  same-role turns and otherwise hit *"roles must alternate"*, while keeping all
  tool-call (`[TOOL_CALLS]`/`[ARGS]`) handling intact. The generated file lives
  at `/etc/setup-ubuntu-ai/<model>-template.jinja` — derived, never committed.

### Moving to a new machine (same external GPU)

`restore` is built for exactly this: the **same external eGPU on a different
host**. Hardware is re-detected on the new box, and any absolute paths the
config carried from the old host (e.g. `/home/<old-user>/models`) are
automatically **re-homed** to the new machine's user — so a different username
is fine. Stale `CUDA_OK` / `SERVICE_INSTALLED` flags are harmless: every phase
re-runs unconditionally and overwrites them.

The only thing to carry to the new machine is `config.conf` (and, for gated
models, an `hf auth login` as your user). A NVIDIA Secure-Boot/MOK enrolment
still requires a reboot; continue with `sudo ./setup.sh resume` afterwards (or
use Ubuntu's pre-signed modules to avoid the console step).

## Run Qwen3.6-27B at 100k context on a 16 GB RTX 5080 — TurboQuant KV cache

**The headline:** Qwen3.6-27B was, for practical purposes, *not* runnable at long
context on a 16 GB card. The IQ4_XS weights alone are ~13.3 GiB resident on the
GPU, and a 100k-token KV cache in the usual `f16`/`q8_0` formats blows straight
past the ~2 GiB that's left — so people bought a 24 GB card (RTX 4090 / 5090)
*just to get the context*. **TurboQuant changes that:** with Trellis-Coded
Quantization (TCQ) for the KV cache, the 27B runs at the **full 100k context
inside 16 GB**, on an RTX 5080. This installer ships that exact setup as a
ready-made profile and **builds the engine for you**.

### Why it didn't fit before

- IQ4_XS weights: **~13.3 GiB** resident on the GPU (`--n-gpu-layers 999`).
- Qwen3.6-27B is a **hybrid** model — gated-delta-net / linear-attention layers
  plus a recurrent state cache — so its KV + state footprint is heavy.
- A 100k KV cache at `f16`/`q8_0` needs several GiB; there is no room next to the
  weights in 16 GiB → CUDA out-of-memory.

### What makes it fit: TurboQuant (TCQ) KV cache

[buun-llama-cpp](https://github.com/spiritbuun/buun-llama-cpp) is a fork of
llama.cpp that adds **Trellis-Coded Quantization** KV-cache types (`turbo3_tcq`),
compressing the cache ~2–3× at quality that matches or beats `f16`. Both K and V
on `turbo3_tcq` is what lets the 100k cache live in the ~2 GiB left after the
weights load.

### Use it — the whole stack, from one config

The profile [`config.qwen3.6-27b-turbo.conf`](config.qwen3.6-27b-turbo.conf)
encodes both *the build* (which engine) and *the run* (which model + args):

```bash
sudo cp config.qwen3.6-27b-turbo.conf /etc/setup-ubuntu-ai/config.conf
sudoedit /etc/setup-ubuntu-ai/config.conf      # set your --api-key
sudo ./setup.sh restore
```

`restore` reads `LLAMACPP_REPO` and **builds the buun fork automatically** (into
its own `~/buun-llama-cpp`, leaving any upstream `~/llama.cpp` untouched),
downloads the exact GGUF (`MODEL_REPO`/`MODEL_FILE`), and starts the service with
the TurboQuant runtime args — nothing prepared by hand.

### Config-driven build source

The `build` step is no longer hard-wired to upstream:

- **`LLAMACPP_REPO`** — git URL to build (default: upstream `ggml-org/llama.cpp`;
  the profile points it at the buun fork). A checkout that tracks a *different*
  remote is detected and re-cloned automatically, so switching engines is clean.
- **`LLAMACPP_REF`** — optional branch/tag/commit pin for a reproducible build.

### The runtime recipe — and why each knob matters

`LLAMA_EXTRA_ARGS` in the profile is the **measured-working** command on a 16 GB
card. Each flag earns its place:

```
--flash-attn on --parallel 1 \
--cache-type-k turbo3_tcq --cache-type-v turbo3_tcq \
--no-mmap --fit off \
--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0
```

- **Both** caches on `turbo3_tcq`. The community's "leave K on `q8_0` for a touch
  more quality" tweak is real, but a `q8_0` K cache is **far larger** and OOMs at
  100k on 16 GB. Use both-turbo here.
- **`--parallel 1`.** Because the model is hybrid, its recurrent **rs-cache scales
  with `--parallel`** — the auto default (`n_parallel=4`) quadruples it and OOMs.
  Pin it to 1.
- **`--no-mmap`** keeps weights pinned in VRAM; **`--fit off`** silences the
  auto-offload warning since every knob here is already explicit.

### ⚠️ CUDA 13.1 or 13.3 only

TurboQuant's `turbo3_tcq` produces **gibberish output on CUDA 13.0 and 13.2** —
only **13.1 and 13.3** are known-good. The `build` step **guards this** and, when
the configured engine is the fork (or the args request a turbo cache), refuses to
build on a bad toolkit (overridable interactively, hard-fails a `restore`).

### Hard limit & failure mode (read this before you raise the context)

- **~15.2 / 16.3 GiB** used at 100k — that's the validated ceiling for this model
  on a 16 GB card. Raising `LLAMA_CTX` past 100k OOMs.
- The fork **SIGSEGVs on a failed `cudaMalloc`** (it crash-loops the service)
  instead of erroring cleanly — so an over-budget config *looks like a crash, not
  an OOM message*. **If `llama-server` dies a couple of seconds after "loading
  model", you are over the VRAM budget — lower `LLAMA_CTX`** (or check
  `journalctl -u llama-server` for `out of memory`).

### Measured — RTX 5080 (16 GB), `turbo3_tcq` KV, flash-attention

| Context depth | Generation | Prompt processing |
|---|---|---|
| 0    | **52.8 tok/s** | 2152 tok/s |
| 16k  | 49.4 tok/s | 1871 tok/s |
| 64k  | **46.1 tok/s** | 1228 tok/s |

Generation stays nearly flat across depth (≈53 → 46 tok/s from 0 → 64k). **Prompt
caching works**, too: the TCQ-compressed cache still does prefix reuse, so a
repeated prefix is served from cache (~4× faster prefill) rather than reprocessed.

### Use it from OpenCode (agentic coding)

A ready client config ships in
[`opencode.example.json`](opencode.example.json). Copy it to `~/opencode.json`
(or `~/.config/opencode/opencode.json`), set your API key and the server's
address (`127.0.0.1` locally, or the host's LAN IP), and OpenCode talks to the
local model. Because Qwen3.6 is a **reasoning** model, the config sets
`interleaved.field = "reasoning_content"` and `reasoning: true` so the thinking
stream is parsed correctly, plus `tool_call: true` for agentic tool use. The
model id must match what `llama-server` reports (the GGUF filename).

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
| `~/llama.cpp` | source + build (owned by you; rebuild without sudo) |
| `~/<repo-basename>` e.g. `~/buun-llama-cpp` | a non-default `LLAMACPP_REPO` builds in its own dir, leaving `~/llama.cpp` untouched |
| `~/models` | downloaded GGUF models |
| `/etc/setup-ubuntu-ai/config.conf` | persisted state (**the source of truth** — carry this to reproduce a machine) |
| `/etc/setup-ubuntu-ai/llama-server.env` | service runtime settings (generated from the config) |
| `/etc/setup-ubuntu-ai/<model>-template.jinja` | chat template regenerated from the GGUF (when `CHAT_TEMPLATE_FIXUP=1`) |
| `/etc/systemd/system/llama-server.service` | the daemon |
| `/var/log/setup-ubuntu-ai/install.log` | full transcript |

The **llama-server** runs as your user and binds **`0.0.0.0`** by default — it is
reachable from your LAN. There is **no authentication** unless you set an API key
during `configure`; consider doing so, or change the host to `127.0.0.1`.

## Important notes

- **NVIDIA + Secure Boot.** The open module must be signed. The installer offers
  Ubuntu's pre-signed modules (no console needed), MOK enrollment (needs a
  physical/IPMI console at the next reboot), or disabling Secure Boot. After a
  required reboot, continue with `sudo ./setup.sh resume`.
- **NVIDIA power limit (TDP).** `power <WATTS>` caps the GPU's sustained power
  draw and installs `nvidia-powerlimit.service` so the cap is re-applied on every
  boot. Useful for thermals or limited PSU cabling — e.g. an RTX 5090 (600W) fed
  by only 3× 8-pin (~450W budget) should be capped to **350–400W** for safety
  margin. A software cap limits *sustained* draw; it does not replace correct,
  fully-seated cabling.
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
setup.sh            entry point (verbs + menu + dispatch)
lib/                shared helpers (logging, config, ui, apt, state, …)
modules/            one file per phase (NN-name.sh, exposes module_main)
services/           systemd unit + env templates
config.example.conf known-good RTX 5080 + Devstral profile (optional, for `restore`)
config.qwen3.6-27b-turbo.conf  RTX 5080 + Qwen3.6-27B @ 100k via the buun-llama-cpp TurboQuant fork
opencode.example.json  ready OpenCode client config for the served model (set your API key)
```

The `model` step is a **live Hugging Face search** — type a query, pick a repo
from the results, then pick from its actual available quantisations (with file
sizes). No hard-coded model list.

## Requirements

Ubuntu 24.04+ (tested target 26.04), `sudo`, internet access. `whiptail`,
`pciutils`, `curl`, `gnupg`, `git` are installed automatically if missing (plus
`bolt` on Thunderbolt/USB4 machines, to authorize a TB-attached eGPU dock).

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
