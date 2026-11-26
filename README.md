# TinyStrata

Runs **Qwen3.6-35B-A3B (MoE, 3B active) on a 4 GB laptop GPU** at 33–43 tok/s, on Windows,
with the whole model on one card plus the host's RAM. It is a patched build of
[Strata](https://github.com/Niko1221/Strata) (MIT) and a launcher for it.

Every number below was measured on the machine in §2. Nothing here is extrapolated.

## 1. What is in the box

| Piece | What it is |
|---|---|
| `strata.exe` | Strata 0.1.43 + 10 patches (§5). 64,747,008 B, `sha256 8b01900e…` |
| `TinyStrata-Launcher.exe` | GUI: pick a GGUF, press Start. 1,504,768 B, not UPX-packed |
| `strata/ctl/` | Middle layer: parameter derivation, VRAM ceiling/suggestion, preflight codes, log parsing |
| `patches/` | The 10 patches as `git am`-able files |

## 2. Measured performance

Machine: **RTX 3050 Ti Laptop (4 GB VRAM)**, i5-11400H, 32 GB RAM, Windows 11,
CUDA 12.8, display 1920×1080 @125 %.
Model: **Qwen3.6-35B-A3B UD-IQ3_S** (14.29 GiB) with its own MTP head.
Settings: `--kv k8v4`, `--spec 3`, `--expert-cache 800`, `--vram-reserve-mib 64`,
`--max-context 20480`, MTP experts in VRAM.

### Decode speed vs. context

Each point: engine loaded once, GPU idle (0 MiB used) before starting, one warm-up
request discarded, then **3 generations of 250 tokens, median shown**.

| prompt | 1 K | 4 K | 8 K | 12 K | 16 K | 20 K |
|---|---:|---:|---:|---:|---:|---:|
| decode tok/s | **43.1** | 40.9 | 40.0 | 38.8 | 37.0 | 33.7 |

- 1 K → 20 K costs **−22 %** (43.1 → 33.7). The slope is about −0.5 tok/s per 1 K past 4 K.
- Prefill measured on the same runs: **350 tok/s** for a fresh ~4 K prompt;
  224 tok/s for a ~19.6 K prompt that was 78 % prompt-cache hits.

### Expert slots (this is what "it got slow" usually means)

Measured from the engine's own log line `expert cache N slots` at `--max-context 20480`:

| MTP experts in | slots | GiB of VRAM |
|---|---:|---:|
| VRAM (`--mtp-cpu-moe 0`, default short mode) | **657** | 0.77 |
| host RAM (`--mtp-cpu-moe 1`) | **915** | 1.07 |

At 1 K–20 K these two are **within ±5 % of each other** (43.1 vs 43.5, 40.0 vs 39.4,
33.7 vs 34.9 tok/s), so the extra 258 slots do not buy decode speed — they buy
head-room for a larger `--max-context`.

If decode drops to single digits, the slots are gone: a leftover engine or another
program holding the card is the usual cause. Check `nvidia-smi --query-gpu=memory.used`.

### Other measured numbers

| What | Value | How |
|---|---|---|
| Launcher preflight (all checks) | **1.2 s** | timed around `Preflight()` on a clean machine |
| Engine start → HTTP ready | ~15 s | time from Start to `/props` answering |
| VRAM ceiling for this model+card | 109,568 ctx | launcher's boundary line, from `serve/prepare.py` |
| Suggested ctx (keeps ~400 slots) | 16,384 | same line, `ctx_suggested` |
| Expert cache per slot | 1.229 MiB | 12.0 GiB experts ÷ 10,240 slots |
| Launcher self-test | 180 checks, 0 fail | `TinyStrata-Launcher.exe --selftest` |

## 3. Requirements

- **GPU**: compute capability 8.6 for the shipped binary (RTX 30-series). Other cards:
  build it yourself (§5) with your `-arch=sm_XX`, the launcher will use it.
- **CUDA 12.x runtime** (`cudart64_12.dll`, `cublas64_12.dll`); the config's `lib_dirs`
  points at `…\CUDA\v12.8\bin`.
- **RAM**: 16 GB minimum. 12.0 GiB is the expert set; below ~19 GB free the server
  switches to low-RAM mode by itself and decode falls to ~1/3 (measured 11.8 tok/s).
- **Windows 10/11 x64.** The portable bundle carries its own CPython 3.11.

## 4. Run it

1. Unzip the portable bundle; double-click `TinyStrata-Launcher.exe`.
2. **GGUF** → Browse… → your `Qwen3.6-35B-A3B-UD-IQ3_S.gguf`.
3. Press **Start**. First start builds the pack the engine needs from the GGUF
   (43.7 MiB zip; the 12 GiB of experts stay in the GGUF), which takes a few minutes;
   later starts reuse it.
4. The window shows the port; open `http://127.0.0.1:1339/` (or point any OpenAI-compatible
   client at `http://127.0.0.1:1339/v1`).

The launcher writes nothing outside its own folder. `--pro` opens the two-column view,
`--selftest` checks the install, `--preflight` prints what it would pass to the engine.

## 5. What the patches change

Ten patches against Strata 0.1.43, each with the measurement that motivated it:

1. `--mtp-cpu-moe` — the draft layer's 256 routed experts move to the host CPU pool:
   the MTP head drops from 439 MiB to 127 MiB of VRAM, which is what makes an 80 K
   context start at all on 4 GB.
2. DRY sampler — adds a repetition penalty that grows with the length of the match.
   Measured cost is inside the run-to-run spread (±3 % on this machine), and it removes
   the repeated-passage loops greedy sampling fell into before.
3. `serve/setup` tools, session autosave, log timestamps.
4. `serve` prepares the pack the engine needs (so a first start does not fail).
5. `serve` honours `sampling.dry_*` from the config (it was silently ignored).
6. `serve` fills the paths a template leaves as placeholders.
7. `strata pack <gguf> -X <out>` — the engine writes the pack itself (no Python, no numpy);
   its output is byte-identical to the Python packer (verified on IQ3_S).
8. `serve` checks that `--mtp` is the model actually being run (a mismatched draft head
   is the classic silent slowdown).
9. `serve` budgets host allocations from the model and the machine (experts, parked
   conversations, guard) instead of fixed numbers.
10. `strata/ctl` — the launcher's middle layer: `mtp_mode → --mtp/--mtp-cpu-moe/--spec`,
    the VRAM ceiling and suggested ctx from the capacity files, preflight warnings as
    codes, and runtime numbers parsed from the logs. Plus: `--kv-resident 0` means
    "all KV in VRAM" (the engine's default); the old code read 0 as "streaming".

## 6. Limits (measured, not guessed)

- **4 GB of VRAM is the constraint.** At `--max-context 20480` the expert cache gets
  657 slots; asking for much more shrinks it (109,568 ctx is where the engine refuses
  to start). The launcher prints the real ceiling and a suggestion that keeps ~400 slots.
- **Compute capability is baked in.** A card that is not sm_86 reports "no kernel image";
  build your own.
- **Long context is not free**: 20 K is 22 % slower than 1 K (table above).
- **The Windows binaries are unsigned.** The launcher is no longer UPX-packed (that
  was causing a `Trojan:Win32/Wacatac.B!ml` false positive), but unsigned executables
  can still be flagged; build from source if that matters.

## 7. Building it yourself

```bat
git clone https://github.com/Niko1221/Strata && cd Strata
git checkout <the commit these patches are against>
git am ..\TinyStrata\patches\*.patch
:: build with upstream's script (CUDA 12.8, -arch=sm_86)
```

Then point the launcher at your `strata.exe` (menu *About → Choose engine…*, remembered
in `strata-launcher.ini`).

## 8. Licence

Strata is MIT; this build keeps its `LICENSE`/`NOTICE.md`. The launcher and `strata/ctl`
are MIT as well. Model weights are **not** included — download them from
[unsloth/Qwen3.6-35B-A3B-MTP-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF).

中文说明见 [README.zh-CN.md](README.zh-CN.md)。
