# NOTICE

**TinyStrata** is a **derivative work of Strata, MIT licensed**, Copyright (c) 2026 Niko1221 and the
Strata contributors (`LICENSE` is upstream's, unchanged).

| | |
|---|---|
| Upstream | https://github.com/Niko1221/Strata |
| Baseline of these patches | `cd1daa4e2291f2705a0bf23976233608cf2631cf` — "Merge upstream/main (0.1.43) into qwen36-35b-support" |
| Branch the baseline came from | `aflin/Strata`, `qwen36-35b-support` (PR #1402: Qwen3.6-35B-A3B support) |
| What this repository adds | 3 patches under `patches/` (~430 lines), plus the launcher, driver, benchmarks and notes |

The name says what it is: a small target (4 GB of VRAM) on top of Strata, not a fork of the
whole engine. It is not affiliated with or endorsed by the upstream authors.

Nothing in this repository is a model, a pack, a binary or a dataset: the model files are
Unsloth's (`Qwen3.6-35B-A3B-MTP-GGUF`, Apache-2.0) and are downloaded by the user's own
`setup.py` run. `LICENSE` covers the source code only.

Our patches are authored as `strata-4gb <strata-4gb@localhost>`; re-author them with
`git commit --amend --reset-author` after applying if you want your own identity on them.
