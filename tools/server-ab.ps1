# server-ab.ps1 - A/B via llama-server /completion timings (llama-bench cannot pass the cache flag)
# configs: mmap (baseline) | nommap (--load-mode none) | cache (none + --moe-expert-cache-budget)
param(
    [string]$Tag = 'avx2',
    [int]$Budget = 2458,
    [int]$Threads = 8,
    [int]$Runs = 3,
    [int]$NPredict = 128,
    [int]$Port = 1338,
    [string[]]$Configs = @('mmap', 'nommap', 'cache1536', 'cache2048', 'cache2458'),
    [int]$Lv = 3,           # keep default verbosity for the timed runs (no debug-log overhead)
    [switch]$LongRun        # NPredict=600 to surface the per-512-step hit-rate line
)
$ErrorActionPreference = 'Continue'
$bin   = "D:\dev\llama-cpp-moe-cache\dist-$Tag"
$model = 'E:\models\AesSedai\Qwen3.6-35B-A3B-GGUF\Qwen3.6-35B-A3B-Q4_K_M-00001-of-00002.gguf'
$out   = 'D:\dev\results'
New-Item -ItemType Directory -Force -Path $out | Out-Null
if ($LongRun) { $NPredict = 600 }

# fixed ~500-token prompt, same for every run
$para = 'The MoE expert cache keeps the most recently used expert weight blocks of a mixture-of-experts model resident in device memory, so that decode steps which route to those experts avoid re-uploading them from host memory across the PCIe bus. '
$prompt = ($para * 20).Trim()

function Get-ConfigArgs($name) {
    if ($name -like 'cache*') {
        $b = $name.Substring(5)
        return @('--load-mode', 'none', '--moe-expert-cache', '9999', '--moe-expert-cache-budget', $b)
    }
    switch ($name) {
        'mmap'   { return @('--load-mode', 'mmap') }
        'nommap' { return @('--load-mode', 'none') }
        'mlock'  { return @('--load-mode', 'mlock') }
        default  { throw "unknown config $name" }
    }
}

$rows = @()
foreach ($cfg in $Configs) {
    $extra = Get-ConfigArgs $cfg
    $slog  = "$out\server-$Tag-$cfg.log"
    Write-Host "########## config=$cfg  log=$slog ##########"
    $args = @('-m', $model, '-ngl', '999', '-ncmoe', '999', '-c', '4096', '-ub', '512',
              '-ctk', 'q8_0', '-ctv', 'q8_0', '-fa', 'on', '-t', "$Threads",
              '--host', '127.0.0.1', '--port', "$Port", '-np', '1', '-lv', "$Lv") + $extra
    $p = Start-Process -FilePath "$bin\llama-server.exe" -ArgumentList $args `
        -RedirectStandardOutput $slog -RedirectStandardError "$slog.err" -PassThru -WindowStyle Hidden
    Write-Host "server pid=$($p.Id) - waiting for /health ..."
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 3
        try {
            $h = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5 -UseBasicParsing
            if ($h.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
        if ($p.HasExited) { Write-Host "server exited early (code $($p.ExitCode))"; break }
    }
    if (-not $ready) { Write-Host "NOT READY - skipping config $cfg"; if (-not $p.HasExited) { $p.Kill() }; continue }

    $body = @{ prompt = $prompt; n_predict = $NPredict; temperature = 0.0; top_k = 1;
               seed = 1234; cache_prompt = $false } | ConvertTo-Json
    # warmup (not measured)
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900 | Out-Null } catch { Write-Host "warmup failed: $_" }

    for ($i = 1; $i -le $Runs; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900
            $sw.Stop()
            $rows += [pscustomobject]@{
                config = $cfg; run = $i
                prompt_n = $r.timings.prompt_n
                pp_tps   = [math]::Round($r.timings.prompt_per_second, 2)
                tg_tps   = [math]::Round($r.timings.predicted_per_second, 2)
                measured = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            }
            Write-Host ("    run $i => pp_n={0} pp={1} t/s tg={2} t/s" -f $r.timings.prompt_n, $r.timings.prompt_per_second, $r.timings.predicted_per_second)
        } catch { Write-Host "    run $i FAILED: $_" }
        Start-Sleep -Seconds 30
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 10
}
Write-Host ''
$rows | Format-Table -AutoSize
$summary = $rows | Group-Object config | ForEach-Object {
    $tgs = ($_.Group.tg_tps | Sort-Object)
    $pps = ($_.Group.pp_tps | Sort-Object)
    [pscustomobject]@{
        config   = $_.Name
        tg_med   = if ($tgs.Count) { $tgs[[int][math]::Floor($tgs.Count / 2)] } else { $null }
        pp_med   = if ($pps.Count) { $pps[[int][math]::Floor($pps.Count / 2)] } else { $null }
        n        = $tgs.Count
    }
}
$summary | Format-Table -AutoSize
$rows | Export-Csv "$out\server-ab-$Tag-runs.csv" -NoTypeInformation -Encoding utf8
$summary | ConvertTo-Json -Depth 3 | Out-File "$out\server-ab-$Tag-summary.json" -Encoding utf8
Write-Host '--- moecache evidence from server logs ---'
foreach ($cfg in $Configs) {
    $slog = "$out\server-$Tag-$cfg.log"
    if (Test-Path $slog) {
        Select-String -Path $slog -Pattern 'moecache|moe-cache|slots|floor' | ForEach-Object { "[$cfg] " + $_.Line }
    }
}
