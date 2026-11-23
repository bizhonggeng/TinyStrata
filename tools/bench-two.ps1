# bench-two.ps1 - generic 2+-config server benchmark for an arbitrary llama.cpp bin dir
# NOTE: -File cannot bind arrays -> pass lists as comma strings
param(
    [string]$BinDir = 'D:\dev\llama-cpp-moe-cache\dist-avx2',
    [string]$Label = 'avx2',
    [string]$ConfigList = 'none',
    [int]$Threads = 8,
    [int]$Runs = 3,
    [int]$NPredict = 128,
    [int]$Ctx = 4096,
    [int]$Port = 1342,
    [int]$IdleSeconds = 20
)
$ErrorActionPreference = 'Continue'
$model = 'E:\models\AesSedai\Qwen3.6-35B-A3B-GGUF\Qwen3.6-35B-A3B-Q4_K_M-00001-of-00002.gguf'
$out   = 'D:\dev\results'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$para = 'The MoE expert cache keeps the most recently used expert weight blocks of a mixture-of-experts model resident in device memory, so that decode steps which route to those experts avoid re-uploading them from host memory across the PCIe bus. '
$prompt = ($para * 20).Trim()
function VramUsed { try { (nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -join ',' } catch { 'n/a' } }

function Get-Cfg($name) {
    if ($name -like 'cache*') {
        return @('--load-mode', 'none', '--moe-expert-cache', '9999', '--moe-expert-cache-budget', $name.Substring(5))
    }
    switch ($name) {
        'none'    { return @('--load-mode', 'none') }
        'mmap'    { return @('--load-mode', 'mmap') }
        'opoff'   { return @('--load-mode', 'none') }                                  # op-offload is default ON
        'noopoff' { return @('--load-mode', 'none', '--no-op-offload') }
        default   { throw "unknown config $name" }
    }
}

$rows = @()
foreach ($cfg in @($ConfigList.Split(',') | ForEach-Object { $_.Trim() })) {
    $extra = Get-Cfg $cfg
    $slog  = "$out\bg-$Label-$cfg.log"
    Write-Host "########## label=$Label config=$cfg ##########"
    $args = @('-m', $model, '-ngl', '999', '-ncmoe', '999', '-c', "$Ctx", '-ub', '512',
              '-ctk', 'q8_0', '-ctv', 'q8_0', '-fa', 'on', '-t', "$Threads",
              '--host', '127.0.0.1', '--port', "$Port", '-np', '1') + $extra
    $p = Start-Process -FilePath "$BinDir\llama-server.exe" -ArgumentList $args `
        -RedirectStandardOutput $slog -RedirectStandardError "$slog.err" -PassThru -WindowStyle Hidden
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 3
        try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5 -UseBasicParsing).StatusCode -eq 200) { $ready = $true; break } } catch { }
        if ($p.HasExited) { break }
    }
    if (-not $ready) {
        Write-Host "  NOT READY (label=$Label cfg=$cfg) - see $slog.err"
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        Start-Sleep -Seconds 10; continue
    }
    $vram = VramUsed
    $body = @{ prompt = $prompt; n_predict = $NPredict; temperature = 0.0; top_k = 1; seed = 1234; cache_prompt = $false } | ConvertTo-Json
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1800 | Out-Null } catch { }
    for ($i = 1; $i -le $Runs; $i++) {
        try {
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1800
            $rows += [pscustomobject]@{ label = $Label; config = $cfg; run = $i; vram_mib = $vram
                pp_tps = [math]::Round($r.timings.prompt_per_second, 2)
                tg_tps = [math]::Round($r.timings.predicted_per_second, 2) }
            Write-Host ("  run {0} => pp={1:N2} tg={2:N2} t/s (vram {3} MiB)" -f $i, $r.timings.prompt_per_second, $r.timings.predicted_per_second, $vram)
        } catch { Write-Host "  run $i FAILED: $_" }
        Start-Sleep -Seconds $IdleSeconds
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Start-Sleep -Seconds 10
}
Write-Host ''
$rows | Format-Table -AutoSize
$sum = $rows | Group-Object label, config | ForEach-Object {
    $g = $_.Group; $t = ($g.tg_tps | Sort-Object); $q = ($g.pp_tps | Sort-Object)
    [pscustomobject]@{ label = $g[0].label; config = $g[0].config; vram_mib = $g[0].vram_mib
        tg_med = if ($t.Count) { $t[[int][math]::Floor($t.Count/2)] } else { $null }
        pp_med = if ($q.Count) { $q[[int][math]::Floor($q.Count/2)] } else { $null }; n = $t.Count }
}
$sum | Format-Table -AutoSize
$rows | Export-Csv "$out\bench-matrix-$Label-runs.csv" -NoTypeInformation -Encoding utf8
$sum | ConvertTo-Json -Depth 3 | Out-File "$out\bench-matrix-$Label-summary.json" -Encoding utf8
