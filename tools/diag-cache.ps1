# diag-cache.ps1 - is the MoE cache actually allocated? (VRAM delta + full log)
param(
    [string]$Tag = 'avx2',
    [int]$Budget = 2458,
    [int]$Slots = 9999,
    [int]$Port = 1339,
    [string]$LoadMode = 'none',   # none = old --no-mmap, mlock = old --no-mmap --mlock
    [int]$Lv = 5,                 # verbosity: this tree hides src/ INFO lines below ~5
    [switch]$NoCache
)
$ErrorActionPreference = 'Continue'
$bin   = "D:\dev\llama-cpp-moe-cache\dist-$Tag"
$model = 'E:\models\AesSedai\Qwen3.6-35B-A3B-GGUF\Qwen3.6-35B-A3B-Q4_K_M-00001-of-00002.gguf'
$out   = 'D:\dev\results'
$name  = if ($NoCache) { 'nocache' } else { "budget$Budget" }
$slog  = "$out\diag-$name.log"

function Vram { (nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader) -join ' | ' }

$args = @('-m', $model, '-ngl', '999', '-ncmoe', '999', '-c', '4096', '-ub', '512',
          '-ctk', 'q8_0', '-ctv', 'q8_0', '-fa', 'on', '-t', '8', '--load-mode', $LoadMode, '-lv', "$Lv",
          '--host', '127.0.0.1', '--port', "$Port", '-np', '1')
if (-not $NoCache) {
    $args += @('--moe-expert-cache', "$Slots", '--moe-expert-cache-budget', "$Budget")
}
Write-Host "VRAM before: $(Vram)"
$p = Start-Process -FilePath "$bin\llama-server.exe" -ArgumentList $args `
    -RedirectStandardOutput "$slog" -RedirectStandardError "$slog.err" -PassThru -WindowStyle Hidden

$ready = $false
for ($i = 0; $i -lt 100; $i++) {
    Start-Sleep -Seconds 3
    try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5 -UseBasicParsing).StatusCode -eq 200) { $ready = $true; break } } catch { }
    if ($p.HasExited) { Write-Host "server exited early"; break }
}
Write-Host "ready=$ready  pid=$($p.Id)"
Write-Host "VRAM with model loaded: $(Vram)"

if ($ready) {
    $body = @{ prompt = 'The quick brown fox'; n_predict = 64; temperature = 0.0; top_k = 1; seed = 7; cache_prompt = $false } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900
    Write-Host ("tg = {0:N2} t/s   pp = {1:N2} t/s" -f $r.timings.predicted_per_second, $r.timings.prompt_per_second)
    Write-Host "VRAM in use: $(Vram)"
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Start-Sleep -Seconds 5
Write-Host '=== log: moe/cache/slot/VRAM lines ==='
Get-Content "$slog.err" -ErrorAction SilentlyContinue |
    Select-String -Pattern 'moecache|moe-cache|slots|floor|budget|CUDA|buffer|VRAM|alloc|error|fail' |
    ForEach-Object { $_.Line }
