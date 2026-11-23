<#
.SYNOPSIS
  一键编译启动器：先杀掉还在跑的实例（否则 Ahk2Exe 会弹"still running"警告），
  再编译，然后自动跑四套自检。

.EXAMPLE
  .\tools\build-launcher.ps1
.EXAMPLE
  .\tools\build-launcher.ps1 -NoTest         # 只编译
.EXAMPLE
  .\tools\build-launcher.ps1 -Upload         # 编译 + 自检 + 传到 Release v0.1.0
#>
[CmdletBinding()]
param(
    [string]$In     = "D:\dev\strata-launcher.ahk",
    [string]$Out    = "D:\dev\dist\TinyStrata\dist\TinyStrata-Launcher.exe",
    [string]$Base   = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe",
    [string]$Compiler = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe",
    [string]$Icon   = "",      # 空 = 自动在仓库根 assets\ 下找
    [string]$Tag    = "v0.1.0",
    [string]$Repo   = "bizhonggeng/TinyStrata",
    [switch]$NoTest,
    [switch]$Upload
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
$env:HTTP_PROXY  = $env:HTTPS_PROXY
$env:Path = "C:\Program Files\GitHub CLI;" + $env:Path

# 1) 杀掉还在跑的实例 —— 这是 "still running, needs to be unloaded" 的根因
foreach ($n in @("TinyStrata-Launcher", "AutoHotkey64")) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host ("[--] 结束 {0} 个 {1} 实例" -f @($p).Count, $n)
        $p | Stop-Process -Force
        Start-Sleep -Milliseconds 400
    }
}

# 2) 编译
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
Write-Host "[--] 编译 $In"
$extra = @()
if (-not $Icon) {
    $up = Split-Path $PSScriptRoot -Parent
    $cands = @((Join-Path $up "assets\icon.ico"),                    # 仓库布局：<root>/assets
               (Join-Path $up "dist\TinyStrata\assets\icon.ico"),   # 开发布局：<root>/dist/TinyStrata/assets
               (Join-Path $PSScriptRoot "assets\icon.ico"))
    foreach ($c in $cands) {
        if (Test-Path $c) { $Icon = $c; break }
    }
}
if ($Icon -and (Test-Path $Icon)) {
    $extra = @("/icon", $Icon)
    Write-Host "[--] 图标 $Icon"
} else {
    Write-Host "[!!] 没找到 assets\icon.ico，用默认图标" -ForegroundColor Yellow
}
& $Compiler /in $In /out $Out /base $Base /compress 2 @extra | Out-Null
if (-not (Test-Path $Out)) { Write-Host "[XX] 编译失败" -ForegroundColor Red; exit 1 }
$f = Get-Item $Out
$h = (Get-FileHash $Out -Algorithm SHA256).Hash.ToLower()
Write-Host ("[ok] {0}  {1:N0} B  sha256={2}" -f $f.Name, $f.Length, $h) -ForegroundColor Green

# 3) 四套自检
if (-not $NoTest) {
    $bad = 0
    foreach ($t in @("--selftest", "--i18ntest", "--findtest", "--guismoke")) {
        & $Out $t *> $null
        $rc = $LASTEXITCODE
        if ($rc -ne 0) { $bad++ }
        Write-Host ("    {0,-12} exit={1}" -f $t, $rc) -ForegroundColor $(if ($rc -eq 0) { "Green" } else { "Red" })
    }
    if ($bad -gt 0) { Write-Host "[XX] $bad 项自检失败" -ForegroundColor Red; exit 1 }
    Write-Host "[ok] 四套自检全过" -ForegroundColor Green
}

# 4) 可选：上传到 Release（exe + sha256）
if ($Upload) {
    $sha = Join-Path (Split-Path $Out) "$($f.Name).sha256"
    "$h  $($f.Name)" | Set-Content -Path $sha -Encoding UTF8
    Write-Host "[--] 上传到 $Repo $Tag"
    gh release upload $Tag $Out $sha --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) { Write-Host "[XX] 上传失败" -ForegroundColor Red; exit 1 }
    gh release view $Tag --repo $Repo --json assets |
        ConvertFrom-Json | ForEach-Object { $_.assets } |
        ForEach-Object { Write-Host ("    {0,-34} {1,12:N0} B  {2}" -f $_.name, $_.size, $_.state) }
}

Write-Host ""
Write-Host "完成。启动器：$Out"
