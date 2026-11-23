<#
.SYNOPSIS
  一键把 TinyStrata 发布到 GitHub：代理 → gh 安装/登录 → git 凭据 → 建仓推送 →（可选）发 exe。

.DESCRIPTION
  可重复执行（幂等）：已经装好/登录/建仓/推送过的步骤会跳过。
  默认只做"推源码"，加 -Release 才上传预编译 exe（走 Releases，不进仓库）。

.EXAMPLE
  # 先预演，什么都不改
  .\publish-tinystrata.ps1 -DryRun -SkipInstall

.EXAMPLE
  # 正常发布（首次会弹浏览器让登录）
  .\publish-tinystrata.ps1

.EXAMPLE
  # 连预编译引擎一起发
  .\publish-tinystrata.ps1 -Release
#>
[CmdletBinding()]
param(
    [string]$Source = "D:\dev\dist\TinyStrata",
    [string]$Repo = "TinyStrata",
    [ValidateSet("public", "private")][string]$Visibility = "public",
    [string]$Branch = "main",
    # 代理：按顺序试，第一个连得上的就用
    [string[]]$ProxyPorts = @("7890", "7897"),
    [switch]$SkipInstall,      # 不尝试 winget 安装 gh
    [switch]$Release,          # 顺便发一个 Release（上传 exe）
    [string]$Exe = "D:\dev\strata\build-cuda12\strata.exe",
    [string]$Tag = "v0.1.0",
    [switch]$DryRun            # 只打印将要做的事
)

$ErrorActionPreference = "Stop"
$script:steps = 0

function Say($msg, $kind = "info") {
    $mark = switch ($kind) { "ok" { "[ok]  " } "warn" { "[!!]  " } "err" { "[XX]  " } default { "[--]  " } }
    $color = switch ($kind) { "ok" { "Green" } "warn" { "Yellow" } "err" { "Red" } default { "Gray" } }
    Write-Host "$mark$msg" -ForegroundColor $color
}
# 原生命令可能"正常地失败"（gh auth status 未登录就把话写到 stderr）。
# PS 5.1 在 $ErrorActionPreference='Stop' 下会把 stderr 当终止错误，所以统一走这里。
function TryNative($exe, [string[]]$rest) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe @rest 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out.Trim() }
    } catch {
        return [pscustomobject]@{ Code = 1; Out = "$_" }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Run($desc, [scriptblock]$action) {
    $script:steps++
    if ($DryRun) { Say "$desc  (dry-run，不执行)" "warn"; return $null }
    Say $desc
    return & $action
}

# ---------------------------------------------------------------- 1. 代理
Say "1) 代理" "info"
$proxy = $null
foreach ($port in $ProxyPorts) {
    $t = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($t) { $proxy = "http://127.0.0.1:$port"; break }
}
if (-not $proxy) {
    Say "没有代理端口在监听（试过 $($ProxyPorts -join ', ')）—— 请先启动 Clash" "err"
    Say "GitHub 在本机必须走代理；api.github.com 直连可用，但 github.com 不行" "warn"
    exit 1
}
Say "用代理 $proxy" "ok"
if (-not $DryRun) {
    $env:HTTPS_PROXY = $proxy
    $env:HTTP_PROXY = $proxy
    $env:NO_PROXY = "127.0.0.1,localhost"
}

# git 自己的代理（早先配过 7890，可能和当前端口不一致）
$gitProxy = (git config --global --get http.proxy) 2>$null
if ($gitProxy -ne $proxy) {
    Run "git 全局 http.proxy: '$gitProxy' -> '$proxy'" {
        git config --global http.proxy $proxy
        git config --global https.proxy $proxy
    }
} else {
    Say "git http.proxy 已经是 $proxy" "ok"
}

# ---------------------------------------------------------------- 2. gh
Say "2) GitHub CLI" "info"
# 本脚本可能在"装 gh 之前"打开的终端里运行：先把标准安装位置补进 PATH
foreach ($dir in @("$env:ProgramFiles\GitHub CLI", "$env:LOCALAPPDATA\GitHubCLI")) {
    if ($dir -and (Test-Path (Join-Path $dir "gh.exe")) -and
        -not (($env:Path -split ';') -contains $dir)) {
        $env:Path = "$dir;$env:Path"
    }
}
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    if ($SkipInstall) {
        Say "gh 未安装（-SkipInstall）：跳过登录/推送，只做本地自检" "warn"
        Say "  手动装：winget install --id GitHub.cli -e" "warn"
    }
    if (-not $SkipInstall) {
        Run "winget 安装 GitHub CLI" {
            winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
        }
    }
    # winget 装完当前会话的 PATH 里可能还没有，从注册表补一次
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh -and -not $DryRun) {
        Say "装完仍然找不到 gh，请重开一个终端再跑本脚本（先做本地自检）" "warn"
    }
} else {
    Say "已安装：$($gh.Source)" "ok"
}
if ($DryRun -and -not $gh) { Say "（dry-run：后续 gh 步骤会跳过）" "warn"; }

# ---------------------------------------------------------------- 3. 登录
Say "3) 登录" "info"
$authed = $false
if ($gh) {
    $authed = ((TryNative "gh" @("auth", "status", "--hostname", "github.com")).Code -eq 0)
}
if ($authed) {
    Say "已登录 github.com" "ok"
} elseif ($gh) {
    Run "gh auth login（浏览器里粘贴一次性码）" {
        gh auth login --hostname github.com --git-protocol https --web
    }
    # 登录后必须重新求值，否则后面的 setup-git / 推送仍按"未登录"跳过
    $authed = ((TryNative "gh" @("auth", "status", "--hostname", "github.com")).Code -eq 0)
    if ($authed) { Say "登录成功" "ok" } else { Say "仍然未登录（继续会跳过推送）" "warn" }
} else {
    Say "跳过（gh 不可用）" "warn"
}

