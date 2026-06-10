# setup-ubuntu-ai

A modular, **verbose**, user-friendly Bash installer that takes a fresh Ubuntu
machine to a running, auto-starting local LLM server — adapting automatically to
your GPU.

Supported hardware:

| GPU | Backend | Notes |
|-----|---------|-------|
| **NVIDIA RTX 5090** (Blackwell, `sm_120`) | CUDA | open kernel driver `nvidia-driver-595-open` + CUDA toolkit |
| **AMD Ryzen AI Max+ 395 "Strix Halo"** (Radeon 8060S, `gfx1151`) | **Vulkan only** (no ROCm) | Mesa RADV; settable unified-memory / VRAM split |

It also degrades gracefully for other NVIDIA/AMD GPUs (manual vendor pick).

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
| `~/models` | downloaded GGUF models |
| `/etc/setup-ubuntu-ai/config.conf` | persisted state (the source of truth) |
| `/etc/setup-ubuntu-ai/llama-server.env` | service runtime settings |
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
- **Models** are downloaded with the Hugging Face CLI (`hf` / `huggingface-cli`,
  installed via `pipx`). Gated models need `hf auth login` as your user first.

## Repository layout

```
setup.sh            entry point (verbs + menu + dispatch)
lib/                shared helpers (logging, config, ui, apt, state, …)
modules/            one file per phase (NN-name.sh, exposes module_main)
services/           systemd unit + env templates
```

The `model` step is a **live Hugging Face search** — type a query, pick a repo
from the results, then pick from its actual available quantisations (with file
sizes). No hard-coded model list.

## Requirements

Ubuntu 24.04+ (tested target 26.04), `sudo`, internet access. `whiptail`,
`pciutils`, `curl`, `gnupg`, `git` are installed automatically if missing.

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
