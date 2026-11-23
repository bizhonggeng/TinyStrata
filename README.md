# TinyStrata

[简体中文](README.zh-CN.md) | [English](README.md)

目标：在 4G VRAM 显卡中快速、高质量、稳定的运行 MoE 模型（比如 Qwen3.6-35B-A3B）。

**Goal:** run MoE models (for example **Qwen3.6-35B-A3B, 256 experts, 8 per token**) fast, with high
quality and stable output, on a **4 GB VRAM** card — with a long context that is actually usable.

**TinyStrata** is a patched build of [Strata](https://github.com/Niko1221/Strata) (MIT) aimed at
that one target.

Upstream runs this model fine on 8–12 GB cards. On 4 GB the draft layer alone did not fit
next to an 80 K context, and the decoder had two failure modes we hit in practice (verbatim
reasoning loops, and parked conversations lost when RAM ran out). TinyStrata is those
three fixes plus the launcher/benchmarks we used to measure them.

Everything here is a patch on upstream — **no model and no pack is included.** A prebuilt
`strata.exe` (CUDA 12.8, sm_86) is attached to [Releases](https://github.com/bizhonggeng/TinyStrata/releases/latest); its sha256 is published alongside it.

## What it changes

| Patch | What it does | Measured effect (RTX 3050 Ti 4 GB + i5-11400H + 32 GB) |
|---|---|---|
| `0001-mtp-cpu-moe` | The MTP draft layer's 256 routed experts move to host RAM and run on the CPU (`--mtp-cpu-moe`); the CPU path skips CUDA graph capture | Draft layer **439 → 127 MiB** of VRAM, which is what lets `--max-context 81920` keep MTP. decode 24.7 tok/s @65 K (87 % drafts accepted), 18.6–21.5 tok/s @80 K (88–89 %) |
| `0002-dry-sampler` | llama.cpp's **DRY** sampler as a pre-pass on the logits: a penalty that grows with the length of a *repeated sequence*, not with token frequency | Off by default (bit-exact). At `--dry-multiplier 1.5` a coding prompt that spent 700 tokens of silent thinking and answered nothing produced the correct function |
| `0003-serve-setup-tools` | Session autosave to disk (a disk fallback for parked conversations), `HH:MM:SS` on every log line, `--chat-template-file`, three more selectable i-quants | Restores a 52 K-token conversation in **0.47 s** instead of 314 s of re-reading; the quant list was a pinned-sha256 list, not a format limit |

## Numbers

Two modes, measured on this machine (interleaved runs, median of three, warm cache between
runs — see `docs/4GB-TUNING.md` for the protocol):

| | short mode | long mode |
|---|---|---|
| `--max-context` | 20480 | **81920** |
| KV | `k8v4`, fully resident | `k8v4`, fully resident |
| MTP | on, experts **on the GPU** (`--spec 3`) | on, experts **on the CPU** (`--mtp-cpu-moe 1`, `--spec 2`) |
| `--vram-reserve-mib` | 64 | 64 |
| largest context that starts | 39936 | 81920 |
| decode | ~32–36 tok/s | ~18 tok/s @79 K, ~25 tok/s @30 K |
| prefill | ~250 tok/s | **153.8 tok/s @79 K** |

Same 79 K prompt, same machine, against llama.cpp (b11382) running the same model family at
`Q4_K_M` with `--spec-type draft-mtp`, `-cth/-ctv q8_0`, `-ncmoe 999`:

| | TinyStrata (UD-IQ3_S, 3.46 bit/w) | llama.cpp (Q4_K_M, 5.19 bit/w) |
|---|---:|---:|
| prefill @79 K | **153.8 tok/s** | 103.3 tok/s |
| decode @79 K (median of 3) | **18.00 tok/s** | 12.35 tok/s |
| draft acceptance | 71–78 % | 65–78 % |

The ratio of the two speeds (1.46 decode, 1.49 prefill) tracks the ratio of the weight bytes
(5.19 / 3.46 = 1.50) almost exactly: at this size the decoder is a **bytes-moved** problem, so a
smaller quant wins and the i-quant decode path costs nothing extra.

## Requirements

- **4 GB VRAM** (built and measured on an RTX 3050 Ti Laptop, sm_86), CUDA 12.8, Windows.
- **32 GB RAM** — the experts live there (~12 GiB for UD-IQ3_S).
- Python 3.11 venv with `cmake`/`ninja` for the engine build (upstream's `START-HERE.bat` makes it).
- The model: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` — **UD-IQ3_S** (15.3 GB, the size measured here)
  or UD-IQ4_XS (18.2 GB). The MTP layer must be inside the file (`blk.40`); see
  `docs/GGUF-SELECTION-STANDARD.md` before downloading another quant.

## Install

Or skip step 3 and take `strata.exe` from [Releases](https://github.com/bizhonggeng/TinyStrata/releases/latest) (CUDA 12.8, sm_86). Patches 1–2 are engine C++ changes, so a binary built from upstream *before* them will not have `--mtp-cpu-moe` or `--dry-multiplier`.

```bash
# 1. upstream, at the commit these patches are written against
git clone https://github.com/aflin/Strata
cd Strata && git checkout cd1daa4e          # "Merge upstream/main (0.1.43) into qwen36-35b-support"

# 2. the patches
git am /path/to/TinyStrata/patches/*.patch

# 3. build the engine (upstream's own script; CUDA 12.8, sm_86)
cmd /c build-strata-cuda12.bat
cp build-cuda12/strata.exe engine-cuda12/strata.exe

# 4. one-time: build the pack from the GGUF (writes the expert pack + profile)
python setup.py --family qwen36 --model UD-IQ3_S
```

Then copy `configs/strata-qwen36-iq3s.example.json` to `D:\dev\strata-qwen36-iq3s.json`,
fix its `--pack` / `--native` / `--mtp` / `--expert-profile` paths, and start a mode:

```bash
# long mode (80 K, MTP experts on the CPU) — this is the mode this repository is about
python tools/strata-run.py --tag long --ctx 81920 --kv k8v4 --vram-reserve-mib 64 \
    --mtp on --mtp-cpu-moe on --spec 2 --thinking on --preserve-thinking on

# short mode (20 K, MTP experts on the GPU)
python tools/strata-run.py --ctx 20480 --kv k8v4 --vram-reserve-mib 64 --mtp on --spec 3
```

`launcher/strata-launcher.ahk` is an AutoHotkey v2 GUI over the same two modes (parameter grid,
model/GGUF/mmproj pickers, vision, chat-template file, run status, log tail). `--selftest` runs
its own checks.

## Expected layout

The scripts assume this layout; `DEV` (top of `tools/strata-run.py` and the launcher) and `ROOT`
are the only two constants to change for another one.

```
D:\dev\
├── strata\                     upstream checkout, engine in strata\engine-cuda12\strata.exe
├── tools\strata-run.py         the driver
├── configs\strata-qwen36-iq3s.example.json   copy to strata-qwen36-iq3s.json and fix the paths
├── results\                    logs land here
└── sessions\                   autosave .sess files (set "slot_save_path")

E:\models\unsloth\Qwen3.6-35B-A3B-MTP-GGUF\   the GGUF (+ mmproj-F32.gguf for images)
E:\Strata-data\packs\qwen36-UD-IQ3_S\         the pack setup.py builds
```

## Limits (read this before filing anything)

- **pi's compaction is a hard boundary** for prefix reuse: a compacted conversation re-reads its
  whole prompt once (~2 min at 37 K tokens here). Every engine that matches token prefixes has
  this.
- **decode falls with context**: 25 tok/s at 30 K, 18 at 79 K on this card.
- **Tool-call loops are a harness problem, not a sampler problem.** A model that repeats the same
  `read` call 77 times is not fixed by temperature, DRY or a quant change — it needs a guard in
  the client. `tools/watch-loop.py` detects both kinds (repeated tool calls in the client's
  session file, verbatim reasoning in the engine log).
- **K-quants are not free here**: `Q4_K*`/`Q5_K*`/`Q6_K` need a build with
  `-DSTRATA_MMQ_KQUANTS=ON` for the prompt path, and every added kernel instance is loaded
  eagerly, costing VRAM for *every* model on a 4 GB card. `Q2_K`/`Q3_K` are not covered by that
  option at all.
- **Single GPU, single request.** `--batch`, layer splits and peer devices do not combine with
  these patches (the session files refuse them too).

## Licence

MIT, as upstream. `patches/` are our changes to MIT code; `LICENSE` is upstream's. See
`NOTICE.md` for the exact baseline and what was modified.
