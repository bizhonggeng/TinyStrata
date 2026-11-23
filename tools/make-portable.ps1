# Assemble the portable TinyStrata tree under D:\dev\scratch\portable\TinyStrata
# (the zip is built from there).  Layout = what the launcher's Locate() expects.
$ErrorActionPreference = "Stop"
$root     = "D:\dev\scratch\portable\TinyStrata"
$checkout = "D:\dev\strata"
$dist     = "D:\dev\dist\TinyStrata"
$venv     = "D:\dev\strata\.venv\Lib\site-packages"

if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force -Path `
    "$root\strata\engine-cuda12", "$root\strata\serve", "$root\strata\tools", "$root\strata\data", `
    "$root\tools", "$root\configs", "$root\results", "$root\sessions" | Out-Null

Write-Host "[--] python + numpy + psutil"
Copy-Item -Recurse "D:\dev\scratch\portable\python" "$root\python"
foreach ($m in @("numpy", "numpy.libs", "psutil", "jinja2", "markupsafe", "gguf", "yaml", "pyaml", "regex")) {
    $src = Join-Path $venv $m
    $dst = Join-Path "$root\python\Lib\site-packages" $m
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
    if (Test-Path $src) { Copy-Item -Recurse $src $dst }
}

Write-Host "[--] engine"
Copy-Item "$checkout\engine-cuda12\strata.exe" "$root\strata\engine-cuda12\strata.exe"

Write-Host "[--] serve/ (with the web UI: web/, chat_template.jinja, ...)"
Copy-Item -Recurse "$checkout\serve\*" "$root\strata\serve\" -Exclude "__pycache__", "test_*.py"
Get-ChildItem "$root\strata\serve" -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force

Write-Host "[--] tools/ (only what the server and the pack builder need)"
foreach ($f in @("iq_pack.py", "make_pack.py", "gguf_reader.py", "strata_tokenizer.py", "pack_index.py", "strata_inspect.py")) {
    $src = Join-Path "$checkout\tools" $f
    if (Test-Path $src) { Copy-Item $src "$root\strata\tools\" }
}

Write-Host "[--] data/ (expert profile + draft vocab)"
foreach ($f in @("expert-profile-qwen36.bin", "draft_vocab_en.bin")) {
    Copy-Item (Join-Path "$checkout\data" $f) "$root\strata\data\"
}

Write-Host "[--] driver + guard"
Copy-Item "D:\dev\tools\strata-run.py" "$root\tools\strata-run.py"
if (Test-Path "D:\dev\tools\strata-ram-guard.py") { Copy-Item "D:\dev\tools\strata-ram-guard.py" "$root\tools\" }

Write-Host "[--] launcher"
Copy-Item "$dist\dist\TinyStrata-Launcher.exe" "$root\"

Write-Host "[--] docs + configs"
foreach ($f in @("README.zh-CN.md", "README.md", "NOTICE.md", "LICENSE")) {
    Copy-Item (Join-Path $dist $f) (Join-Path $root $f)
}
Copy-Item -Recurse "$dist\configs\*" "$root\configs\"
Copy-Item "$dist\configs\strata-qwen36-iq3s.example.json" "$root\strata-qwen36-iq3s.json"

@'
TinyStrata portable - first run
===============================

1. Double-click TinyStrata-Launcher.exe
2. Model -> Browse... and pick your GGUF (e.g. Qwen3.6-35B-A3B-UD-IQ3_S.gguf).
   The pack it needs is built on the first start (~3 s) under ..\packs\.
3. Press Start.  The web chat link appears once the engine is up.

No Python and no AutoHotkey installation is needed: python\ holds an embedded
CPython 3.11 with numpy, and the launcher is a compiled exe.

The template strata-qwen36-iq3s.json still contains %STRATA_MODELS% style
placeholders for the paths the launcher does not ask about (pack, tokenizer,
expert profile, mtp draft vocab).  The server fills the pack and the tokenizer
and falls back to <install>\strata\data for the profile/vocab; if the engine
still complains about a path, set the variables listed in configs\README.md or
edit strata-qwen36-iq3s.json (plain JSON).

Logs: results\*.log
'@ | Set-Content -Path "$root\FIRST-RUN.txt" -Encoding UTF8

$files = Get-ChildItem $root -Recurse -File
$bytes = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host ("[ok] {0} files, {1:N1} MB in {2}" -f $files.Count, ($bytes / 1MB), $root)
