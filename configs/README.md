# configs/

`strata-qwen36-iq3s.example.json` is a **template**, not a runnable config: every path is written as
an environment variable placeholder, so nothing in this repository points at somebody's disk.

Copy it next to your install and either edit the paths or set the variables:

| Placeholder | Meaning | Example value |
|---|---|---|
| `%STRATA_HOME%` | your install dir (config, logs, sessions) | `C:\TinyStrata` |
| `%STRATA_ROOT%` | the Strata checkout / engine dir | `C:\TinyStrata\strata` |
| `%STRATA_PACKS%` | where `setup.py` writes packs | `C:\TinyStrata-data\packs` |
| `%STRATA_MODELS%` | where the GGUF files live | `D:\models\unsloth` |
| `%CUDA_BIN%` | CUDA 12.x `bin` dir | `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8\bin` |

```powershell
$env:STRATA_HOME   = "C:\TinyStrata"
$env:STRATA_ROOT   = "C:\TinyStrata\strata"
$env:STRATA_PACKS  = "C:\TinyStrata-data\packs"
$env:STRATA_MODELS = "D:\models\unsloth"
$env:CUDA_BIN      = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8\bin"

copy configs\strata-qwen36-iq3s.example.json C:\TinyStrata\strata-qwen36-iq3s.json
python tools\strata-run.py --check
```

`tools/strata-run.py` expands `%VAR%` and `$VAR` when it loads the file, and it also accepts
`--base <file>`. Paths inside a *pack* (written by `setup.py`) are not affected.
