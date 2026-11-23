# Tuning notes for a 4 GB card

Every number below was measured on **RTX 3050 Ti Laptop (4 GB, sm_86) + i5-11400H (6C/12T,
AVX-512) + 32 GB DDR4-3200**, Windows 11, engine 0.1.43 + TinyStrata's patches,
model `Qwen3.6-35B-A3B-UD-IQ3_S` (15.34 GB, 3.46 bit/weight overall, 3.20 bit/weight for the
routed experts), tokenizer/pack from upstream's `setup.py`.

## Measure like this, or you will measure nothing

Run-to-run noise on this machine is **±6 % between engine instances** (±2 % within one). A 3 %
"win" measured once is noise.

1. **Warm up first.** The first request after a start is 20–35 % slower (cold page cache, the
   adaptive expert tier still learning). Never take the first number.
2. **Median of three** decode runs inside one engine instance (the prompt is cached by then, so
   each costs ~20 s).
3. **Interleave the arms** (A, B, A, B) and restart the engine for each arm.
4. To resolve a 3 % difference you need **8–10 engine instances per arm**. Below that, treat it
   as noise and move on.

## The two modes

| | short | long |
|---|---|---|
| `--max-context` | 20480 | 81920 |
| KV | `k8v4`, resident | `k8v4`, resident (`--kv-resident 0`) |
| MTP | on, experts on GPU, `--spec 3` | on, experts on CPU, `--mtp-cpu-moe 1 --spec 2` |
| `--vram-reserve-mib` | 64 | 64 |
| measured ceiling | **39936** starts / 40960 refused | **81920** starts / 90112 refused |
| decode | 32–36 tok/s | 18 tok/s @79 K, 25 tok/s @30 K |
| prefill | ~250 tok/s | 153.8 tok/s @79 K |

The ceilings come from VRAM accounting, not from the model: past them the engine refuses with
`no VRAM is left for the expert cache: it needs at least 287 slots`.

## `--expert-cache` is an upper bound, not a hint

`--expert-cache N` caps the slot count; the engine fills what fits below it. Setting it too low
costs **prefill**, and prefill is the expensive half of a long context:

| `--expert-cache` | slots filled | prefill (52,066-token prompt) | decode |
|---|---:|---:|---:|
| 300 | 422 | **359 s** (145 tok/s) | 19.6 |
| 800 | 452 | **263 s** (198 tok/s) | 18.6 |

+27 % prefill (+45 % at a 64 K context: 343 s → 236 s) for no decode change. Use 800 and let the
engine clamp.

## Decode falls with context (this is the whole curve)

| context | decode |
|---:|---:|
| 12 K | 32–34 tok/s |
| 25 K | ~27 tok/s |
| 30 K | ~25 tok/s |
| 41 K | 22.9 tok/s |
| 52 K | 19.6 tok/s |
| 65 K | 17.0 tok/s |
| **79 K** | **18.0 tok/s** (median of 3, 153.8 tok/s prefill) |

Decode also depends on draft acceptance, which depends on the text: `decode ≈ 1 / (window cost /
(1 + spec × acceptance))`. The same configuration measured 24.7 tok/s at one point and 20.4 at
another purely because the generated text was easier or harder to draft. **A recorded decode
number without its acceptance rate is not a measurement.**

## KV: `k8v4`, resident, and nothing fancier

`k8v4` costs ~10.7 KiB/token → ~856 MiB at 80 K. Alternatives measured here:

- `--kv-grow` (KV takes only the cells reached): **+8 % at 41 K, 0 % at 73 K** — and it interacts
  badly with parked conversations (their cells get trimmed), so it is off.
- KV streaming (`--kv-resident N`): much worse than resident on this card, because the read path
  then competes with expert streaming for the same PCIe link.

## MTP: depth 2, experts on the CPU for long context

| draft window | decode @80 K | acceptance |
|---|---:|---:|
| `--spec 3` | 21.20 | 85.4 % |
| `--spec 2` | 21.40 | 88.0 % |

Depth 2 wins at long context (smaller window → higher acceptance → fewer wasted verifications);
depth 3 wins at short context. That is why the two modes differ.

`--mtp-cpu-moe` is what makes 80 K + MTP possible at all: the draft layer's VRAM goes from 439 to
127 MiB. The CPU path runs the draft experts with the AVX-512 kernels and skips CUDA graph
capture.

## What did *not* help (so you do not repeat it)

| Try | Result |
|---|---|
| `STRATA_ROUTE_RESIDENT` (residency-biased routing) | no reproducible gain at either mode (±6 % noise); it only reorders experts ranked 6–9 when the expert hit rate is ~33 % |
| `STRATA_ADAPT_LAG=2`, `STRATA_ADAPT_NOWAIT=1` (upstream's sm_86 defaults) | within noise |
| DFlash2 drafter (instruct, Qwen3.6 build exists) | equal to MTP at 32 K and 74 K; on the CPU 16 % slower; the Q4_K_M drafter does not fit at 80 K |
| `--lookup-chain 3` | −2.6 %, dropped |
| `-mno-gather` (PolyStrata's build flag) | this build already picks scalar lookups on a Tiger Lake CPU (no AVX-VNNI → gather judged slow) |
| bigger `--max-context` than 81920 | engine refuses (VRAM) |
| `--batch` / multiple slots | each slot's KV is fp32 (1.5 GB at 32 K for the qwen36 path) — not possible on 4 GB |

## Session cache: what actually survives a switch

- **Parked conversations** (`--conversation-cache-mib`) keep whole conversations in host RAM and
  come back in ~20 ms. `--conversation-cache-min-free-mib` defaults to 2560 MiB, which on a 32 GB
  machine under load means **parking silently never happens** (`skip parking (...) 1687 MiB
  available`). 512 works here.
- **Session files** (`--slot-save-path`, and `serve/autosave.py` in this repository) write the KV
  to disk: a 52 K-token conversation is 588 MiB and restores in **0.47 s** against 314 s of
  re-reading. Use them when the engine restarts, or when parking ran out of RAM.
- **Compaction is a hard boundary.** A client that rewrites its history (pi's compaction replaces
  the middle with a summary) changes the token sequence, so no prefix matches and the whole prompt
  is read again — 144 s for 23,883 tokens here. Nothing in the engine can reuse a rewritten
  history.

## Reference: this build vs llama.cpp at 79 K

Same prompt (79,168 tokens), same machine, both with MTP, experts on the CPU:

| | this build (UD-IQ3_S, 3.46 bit/w, k8v4) | llama.cpp b11382 (Q4_K_M, 5.19 bit/w, q8_0 KV) |
|---|---:|---:|
| prefill | **153.8 tok/s** | 103.3 tok/s |
| decode (median of 3) | **18.00 tok/s** | 12.35 tok/s |
| drafts accepted | 71–78 % | 65–78 % |

llama.cpp's parameters were the ones LM Studio used for the same run
(`-ngl 999 -ncmoe 999 -c 80128 -ub 512 -ctk/-ctv q8_0 -fa on -t 6 --spec-type draft-mtp`), and its
prefill reproduced LM Studio's own log (101–104 tok/s).