# ---------------------------------------------------------------- 4. git 凭据
Say "4) git 凭据" "info"
$helper = (git config --get credential.helper) 2>$null   # merged: 全局 + system
if ($gh -and $authed) {
    Run "gh auth setup-git（本机没装 GCM，用 gh 的 token 顶替）" { gh auth setup-git }
} elseif ($helper) {
    $bin = Get-Command git-credential-manager.exe -ErrorAction SilentlyContinue
    if (-not $bin) {
        $bin = @("C:/Program Files/Git/mingw64/bin/git-credential-manager.exe",
                 "C:/Program Files/Git/mingw64/libexec/git-core/git-credential-manager.exe") |
               Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($bin) {
        Say "credential.helper = $helper（$bin）：没登录时 push 会弹一次登录" "warn"
    } else {
        Say "credential.helper = $helper，但 git-credential-manager.exe 不存在 —— push 必然失败" "err"
    }
} else {
    $gcm = @(
        "C:/Program Files/Git/mingw64/bin/git-credential-manager.exe"
        "C:\Program Files\Git\mingw64\libexec\git-core\git-credential-manager.exe"
    ) | Where-Object { Test-Path $_ }
    if ($helper -and -not $gcm) {
        Say "credential.helper=$helper，但 git-credential-manager.exe 不存在 —— push 会要求账号密码" "warn"
    } else {
        Say "没有可用的凭据助手 —— push 会要求账号密码" "warn"
    }
}

# ---------------------------------------------------------------- 5. 仓库内容自检
Say "5) 待发布目录自检" "info"
if (-not (Test-Path (Join-Path $Source ".git"))) {
    Say "$Source 不是 git 仓库，先初始化" "warn"
    Run "git init -b $Branch" { git -C $Source init -b $Branch }
}
$bad = git -C $Source ls-files | Where-Object {
    $_ -match '\.(gguf|exe|dll|sess|log|bin)$' -or $_ -match '^(results|sessions|scratch|build)/'
}
if ($bad) {
    Say "仓库里有不该发布的东西：" "err"
    $bad | Select-Object -First 10 | ForEach-Object { Say "  $_" "err" }
    Say "把它们从索引里去掉（git rm --cached）后再跑" "warn"
    exit 1
}
$tracked = (git -C $Source ls-files | Measure-Object).Count
Say "跟踪文件 $tracked 个，没有模型/二进制/日志" "ok"
if (-not $DryRun) {
    $dirty = git -C $Source status --porcelain
    if ($dirty) { Say "有未提交改动（先提交再发布）：" "warn"; $dirty | Select-Object -First 5 | ForEach-Object { Say "  $_" "warn" } }
}

# ---------------------------------------------------------------- 6. 建仓 + 推送
Say "6) 仓库与推送" "info"
if (-not $gh -or -not $authed) {
    Say "跳过（未登录）。手动：" "warn"
    Say "  cd $Source" "warn"
    Say "  git remote add origin https://github.com/<账号>/$Repo.git" "warn"
    Say "  git push -u origin $Branch" "warn"
    exit 0
}
$me = TryNative "gh" @("api", "user", "--jq", ".login")
if ($me.Code -ne 0) {
    Say "读取账号失败：$($me.Out)" "err"
    exit 1
}
$login = $me.Out
Say "登录账号：$login" "ok"
$exists = ((TryNative "gh" @("repo", "view", "$login/$Repo")).Code -eq 0)
if ($exists) {
    Say "$login/$Repo 已存在，只推更新" "ok"
    $remote = (git -C $Source remote get-url origin) 2>$null
    if (-not $remote) {
        Run "加 remote origin" { git -C $Source remote add origin "https://github.com/$login/$Repo.git" }
    }
    Run "git push -u origin $Branch" { git -C $Source push -u origin $Branch }
} else {
    Run "gh repo create $login/$Repo（$Visibility）并推送" {
        gh repo create "$login/$Repo" "--$Visibility" --source $Source --remote origin --push
    }
}

# ---------------------------------------------------------------- 7. Releases（可选）
if ($Release) {
    Say "7) Release + 预编译引擎" "info"
    if (-not (Test-Path $Exe)) {
        Say "找不到 $Exe" "err"
    } else {
        $mb = [math]::Round((Get-Item $Exe).Length / 1MB, 1)
        $have = ((TryNative "gh" @("release", "view", $Tag, "--repo", "$login/$Repo")).Code -eq 0)
        if ($have) {
            Say "Release $Tag 已存在，跳过（要覆盖先 gh release delete $Tag）" "warn"
        } else {
            Run "上传 $Exe（$mb MiB）到 Release $Tag" {
                gh release create $Tag $Exe --repo "$login/$Repo" `
                    --title "TinyStrata for Qwen3.6-35B-A3B (4 GB VRAM)" `
                    --notes "CUDA 12.8, sm_86. Built from upstream cd1daa4e plus TinyStrata's three patches (see patches/). Model files are not included."
            }
        }
    }
}

# ---------------------------------------------------------------- 收尾
Say ""
Say "完成。仓库：https://github.com/$login/$Repo" "ok"
if (-not $DryRun) {
    try {
        $rl = (gh api rate_limit --jq '.resources.core') | ConvertFrom-Json
        Say "API 限额：$($rl.remaining)/$($rl.limit)（认证后是 5000/小时）" "ok"
    } catch {
        Say "（读限额失败，不影响）" "warn"
    }
}
Say "提示：gh 的 token 在 $env:USERPROFILE\.config\gh\hosts.yml，别拷进备份或仓库" "warn"
exit 0
