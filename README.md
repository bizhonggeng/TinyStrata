# TinyStrata

<img src="assets/icon.png" width="96" align="right" alt="TinyStrata">

[简体中文](README.zh-CN.md) | [English](README.md)

---

## 1. Goal

> 目标：在 4G VRAM 显卡中快速、高质量、稳定的运行 MoE 模型（比如 Qwen3.6-35B-A3B）。
>
> **Goal: run MoE models fast, with high quality and stable output, on a 4 GB VRAM card.**

Upstream [Strata](https://github.com/Niko1221/Strata) runs Qwen3.6-35B-A3B fine on 8–12 GB cards.
Squeezed to 4 GB you hit three walls at once:

1. **It does not fit** — the MTP draft layer alone wants 439 MiB, and it has to share the card with
   an 80 K KV cache;
2. **It repeats itself** — at long context the decoder falls into verbatim reasoning loops, burning
   tens of thousands of tokens without answering;
3. **Conversations get lost** — under memory pressure parked conversations are dropped, and
   switching back costs a full re-read.

TinyStrata is three fixes for those three walls, plus the launcher, driver and benchmarks used to
measure them. It is deliberately small: **3 patches (~430 lines) + a toolchain**, not a whole-tree fork.

---

## 2. Features

| # | Feature | What it does |
|---|---|---|
| 1 | **MTP experts on the CPU** (`--mtp-cpu-moe`) | The draft layer's 256 routed experts move to host RAM and run on the CPU; the CPU path skips CUDA graph capture. Draft layer **439 → 127 MiB** of VRAM — which is what lets `--max-context 81920` keep speculative decoding |
| 2 | **DRY sampler** (`--dry-multiplier`) | llama.cpp's DRY as a pre-pass on the logits: a penalty that grows with the length of a **repeated sequence**, not with token frequency. Off by default (bit-exact); aimed at verbatim reasoning loops |
| 3 | **Session autosave** | After each request the KV state is fingerprinted and SAVEd to disk, and RESTOREd on the way back. A 52 K-token conversation returns in **0.47 s** instead of 314 s of re-reading — a disk fallback for parked conversations |
| 4 | **Log timestamps** | Every line from the engine and the driver carries `HH:MM:SS` (1,150 `fprintf` sites untouched — a pipe adds the stamps), so timing questions stop being guesswork |
| 5 | **GUI launcher** | AutoHotkey v2: two views (pro / compact), parameter grid, model / GGUF / mmproj pickers, vision, chat-template file, run status, log tail, per-mode INI. Ships with `--selftest` |
| 6 | **Driver and tools** | `strata-run.py` (one command per mode), `watch-loop.py` (two-source loop monitor), `ab-*.py` (warm-up + interleaved + median A/B benchmarks) |

### 2.1 Measured performance

RTX 3050 Ti Laptop **4 GB** + i5-11400H + 32 GB, two parameter sets:

| | short mode | long mode |
|---|---|---|
| `--max-context` | 20480 | **81920** |
| KV | `k8v4`, fully resident | `k8v4`, fully resident |
| MTP | on, experts **on the GPU** (`--spec 3`) | on, experts **on the CPU** (`--mtp-cpu-moe 1`, `--spec 2`) |
| `--vram-reserve-mib` | 64 | 64 |
| `--expert-cache` | 800 | 800 |
| largest context that starts | 39936 | **81920** |
| **decode** | ~32–36 tok/s | **18.00 tok/s @79 K** (median of 3) |
| **prefill** | ~250 tok/s | **153.8 tok/s @79 K** |

Same 79 K prompt, same machine, against llama.cpp (b11382) running the same model family at `Q4_K_M`:

| | TinyStrata (UD-IQ3_S, 3.46 bit/w) | llama.cpp (Q4_K_M, 5.19 bit/w) |
|---|---:|---:|
| prefill @79 K | **153.8 tok/s** | 103.3 tok/s |
| decode @79 K | **18.00 tok/s** | 12.35 tok/s |
| draft acceptance | 71–78 % | 65–78 % |

The ratio of the two speeds (1.46 decode, 1.49 prefill) tracks the ratio of the weight bytes
(5.19 / 3.46 = 1.50) almost exactly: at this size decoding is a **bytes-moved** problem, so the
smaller quant wins and the i-quant path costs nothing extra.

---

## 3. Hardware requirements

| | Requirement | Note |
|---|---|---|
| VRAM | **4 GB** | Built and measured on an RTX 3050 Ti Laptop (sm_86); 8 GB+ is easier |
| RAM | **32 GB** | The experts live there (~12 GiB for UD-IQ3_S) |
| OS | Windows x64 | The only platform tested here; the engine itself is portable |
| CUDA | **12.8** | The `strata.exe` in Releases is built for 12.8 / sm_86 |
| Disk | GGUF 15.3 GB + the pack `setup.py` builds (same order of magnitude) + session files (52 K tokens ≈ 588 MiB) | |
| Build only | Python 3.11 venv + `cmake` + `ninja` + MSVC (`vcvars64`) | §4 needs none of this |

---

## 4. Quick start (download and run, no build)

### 4.1 Download

| File | Where |
|---|---|
| **`TinyStrata-Launcher.exe`** (v0.1.0) | [Releases / v0.1.0](https://github.com/bizhonggeng/TinyStrata/releases/tag/v0.1.0) (538 KiB, **no AutoHotkey install needed**) |
| `strata.exe` + `strata.exe.sha256` | same release (61.7 MiB, CUDA 12.8 / sm_86) |
| `strata-launcher.ahk` (optional) | this repo, [launcher/](launcher/) (only if you want to change the UI) |
| `strata-run.py` (optional) | this repo, [tools/](tools/), the CLI driver |
| model GGUF | §7 |

> **The launcher finds the engine itself**: it searches its own directory, four parent
> directories and their subdirectories for `strata.exe` (including checkout layouts such as
> `engine-cuda12\strata.exe`), then derives python / driver / config / log paths. Override it
> with `STRATA_HOME` or pick a folder once from the menu (remembered in the ini).
> The UI is bilingual, **follows the system language** by default, and the
> 「语言 / Language」 menu switches it at any time.

```powershell
# verify (should print 9c6f5a0f...)
Get-FileHash strata.exe -Algorithm SHA256
Get-Content strata.exe.sha256
```

### 4.2 Put the files in place

```powershell
# <install> = wherever you put TinyStrata, e.g. C:\TinyStrata (used below)
copy strata.exe              <install>\strata\engine-cuda12\strata.exe
copy TinyStrata-Launcher.exe <install>\
copy strata-run.py           <install>\tools\
```

The folder name is yours to pick: the launcher finds the engine by itself (§4.5) and the
CLI driver knows its own location (`tools/strata-run.py` -> its parent is `<install>`).
For a different layout, set `STRATA_HOME` / `STRATA_ROOT` (§5.3).

### 4.3 Build the pack once

```powershell
cd <install>\strata
python setup.py --family qwen36 --model UD-IQ3_S
```

### 4.4 Configure the template

Copy `configs/strata-qwen36-iq3s.example.json` to `<install>\strata-qwen36-iq3s.json`.
The template uses **environment-variable placeholders** (`%STRATA_ROOT%` / `%STRATA_PACKS%` /
`%STRATA_MODELS%` ...): either set them (see `configs/README.md`) or edit the paths in place.

### 4.5 Start a mode

**A: GUI** — double-click `TinyStrata-Launcher.exe` (or the `.ahk`), pick long/short, press Start.
It locates the engine by itself, so no path editing. The simple view already has a **Model** group
with GGUF / mmproj `Browse...` buttons, so you can point it at the model you just downloaded
without switching to the pro view. **Vision follows the mmproj**: with none selected the vision
box is `off` and greyed out (no error); picking an mmproj switches it to `cpu` (no VRAM), and you
can still choose `gpu` / `off` afterwards. The UI follows the system language and the
「Language」 and 「About」 menus (About has clickable project / upstream / model links and
prints the paths the launcher resolved). Launcher self-checks: `TinyStrata-Launcher.exe --selftest` /
`--i18ntest` / `--findtest` (reports land next to the engine).

**B: command line**

```bash
# long mode (80 K, MTP experts on the CPU) — the mode this repository is about
python tools/strata-run.py --tag long --ctx 81920 --kv k8v4 --vram-reserve-mib 64 \
    --mtp on --mtp-cpu-moe on --spec 2 --thinking on --preserve-thinking on

# short mode (20 K, MTP experts on the GPU)
python tools/strata-run.py --ctx 20480 --kv k8v4 --vram-reserve-mib 64 --mtp on --spec 3
```

### 4.6 Check the two flags that matter

```powershell
<install>\strata\engine-cuda12\strata.exe --help | findstr /C:"mtp-cpu-moe"
<install>\strata\engine-cuda12\strata.exe --help | findstr /C:"dry-multiplier"
```

Both lines must appear. A binary built from upstream **without** these patches prints nothing.

---

## 5. Install (build or modify it yourself)

### 5.1 Build

```bash
# 1. upstream, at the commit these patches are written against
git clone https://github.com/Niko1221/Strata
cd Strata && git checkout cd1daa4e          # "Merge upstream/main (0.1.43) into qwen36-35b-support"

# 2. the patches
git am /path/to/TinyStrata/patches/*.patch

# 3. build the engine (upstream's own script; CUDA 12.8, sm_86)
cmd /c build-strata-cuda12.bat
cp build-cuda12/strata.exe engine-cuda12/strata.exe

# 4. one-time: build the pack from the GGUF
python setup.py --family qwen36 --model UD-IQ3_S
```

> **Deployment trap you must know**: `cmake --build` writes only `build-cuda12/strata.exe`, while
> the runtime reads `engine-cuda12/strata.exe` — **without the `cp` nothing changed**.

### 5.2 Changing the code

Every change is small and commented: `src/core/mtp.cpp` (expert offload),
`sampler.hpp` / `sampler.cu` (the DRY kernel), `src/program/generate.cpp` (flags),
`serve/` (autosave, log timestamps). Re-export the patches with:

```bash
cd <install>/strata
git format-patch -q cd1daa4e..HEAD -o /path/to/TinyStrata/patches --no-signature
```

### 5.3 Layout

Default layout (pick any folder name; `<install>` is where the launcher and the driver live):

```
<install>\
├── strata\                     upstream checkout, engine in strata\engine-cuda12\strata.exe
├── tools\strata-run.py         the driver (its parent is <install>)
├── configs\strata-qwen36-iq3s.example.json   copy to strata-qwen36-iq3s.json
├── results\                    logs land here
└── sessions\                   autosave .sess files (set "slot_save_path")

<models>\Qwen3.6-35B-A3B-MTP-GGUF\           the GGUF (+ mmproj-F32.gguf for images)
<packs>\qwen36-UD-IQ3_S\                    the pack setup.py builds
```

This layout is a **default, not a hard-coded path**. Three ways to move things:

| Knob | What it does |
|---|---|
| env `STRATA_HOME` | the whole `<install>` root (config, logs, sessions follow) |
| env `STRATA_ROOT` | the upstream checkout only (default `<install>\strata`) |
| launcher menu "About -> Open engine folder" / the "Browse..." prompt | pick once, remembered in `strata-launcher.ini` |

`<models>` / `<packs>` live in the config template as `%STRATA_MODELS%` / `%STRATA_PACKS%`
placeholders (see `configs/README.md`).

---

## 6. Upstream and what the patches change

**TinyStrata is a derivative work of [Strata](https://github.com/Niko1221/Strata)** (MIT,
Copyright (c) 2026 Niko1221 and the Strata contributors). `LICENSE` is upstream's, unchanged;
see [`NOTICE.md`](NOTICE.md) for the exact baseline and the disclaimer.

| | |
|---|---|
| Upstream | <https://github.com/Niko1221/Strata> |
| Baseline of these patches | `cd1daa4e` — "Merge upstream/main (0.1.43) into qwen36-35b-support" |
| Branch the baseline came from | `aflin/Strata`, `qwen36-35b-support` (PR #1402: Qwen3.6-35B-A3B support) |

### 6.1 The three patches

| Patch | Touches | Effect (measured on 4 GB) |
|---|---|---|
| [`0001-mtp-mtp-cpu-moe`](patches/0001-mtp-mtp-cpu-moe-the-draft-layer-s-256-experts-on-the.patch) | `src/core/mtp.cpp`, `src/program/generate.cpp`: adds `--mtp-cpu-moe` — draft experts on the CPU, graph capture skipped | draft layer **439 → 127 MiB**; decode 24.7 tok/s @65 K (87 % accepted), 18.6–21.5 tok/s @80 K |
| [`0002-sampler-DRY`](patches/0002-sampler-DRY-a-penalty-that-grows-with-the-length-of-.patch) | `sampler.hpp` / `sampler.cu` / `generate.cpp`: DRY pre-pass kernel + four `--dry-*` flags, covering greedy / sampled / split-merge | coding prompt: off = 2,529 tokens of thinking and **not one token of answer**; `--dry-multiplier 1.5` = 1,737 tokens + the correct function |
| [`0003-serve-setup-tools`](patches/0003-serve-setup-tools-session-autosave-log-timestamps-ch.patch) | `serve/autosave.py` (new), `serve/server.py`, `setup.py`, `tools/strata_inspect.py`: session autosave, log timestamps, `--chat-template-file`, wider quant list | 52 K-token restore in **0.47 s** (vs 314 s); save 380 ms / restore 143 ms; `--expert-cache 800` makes prefill 27–45 % faster |

The patches are authored as `strata-4gb <strata-4gb@localhost>`; after applying, run
`git commit --amend --reset-author` to put your own name on them.

---

## 7. Supported models

| Model | Quant | Size | Note |
|---|---|---|---|
| [**unsloth/Qwen3.6-35B-A3B-MTP-GGUF**](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF) | **UD-IQ3_S** | 15.3 GB | **Every number in this repo comes from it.** Recommended |
| same | UD-IQ4_XS | 18.2 GB | Fits 4 GB too; slightly slower prefill, slightly better quality |
| same | `mmproj-F32.gguf` | — | Only needed for image input (vision) |

- In China, swap the host for `hf-mirror.com` (`HF_ENDPOINT=https://hf-mirror.com`).
- **The MTP layer must be inside the GGUF** (`blk.40`). Before downloading another quant or another
  uploader, run the three-step check in
  [`docs/GGUF-SELECTION-STANDARD.md`](docs/GGUF-SELECTION-STANDARD.md): `qwen35moe` +
  `block_count 41` + an MTP-named file / `strata_inspect.py` printing `with an MTP layer`.
- Model licence: this Unsloth GGUF is Apache-2.0. Weights are not part of this repository.

---

## 8. Documentation

| Document | Contents |
|---|---|
| [`docs/4GB-TUNING.md`](docs/4GB-TUNING.md) | The full 4 GB tuning log: why each parameter has its value, the measurement protocol (warm-up → interleaved → median of 3) and the noise floor (instance-to-instance ±6 %) |
| [`docs/GGUF-SELECTION-STANDARD.md`](docs/GGUF-SELECTION-STANDARD.md) | Hard requirements for picking a GGUF, red flags, the three-step filter |
| [`launcher/strata-launcher.ahk`](launcher/strata-launcher.ahk) | The GUI launcher (AHK v2, ships `--selftest` / `--guismoke` / `--switchtest`) |
| [`tools/strata-run.py`](tools/strata-run.py) | Mode driver: one command per mode, boundary checks, logs |
| [`tools/watch-loop.py`](tools/watch-loop.py) | Two-source loop monitor: engine log (`LOOP-RECOVERY` / `DEGEN-TOKEN` / `THINK-ONLY`) and the client's session file (repeated tool calls, verbatim repeated reasoning) |
| [`tools/ab-modes.py`](tools/ab-modes.py) · [`tools/ab-prefill-fast.py`](tools/ab-prefill-fast.py) | A/B benchmarks: warm-up + interleaved + median of 3; prefill from the progress line in 45 s |

---

## 9. Everything else

### 9.1 Limits (read this before filing anything)

- **Decode falls with context**: 25 tok/s at 30 K, 18 at 79 K on this card.
- **Client-side compaction is a hard boundary** for prefix reuse: a compacted conversation re-reads
  its whole prompt once (~2 min at 37 K tokens here). Every engine that matches token prefixes has
  this.
- **Tool-call loops are a harness problem, not a sampler problem.** A model that repeats the same
  `read` call 77 times is not fixed by temperature, DRY or a quant change — it needs a guard in the
  client (`tools/watch-loop.py` detects both kinds).
- **K-quants are not free here**: `Q4_K*`/`Q5_K*`/`Q6_K` need a build with
  `-DSTRATA_MMQ_KQUANTS=ON` for the prompt path, and every added kernel instance is loaded eagerly,
  costing VRAM for *every* model on a 4 GB card. `Q2_K`/`Q3_K` are not covered by that option at all.
- **Single GPU, single request.** `--batch`, layer splits and peer devices do not combine with
  these patches (the session files refuse them too).

### 9.2 Licence

**MIT**, as upstream. `LICENSE` is upstream's text; `patches/` are our changes to MIT code and are
MIT as well. Model weights are not part of this repository and keep their own licence (Apache-2.0).

This project is not affiliated with or endorsed by the Strata authors.

### 9.3 Reporting

When opening an issue, include: the full `strata-run.py` command line, the
`--max-context` / KV / MTP settings, and the tail of the matching log in `results/`
(the timestamps let us align things directly).
