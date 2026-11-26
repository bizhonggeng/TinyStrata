#Requires AutoHotkey v2.0
#Warn All, StdOut        ; 警告也打到 stdout（/ErrorStdOut 只重定向「会触发」的那些，这个才会全开）
#Warn LocalSameAsGlobal, Off   ; 这个代码库大量函数用 global + 同名局部变量（74 条噪音），其余警告全开
#SingleInstance Force

; ============================================================================
;  TinyStrata 启动器（AutoHotkey v2，本机 v2.0.19 实测）
;  把 run-strata-qwen36.bat（短模式）与 run-strata-qwen36-long.bat（长模式）
;  合成一个界面：模式切换 / 参数交互 / 运行状态查看 / 可点击浏览器链接。
;
;  两个 .bat 的参数构造规则在这里被逐字复刻 —— 同一组参数下驱动
;  (D:\dev\tools\strata-run.py) 生成的运行配置 JSON 与 .bat 完全一致。
;  原来两个 .bat 没有改动，仍可双击使用（后备）。
;
;  用法：
;    双击本文件                                        -> 打开界面（默认简洁模式，记住上次用的模式）
;    AutoHotkey64.exe strata-launcher.ahk --simple     -> 强制简洁模式
;    AutoHotkey64.exe strata-launcher.ahk --pro        -> 强制专业模式
;    AutoHotkey64.exe strata-launcher.ahk --ontop      -> 调试用：界面强制置顶（正常使用不置顶）
;    AutoHotkey64.exe strata-launcher.ahk --selftest   -> 功能自检（结果写 D:\dev\strata-launcher-selftest.txt）
;    AutoHotkey64.exe strata-launcher.ahk --guismoke   -> 只把界面建出来 2.5 秒再退出
;  语法检查：AutoHotkey64.exe /ErrorStdOut strata-launcher.ahk
;
;  两个界面（同一份参数集合的两套视图，互相切换不丢设置）：
;    简洁模式：模式 / 上下文长度 / 启用思考 / preserve-thinking / 端口 / api-key(可复制)，
;              状态图（运行中/启动中/异常/未运行）+ 网页聊天 + 可复制的 base_url
;    专业模式：全部驱动参数、边界检查、进程与显存状态、日志与配置、全部端点链接
;
;  单实例：再次双击会替换掉已有窗口 —— 旧窗口是直接被结束的，不会保存"没点过保存"的改动，
;  想留住设置请先点「保存为默认」（脚本第 2 行 #SingleInstance Force）。
;
;  启动方式：驱动在后台跑（不弹 cmd 窗口），输出重定向到 results\strata-qwen36[-long]-driver.log，
;  界面底部的「驱动输出」按钮可看；驱动跑完会自己检查日志尾部并在异常时弹提示。
; ============================================================================
; ---- 路径：全部由 Locate() 在启动时算出来（便携化：不再硬编码 D:\dev）----
; 优先级：环境变量 STRATA_HOME > 启动器旁边 ini 的 [ui] home > 启动器所在目录
;         > 上溯 4 级父目录 > 老路径 D:\dev
; 每个候选目录里的找法：<dir>\engine*\strata.exe > <dir>\strata.exe
;                     > <dir>\*\strata.exe > <dir>\*\*\strata.exe
global DEV      := ""    ; HOME：配置/日志/会话所在目录
global ROOT     := ""    ; 引擎检出目录（含 serve\server.py）
global EXE      := ""    ; strata.exe 的实际位置
global SERVER_PY := ""   ; serve\server.py（OpenAI 兼容层；引擎本身没有 HTTP 服务）
global PY       := ""
global DRIVER   := ""
global BASE_CFG := ""
global RESULTS  := ""
global SESSIONS := ""
global GUARD_PY := ""
global INI      := ""
global SELFLOG  := ""
global SMOKELOG := ""
global SWITCHLOG := ""
global I18NLOG  := ""
global FINDLOG  := ""
global ABOUTLOG := ""
global GUARD_LOG := ""
global TPL_DIR  := ""
global gLocated := false  ; Locate() 有没有真的找到 strata.exe
global gLocateHow := ""   ; 从哪个目录找到的（状态行要显示）
global APP_VER := "0.1.4"       ; 与 Release tag 对齐
global PROJ_URL := "https://github.com/bizhonggeng/TinyStrata"
global UPSTREAM_URL := "https://github.com/Niko1221/Strata"
global MODEL_URL := "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF"       ; 启动器版本（与 Release tag 对齐）
global gLang := "zh"            ; "zh" | "en"（InitLang() 里定）
global EN := Map()
global ENKeys := []
Locate()
try {
    InitLang()
} catch as e {
    FileAppend("i18n init failed: " . e.Message . " @" . e.Line . " (" . e.What . ")" . chr(10), A_ScriptDir . "\i18n-init-error.txt", "UTF-8")
    gLang := "zh"
}

global EXPERTS_MIB := 12288      ; 35B-A3B 的专家在内存里的大小（IQ3_S 实测 12.0 GiB）
global LOWRAM_SPARE_MIB := 7168  ; 与 serve/prepare.py 的 LOWRAM_SPARE_MIB 保持一致
global RAM_ABORT_MB := 500        ; 与驱动内护栏同阈值：余量低于它就杀引擎
global MODEL_NEED_MB := 13000     ; 引擎要吞 ~12 GiB 专家进内存
global VRAM_WARN_MIB := 400       ; 显存"实际已占用"超过它才提醒（不按有没有进程）
global LOG_FRESH_MIN := 3         ; 端口还没通时：日志最近这么多分钟内还在写 → 算"加载中"，不喊异常
global gLaunchTick := 0           ; 点「启动」的时刻（A_TickCount），用来显示"已等多久"
global ONTOP := HasArg("--ontop") ; 置顶只作为调试开关，正常使用不置顶
global gDriverPid := 0            ; 后台驱动的 cmd 包装进程 pid（用它判断驱动何时跑完）
global gDriverLog := ""           ; 后台驱动这次写哪个日志（结束判定读它）
global LINK_BOX_Y := 452          ; 「浏览器链接」分组框的 y（左栏，紧跟主按钮行 y=410..442）

; 链接行必须在分组框标题下沿之下（标题占 y+2..y+16 那一条），否则会和标题文字重叠
global LINK_Y := LINK_BOX_Y + 20  ; = 500：链接行在窗口里的 y
global LINK_X0 := 22              ; 链接行起点 x
global LINK_DX := 96              ; 链接间隔（7 个也要塞进分组框：22+6*96+92 = 690 <= 700）
global LINK_W := 92
global gMonitorOn := false        ; /api-monitor（请求监控）当前是否可用
global gHasGui := false           ; 已建界面？（--inicheck 等无界面模式不碰 / 不弹气泡）
global gIgnoreIni := false        ; 自检/测试时置 true：ApplyPreset 不读用户 INI
global gInSetFields := false      ; SetFields 期间抑制 Change 事件
global gMtpList := []           ; MTP 下拉框当前的选项（切模式时换）
global gUiMode := "simple"        ; 当前界面："simple"（简洁）| "pro"（专业）
global gParams := {}              ; 最近一次完整的参数集合（简洁模式隐藏字段的取值来源）
global gPro := 0                  ; 专业模式窗口
global gSimple := 0               ; 简洁模式窗口
global gAbout := 0                ; 「关于」窗口
global gPack := ""                ; 本次实际用的 pack 目录（"" = 沿用模板里的 --pack）
global gRebuilding := false      ; 正在销毁/重建窗口：定时器与按钮必须停手（否则读到已销毁的控件）
global gLastBasePort := -1        ; 简洁模式里 base_url / 网页聊天链接上次用的端口
global SIMPLE_W := 460            ; 简洁模式窗口尺寸 + 浏览器那一行的位置（自检会检查它离底部有留白）
global SIMPLE_H := 552            ; 486 + 66：多了「模型」分组（GGUF / mmproj 两行）
global PRO_W := 1260              ; 专业模式窗口尺寸（左栏参数 704 + 右栏状态/日志 520 + 边距；自检会检查）
global PRO_H := 520              ; 两栏布局：左栏到 508，右栏日志到 512（约 14 行，自动换行）
global S_BASE_Y := 500            ; 「接口地址」那行的复制按钮 y（模型分组后整体下移 92）
global S_BASE_H := 26

; 下拉框允许的取值（AHK v2.0.19 里 DropDownList 的 .Value 是"下标"不是文本，
; 所以：设置用 .Text，读取用 .Text；.Value 只在 Radio/CheckBox 上用 0/1）
global KV_LIST := ["k8v4", "q4_0", "int8", "fp16"]

; MTP 选项按模式：短模式 = gpu（专家在显存）/ off；长模式 = cpu（专家在主机内存，省 312 MiB）/ off
global TPL_DIR := ""   ; chat 模板默认目录（Locate() 里按 HOME\templates 定）
global MTP_LIST_SHORT := ["gpu", "cpu", "off"]   ; gpu = 专家在显存（IQ3_S 最快）；cpu = 上 CPU（大量化必须）
global MTP_LIST_LONG := ["cpu", "off"]   ; 长模式只有 cpu/off：专家全上 GPU 会装不下（80K 上下文放不下 312 MiB）

; ---------------------------------------------------------------- 0. 便携化定位
; 找到 strata.exe 在哪，然后把 DEV/ROOT/PY/DRIVER/... 全部派生出来。
; 找不到就退回老布局（D:\dev\strata\engine-cuda12），让界面还能建出来，Preflight 会报缺件。

Locate() {
    global DEV, ROOT, EXE, SERVER_PY, PY, DRIVER, BASE_CFG, RESULTS, SESSIONS
    global GUARD_PY, INI, SELFLOG, SMOKELOG, SWITCHLOG, I18NLOG, FINDLOG, ABOUTLOG, GUARD_LOG, TPL_DIR
    global gLocated, gLocateHow
    ; （hit/how 由下面的「显式指定引擎」块初始化）
    cands := []
    if (v := EnvGet("STRATA_HOME")) && v != ""
        cands.Push(v)                        ; 1) 环境变量
    iniNear := A_ScriptDir . "\strata-launcher.ini"
    if FileExist(iniNear) {
        try {
            h := IniRead(iniNear, "ui", "home", "")
            if (h != "")
                cands.Push(h)                ; 2) 上次「浏览…」选过的
        }
    }
    d := A_ScriptDir
    loop 5 {                                 ; 3) 启动器所在目录 + 上溯 4 级
        cands.Push(d)
        p := ParentDir(d)
        if (p = "" || p = d)
            break
        d := p
    }
    ; 0) 显式指定引擎（自己编译的、或另一块卡用的那份）：环境变量 > ini
    override := EnvGet("STRATA_EXE")
    if (override = "" && FileExist(iniNear)) {
        try override := IniRead(iniNear, "ui", "exe", "")
    }
    if (override != "" && FileExist(override)) {
        {
            hit := override
            how := "（指定）" . ParentDir(override)
        }
    }
    hit := (IsSet(hit) ? hit : ""), how := (IsSet(how) ? how : "")
    for dir in (hit != "" ? [] : cands) {   ; 已经指定了引擎就不再搜目录
        if (dir = "")
            continue
        e := FindEngineIn(dir)
        if (e != "") {
            hit := e, how := dir
            break
        }
    }
    if (hit = "") {
        gLocated := false, gLocateHow := ""
        DEV := A_ScriptDir, ROOT := A_ScriptDir          ; 兜底：把启动器所在目录当便携根
        if DirExist(A_ScriptDir . "\strata")
            ROOT := A_ScriptDir . "\strata"
        EXE := ROOT . "\engine-cuda12\strata.exe"
        SERVER_PY := ROOT . "\serve\server.py"
    } else {
        gLocated := true, gLocateHow := how
        r := ResolveEngineRoot(hit)
        EXE := r.exe, ROOT := r.root, DEV := r.home
        SERVER_PY := ROOT . "\serve\server.py"
    }
    PY := FirstFile(ROOT . "\.venv\Scripts\python.exe", DEV . "\.venv\Scripts\python.exe",
                    ROOT . "\python\python.exe", DEV . "\python\python.exe")
    if (PY = "")
        PY := OnPath("python.exe")
    DRIVER := FirstFile(DEV . "\tools\strata-run.py", ROOT . "\tools\strata-run.py",
                        A_ScriptDir . "\tools\strata-run.py")
    BASE_CFG := FirstFile(DEV . "\strata-qwen36-iq3s.json", ROOT . "\strata-qwen36-iq3s.json",
                          A_ScriptDir . "\strata-qwen36-iq3s.json")
    if (BASE_CFG = "")
        BASE_CFG := FirstGlob(DEV . "\configs\*.json", ROOT . "\configs\*.json",
                              A_ScriptDir . "\configs\*.json")
    RESULTS := DEV . "\results"
    SESSIONS := DEV . "\sessions"
    GUARD_PY := FirstFile(DEV . "\tools\strata-ram-guard.py", ROOT . "\tools\strata-ram-guard.py")
    INI := DEV . "\strata-launcher.ini"
    SELFLOG := DEV . "\strata-launcher-selftest.txt"
    SMOKELOG := DEV . "\strata-launcher-guismoke.txt"
    SWITCHLOG := DEV . "\strata-launcher-switchtest.txt"
    I18NLOG := DEV . "\strata-launcher-i18ntest.txt"
    FINDLOG := DEV . "\strata-launcher-findtest.txt"
    ABOUTLOG := DEV . "\strata-launcher-about.txt"
    GUARD_LOG := RESULTS . "\strata-ram-guard.log"
    TPL_DIR := DirExist(DEV . "\templates") ? DEV . "\templates" : ROOT . "\templates"
}

; a\b\c -> a\b（盘根不再上溯；已到顶就返回原值）

ParentDir(p) {
    p := StrReplace(p, "/", "\\")          ; 环境变量/配置里常是正斜杠：先归一
    p := RTrim(p, "\\/")
    if (p = "" || RegExMatch(p, "^[A-Za-z]:$"))
        return p
    q := RegExReplace(p, "\\[^\\]*$", "")
    return (q = "") ? p : q
}

; 在一个目录里找引擎。不是"第一个命中"就返回 —— 而是**收集全部候选再打分**：
; 本机 D:\dev 下就有 backup-2026-10-12\engine-cuda12-0.1.41\strata.exe 这种归档，
; 按字母序它会抢在 strata\engine-cuda12\ 前面。

FindEngineIn(dir) {
    exes := FindEnginesIn(dir)
    best := "", bestScore := -1000000
    for e in exes {
        sc := ScoreEngine(e)
        if (sc > bestScore)
            best := e, bestScore := sc
    }
    return best
}

; 收集一个目录里所有候选（去重）

FindEnginesIn(dir) {
    out := []
    if (dir = "" || !DirExist(dir))
        return out
    patterns := [dir . "\strata.exe", dir . "\engine*\strata.exe",
                 dir . "\*\strata.exe", dir . "\*\engine*\strata.exe"]
    for pat in patterns {
        loop files, pat {
            f := A_LoopFileFullPath
            if !HasVal(out, f)
                out.Push(f)
        }
    }
    if !RegExMatch(RTrim(dir, "\/"), "^[A-Za-z]:$")          ; 盘根不做 DFS
        out := MergeUniq(out, FindEnginesDeep(dir, 1, 3, A_TickCount + 3000))
    return out
}

; 有限深度遍历，跳过备份/缓存这类大而无用的目录

FindEnginesDeep(dir, depth, maxDepth, deadline) {
    out := []
    if (depth > maxDepth || A_TickCount > deadline)
        return out
    loop files, dir . "\*", "D" {
        if (A_TickCount > deadline)
            return out
        sub := A_LoopFileFullPath
        n := RegExReplace(sub, "^.*\\", "")
        if RegExMatch(n, "i)^(node_modules|__pycache__|\.git.*|\.venv|\.cache|dist|tmp|temp)$")
            continue
        if FileExist(sub . "\strata.exe")
            out.Push(sub . "\strata.exe")
        out := MergeUniq(out, FindEnginesDeep(sub, depth + 1, maxDepth, deadline))
    }
    return out
}

HasVal(arr, v) {
    for x in arr
        if (x = v)
            return true
    return false
}

MergeUniq(a, b) {
    for x in b
        if !HasVal(a, x)
            a.Push(x)
    return a
}

; 候选打分：正经检出 > 便携 > 归档/备份；浅的优先

ScoreEngine(exe) {
    exeDir := ParentDir(exe)
    root := ResolveEngineRoot(exe).root
    nm := RegExReplace(exeDir, "^.*\\", "")
    s := 0
    if FileExist(root . "\serve\server.py")
        s += 100                                   ; 有 Python 服务层 = 真检出
    if (nm = "engine-cuda12")
        s += 50                                    ; 规范目录名
    if FileExist(root . "\setup.py")
        s += 20
    for comp in StrSplit(exe, "\") {                 ; 路径里任一目录名像归档 → 扣分
        lc := StrLower(comp)
        if (SubStr(lc, 1, 6) = "backup" || SubStr(lc, 1, 3) = "old"
            || lc = "tmp" || lc = "temp" || lc = "dist" || lc = "obsolete")
            s -= 200
    }
    if InStr(nm, "-0.")                                ; engine-cuda12-0.1.41 这类版本快照
        s -= 60                                    ; engine-cuda12-0.1.41 这类版本快照
    s -= StrSplit(exe, "\").Length                 ; 同等条件下浅的赢
    return s
}

; 从 exe 路径反推 ROOT（项目根）与 HOME（配置/日志目录）

ResolveEngineRoot(exe) {
    parent := ParentDir(exe)
    name := RegExReplace(parent, "^.*\\", "")
    root := (SubStr(name, 1, 6) = "engine") ? ParentDir(parent) : parent
    home := root
    up := ParentDir(root)
    if (up != "" && (FileExist(up . "\tools\strata-run.py") || DirExist(up . "\results")))
        home := up
    return {exe: exe, root: root, home: home}
}

FirstFile(paths*) {
    for p in paths {
        if (p != "" && FileExist(p))
            return p
    }
    return ""
}

FirstGlob(patterns*) {
    for p in patterns {
        loop files, p
            return A_LoopFileFullPath
    }
    return ""
}

OnPath(exeName) {
    for d in StrSplit(EnvGet("PATH"), ";") {
        if (d = "")
            continue
        if FileExist(d . "\" . exeName)
            return d . "\" . exeName
    }
    return ""
}

; ---------------------------------------------------------------- 0c. 语言（中英）
; 做法：EN 是「中文原文 -> 英文」映射，Tf() 按 key 长度从长到短做字串替换。
; 没收录的串原样返回 —— 漏译只是不翻译，绝不会报错或吃字符。

LangFill(e) {
    e["TinyStrata 启动器"] := "TinyStrata Launcher"
    e["TinyStrata 启动器 · 简洁模式"] := "TinyStrata Launcher - Simple"
    e["TinyStrata 启动器 - 简洁模式"] := "TinyStrata Launcher - Simple"
    e["TinyStrata 启动器 - 停止"] := "TinyStrata Launcher - Stop"
    e["TinyStrata 启动器 - 重启"] := "TinyStrata Launcher - Restart"
    e["TinyStrata 启动器 - 预检失败"] := "TinyStrata Launcher - Preflight failed"
    e["TinyStrata 启动器"] := "TinyStrata Launcher"
    e["模式（切换按预设覆盖 ctx/kv/resident/mtp/reserve/preserve 等模式相关参数）"] := "Mode (switching applies a preset: ctx/kv/resident/mtp/reserve/preserve ...)"
    e["参数（改完直接点启动；字段名与驱动一致）"] := "Parameters (edit, then Start; names match the driver)"
    e["采样（留空 = 该键不写；thinking=off → reasoning_effort=none）"] := "Sampling (blank = key omitted; thinking=off -> reasoning_effort=none)"
    e["浏览器链接（点击用默认浏览器打开；端口跟随上面的 port 字段）"] := "Browser links (click to open; the port follows the field above)"
    e["运行状态（每 5 秒刷新）"] := "Status (refreshed every 5 s)"
    e["日志与配置"] := "Logs and config"
    e["服务端日志尾部（自动刷新；最新在最上；往下滚是历史）"] := "Server log tail (auto-refresh, wrapped, scrollable)"
    e["参数"] := "Parameters"
    e["短模式（快）"] := "Short (fast)"
    e["长模式（长上下文）"] := "Long (big context)"
    e["短：20K 上下文 / MTP 开　长：64K 上下文、KV 全常驻 / MTP 关（实测更快）"] := "short: 20K ctx, MTP on;  long: big ctx, KV fully resident"
    e["上下文长度"] := "Context length"
    e["启用思考"] := "Thinking"
    e["接口地址"] := "Base URL"
    e["打开网页聊天"] := "Open web chat"
    e["刷新"] := "Refresh"
    e["复制"] := "Copy"
    e["已切到"] := "Switched to "
    e["切到"] := "Switch to "
    e["专业模式"] := "Pro"
    e["简洁模式"] := "Simple"
    e["短"] := "short"
    e["长"] := "long"
    e["启动"] := "Start"
    e["重启"] := "Restart"
    e["停止"] := "Stop"
    e["预览(--check)"] := "Preview (--check)"
    e["刷新状态"] := "Refresh"
    e["打开日志目录"] := "Open logs"
    e["保存为默认"] := "Save defaults"
    e["简洁模式 →"] := "Simple view ->"
    e["专业模式 →"] := "Pro view ->"
    e["引擎日志"] := "Engine log"
    e["服务端日志"] := "Server log"
    e["驱动输出"] := "Driver output"
    e["护栏日志"] := "Guard log"
    e["运行配置 json"] := "Run config json"
    e["模板配置"] := "Template config"
    e["自检报告"] := "Selftest report"
    e["选择…"] := "Browse..."
    e["GGUF…"] := "GGUF..."
    e["mmproj…"] := "mmproj..."
    e["清空"] := "Clear"
    e["模型"] := "Model"
    e["模板"] := "Template"
    e["端口"] := "port"
    e["运行状态: -"] := "Status: -"
    e["进程: -"] := "Processes: -"
    e["端口: -"] := "Port: -"
    e["内存: -"] := "RAM: -"
    e["显存: -"] := "VRAM: -"
    e["文件自检: -"] := "Files: -"
    e["最近动作: -"] := "Last action: -"
    e["运行状态"] := "Status"
    e["文件自检"] := "Files"
    e["最近动作"] := "Last action"
    e["边界检查: —"] := "Bounds: -"
    e["边界检查: "] := "Bounds: "
    e["运行中（引擎已加载）"] := "running (engine loaded)"
    e["加载中…"] := "loading..."
    e["未运行"] := "not running"
    e["异常"] := "error"
    e["留空=用 pack 自带"] := "blank = pack default"
    e["off=关 / cpu=不占显存 / gpu=占~1.2GB"] := "off / cpu = no VRAM / gpu = ~1.2 GB"
    e["cpu=不占显存（推荐）"] := "cpu = no VRAM"
    e["对应这些 --xxx 参数（写进 sampling 块）；dry = 重复序列惩罚，空=用模板值 1.5，0=关"] := "these map to --xxx flags in the sampling block; dry = repeated-sequence penalty, blank = template 1.5, 0 = off"
    e["图片"] := "Image"
    e["图tok"] := "img-tok"
    e["浏览器"] := "Browser"
    e["已清空 GGUF/mmproj 覆盖"] := "Cleared the GGUF/mmproj overrides"
    e["已发起启动"] := "Launch requested"
    e["已发起预览 --check"] := "Preview (--check) requested"
    e["已保存为默认："] := "Saved as default: "
    e["已保存为默认（"] := "Saved as default ("
    e["已载入上次设置（"] := "Loaded last settings ("
    e["保存失败: "] := "Save failed: "
    e["保存失败："] := "Save failed: "
    e["模板: "] := "Template: "
    e["模式 ctx="] := "mode ctx="
              SetStatusText(Bi("已取消启动：参数没有应用（当前引擎/配置保持原样）", "Launch cancelled: the parameters were not applied (the running engine is untouched)"), "C00000")
    e["没有发现运行中的 Strata 进程（引擎 / 服务端 / 护栏 / 驱动 / 启动 cmd 都没有）。"] := "No Strata process found (engine / server / guard / driver / launcher cmd)."
    e["预览完成（--check）：运行配置已重写，引擎没启动"] := "Preview done (--check): run config rewritten, engine not started"
    e["驱动已正常退出（服务端 code=0）"] := "Driver exited normally (server code=0)"
    e["驱动已退出，但没找到输出日志： "] := "Driver exited but its log was not found: "
    e["驱动异常退出"] := "Driver exited with an error"
    e["（重启后生效，缓存会失效）"] := " (takes effect after restart; cache is dropped)"
    e["—— 见「驱动输出」"] := " - see 'Driver output'"
    e["个进程，成功 "] := " process(es), killed "
    e["个进程，等待释放后重新启动…"] := " process(es), waiting for release then restarting..."
    e["停止：请求 "] := "Stop: asked "
    e["重启：已停 "] := "Restart: stopped "
    e["，日志："] := ", log: "
    e["找不到：`n"] := "Not found:`n"
    e["无法启动：`n"] := "Cannot start:`n"
    e["界面启动失败：`n"] := "UI failed to start:`n"
    e["`n位置："] := "`n  at "
    e[" @行 "] := " line "
    e["`n`n命令行：`n"] := "`n`nCommand line:`n"
    e["`n`n最后几行：`n"] := "`n`nLast lines:`n"
    e["`n`n继续？"] := "`n`nContinue?"
    e["是否停止Strata引擎及相关进程"] := "Stop the Strata engine and related processes?"
    e["TinyStrata 启动器 · 简洁模式"] := "TinyStrata Launcher - Simple"
    e["专业模式 →"] := "Pro view ->"
    e["模式"] := "Mode"
    e["参数"] := "Parameters"
    e["端口"] := "Port"
    e["图片"] := "Image"
    e["图tok"] := "img-tok"
    e["上下文长度"] := "Context length"
    e["启用思考"] := "Thinking"
    e["复制"] := "Copy"
    e["刷新"] := "Refresh"
    e["打开网页聊天"] := "Open web chat"
    e["接口地址"] := "Base URL"
    e["API 监控"] := "API monitor"
    e["网页聊天"] := "Web chat"
    e["preserve-thinking"] := "preserve-thinking"
    e["运行中（引擎已加载）"] := "running (engine loaded)"
    e["（引擎在起，端口 "] := " (engine starting, port "
    e[" 还没就绪"] := " not ready yet"
    e["：进程还在但端口 "] := ": process alive but port "
    e[" 无响应，日志也停了"] := " is unresponsive and the log stopped"
    e["（端口 "] := " (port "
    e[" 无响应）"] := " unresponsive)"
    e["进程还在但端口 "] := "process alive but port "
    e["引擎在起，端口 "] := "engine starting, port "
    e["异常："] := "error: "
    e["运行中"] := "running"
    e["无"] := "none"
    e["ctx 上下文窗口 · kv K/V 存储（k8v4 最省显存）· mtp 草稿专家放哪（gpu 显存 / cpu 内存）· reserve 留给别人 · resident 留空=不写、0=显式全常驻、≥20480=流式"] := "ctx = window | kv = K/V storage (k8v4 uses the least VRAM) | mtp = where the draft experts live (gpu = VRAM / cpu = RAM) | reserve = kept for other apps | resident: blank = not written, 0 = explicitly all-resident, >=20480 = streaming"
    e["能开多大 ctx 由模型的显存占用与 kv 方式决定，不由预设决定；边界检查按本机实测表算"] := "how much ctx fits follows the model's VRAM footprint and the kv mode, not the preset; the bounds line uses the measured table"
    e["无响应"] := "no response"
    e["长"] := "long"
    e["短"] := "short"
    e["模式"] := "mode"
    e["开"] := "on"
    e["关"] := "off"
    e["进程: 引擎 "] := "Processes: engine "
    e[" · 服务端 "] := " · server "
    e[" · 驱动 "] := " · driver "
    e[" · 护栏 "] := " · guard "
    e[" · 监控 "] := " · monitor "
    e["内存: 空闲 "] := "RAM free: "
    e[" GiB / 共 "] := " GiB of "
    e[" GiB（护栏阈值 <"] := " GiB (guard kills below "
    e[" MB 杀引擎；模型要 ~12 GiB）"] := " MB; the model needs ~12 GiB)"
    e["显存: "] := "VRAM: "
    e["读不到（nvidia-smi 不可用）"] := "unavailable (nvidia-smi)"
    e["已用 "] := "used "
    e["文件自检: "] := "Files: "
    e["缺 "] := "missing "
    e["、"] := ", "
    e["齐全"] := "OK"
    e["模式日志 "] := "mode log "
    e["（本次实例）"] := " (this instance)"
    e[" · 另有 "] := " · also "
    e["（超过 "] := " (above "
    e[" MiB 阈值 → 启动前会提醒）"] := " MiB threshold -> warn before start)"
    e[" · 占用: "] := " · held by: "
    e["（低于 "] := " (below "
    e[" MiB 阈值 → 启动前不提醒）"] := " MiB threshold -> no warning)"
    e["长模式"] := "long mode"
    e["短模式"] := "short mode"
    e[" 还没有本机实测数据：启动一次后按引擎日志自动标定（专家槽 + KV 预算）"] := " has no on-machine measurement yet: one start fills it in from the engine log"
    e[" 能启动 / "] := " starts / "
    e[" 被拒  ->  当前 ctx "] := " refused  ->  current ctx "
    e["可启动"] := "ok"
    e["超过边界，引擎很可能拒绝"] := "over the bound; the engine will likely refuse"
    e["），改完点「启动」"] := "), edit then press Start"
    e["关于 / About"] := "About"
    e["语言 / Language"] := "Language"
    e["引擎缺失: "] := "engine missing: "
    e["（把 strata.exe 放到启动器旁边，或设 STRATA_HOME）"] := " (put strata.exe next to the launcher, or set STRATA_HOME)"
    e["服务层缺失: "] := "server layer missing: "
    e["（引擎本身没有 HTTP 服务，serve\ 目录必须存在）"] := " (the engine has no HTTP server of its own; the serve\ directory must exist)"
    e["python 缺失: "] := "python missing: "
    e["（检出布局需先在 "] := " (a checkout needs "
    e["跑一次 START-HERE.bat；便携包需带 python\python.exe）"] := " to run START-HERE.bat once; a portable bundle needs python\python.exe)"
    e["驱动缺失: "] := "driver missing: "
    e["模板配置缺失: "] := "config template missing: "
    e["参数错误: "] := "bad argument: "
    e["预检未通过："] := "preflight failed:"
    e["运行环境: "] := "environment: "
    e["没有指定 GGUF 模型文件：用「选择…」（简洁模式也有）选一次，或把配置模板里的 --native / 环境变量设好"] := "no GGUF model file: pick one with the Browse button (the simple view has it too), or set --native in the template / the environment"
    e["已经有实例在跑（引擎 pid "] := "an instance is already running (engine pid "
    e[" / 服务端 pid "] := " / server pid "
    e["）：驱动启动时会先把它杀掉 —— 单卡上这是设计行为。"] := "): the driver kills it first, which is by design on a single card."
    e["内存护栏已在运行（pid "] := "the RAM guard is already running (pid "
    e["），驱动会复用它。"] := "); the driver reuses it."
    e["空闲内存 "] := "RAM free "
    e[" MB（共 "] := " MB of "
    e[" MB），引擎要吞约 12 GiB 专家进内存；"] := " MB); the engine needs ~12 GiB of experts in RAM;"
    e["护栏在余量 <"] := "the guard kills below "
    e[" MB 时会杀引擎。"] := " MB free."
    e["内存余量只有 "] := "only "
    e[" MB，低于护栏阈值 "] := " MB free, below the guard threshold of "
    e[" MB —— 驱动一起来就会把引擎杀掉。先关掉占内存的程序再启动。"] := " MB -- the driver kills the engine right away; close the memory hogs first."
    e["显存实际被占用"] := "VRAM actually in use (threshold "
    e["）；引擎很可能拒绝启动并告诉你差多少 MiB。"] := "); the engine will likely refuse and say how many MiB short."
    e["ctx 必须是正整数"] := "ctx must be a positive integer"
    e["kv-resident 只能是 0（关闭流式）或 >= 20480（引擎下限）"] := "kv-resident is either 0 (no streaming) or >= 20480 (the engine's floor)"
    e["port 必须在 1-65535"] := "port must be 1-65535"
    e["vram-reserve-mib 不能为负"] := "vram-reserve-mib cannot be negative"
    e["超过本机实测硬上限 "] := "is past this machine's measured ceiling "
    e["，实测 "] := "; measured "
    e[" 被拒）。降到 "] := " refused). Lower it to "
    e["或以下。"] := "or below."
    e["启动前提醒："] := "before starting:"
    e["预览前提醒（不影响 --check）："] := "before previewing (--check ignores these):"
    e["（后台运行，不弹窗口；输出写 "] := " (runs in the background, no window; output goes to "
    e["（无窗口）：引擎加载约 12 秒，状态变绿即就绪；驱动输出见「驱动输出」按钮"] := " (no window): the engine takes ~12 s to load; once the badge is green it is ready. See the Driver output button for its log"
    e["已等多久"] := "elapsed"
    e["进程还在但引擎没在跑（上次的残留？点「停止」清掉）"] := "the process is alive but the engine is not (leftover from a previous run? press Stop)"
    e["（"] := " ("
    e["："] := ": "
    e["，"] := ", "
    e["。"] := "."
    e["；"] := "; "
    return e
}

; 把文本里已知的中文片段换成英文（只在 en 模式生效）

Tf(s) {
    global gLang, EN, ENKeys
    if (gLang != "en" || s = "")
        return s
    s := String(s)
    for k in ENKeys
        if InStr(s, k)
            s := StrReplace(s, k, EN[k])
    return s
}

; 遍历一个 Gui 的所有控件，翻译 Text（按钮/标签/分组框/单选/复选）

TranslateGui(g) {
    if (!IsObject(g))
        return 0
    n := 0
    for c in g {
        try {
            t := c.Text
            if (t != "" && (t2 := Tf(t)) != t) {
                c.Text := t2
                n++
            }
        }
    }
    return n
}

; 语言来源：命令行 > INI > 系统 UI 语言（主语言 0x04 = 中文，其余按英文）

DetectLang() {
    global INI
    if HasArg("--en")
        return "en"
    if HasArg("--zh")
        return "zh"
    if (INI != "" && FileExist(INI)) {
        try {
            v := IniRead(INI, "ui", "lang", "")
            if (v = "zh" || v = "en")
                return v
        }
    }
    try {
        lcid := DllCall("GetUserDefaultUILanguage", "UShort")
        return ((lcid & 0x3FF) = 0x04) ? "zh" : "en"
    }
    return "zh"
}

InitLang() {
    global gLang, EN, ENKeys
    EN := LangFill(Map())
    ENKeys := []
    for k, v in EN
        ENKeys.Push(k)
    ; 长 key 优先，避免短片段先命中把长串拆坏
    loop ENKeys.Length - 1 {
        i := A_Index
        while (i >= 1 && StrLen(ENKeys[i]) < StrLen(ENKeys[i + 1])) {
            tmp := ENKeys[i], ENKeys[i] := ENKeys[i + 1], ENKeys[i + 1] := tmp
            i--
        }
    }
    gLang := DetectLang()
    return gLang
}

SaveLang(v) {
    global INI
    try {
        if (INI != "")
            IniWrite(v, INI, "ui", "lang")
    }
}

; 菜单栏（两个窗口共用）：语言 / 关于。成熟启动器的惯例：来源、链接、诊断信息都在「关于」里。

AddMenus(g) {
    ; ---- 语言 ----
    m := Menu()
    m.Add("简体中文", (*) => SetLang("zh"))
    m.Add("English", (*) => SetLang("en"))
    m.Add()
    m.Add(Bi("跟随系统", "Follow system"), (*) => SetLang(""))
    ; ---- 关于 ----
    a := Menu()
    a.Add(Bi("关于 TinyStrata", "About TinyStrata"), (*) => ShowAbout())
    a.Add()
    a.Add(Bi("项目主页", "Homepage"), (*) => OpenUrl(PROJ_URL))
    a.Add(Bi("上游 Strata", "Upstream Strata"), (*) => OpenUrl(UPSTREAM_URL))
    a.Add(Bi("模型（HuggingFace）", "Model (HuggingFace)"), (*) => OpenUrl(MODEL_URL))
    a.Add()
    a.Add(Bi("选择引擎…", "Choose engine…"), (*) => PickEngine())
    a.Add(Bi("打开引擎目录", "Open engine folder"), (*) => OpenPath(ROOT))
    a.Add(Bi("打开日志目录", "Open logs"), (*) => OpenPath(RESULTS))
    a.Add(Bi("打开启动器目录", "Open launcher folder"), (*) => OpenPath(A_ScriptDir))
    a.Add()
    a.Add(Bi("自检（写报告）", "Self-check (writes a report)"), (*) => RunSelfCheck())
    bar := MenuBar()
    bar.Add(Tf("语言 / Language"), m)
    bar.Add(Tf("关于 / About"), a)
    g.MenuBar := bar
}

OpenUrl(u) {
    try Run(u)
    catch as e
        Notify("error", Tf("打不开链接：") . " " . u . " (" . e.Message . ")")
}

; 从界面里跑一次自检：写报告 + 打开它（比让用户开命令行现实）

RunSelfCheck() {
    try {
        RunWait('"' . A_AhkPath . '" /ErrorStdOut "' . A_ScriptFullPath . '" --selftest', , "Hide")
    } catch {
    }
    if FileExist(SELFLOG)
        OpenPath(SELFLOG)
}

; 「关于」：版本 / 定位到的真实路径 / 可点击链接 / 许可。
; 用自定义窗口而不是 MsgBox —— MsgBox 的文本不能点，Link 控件才能直接用默认浏览器打开。

AboutIntro() {
    global gLang
    if (gLang = "en")
        return "Goal: run MoE models (e.g. Qwen3.6-35B-A3B) fast, with high quality and stable output" . "`n"
            . "on a 4 GB VRAM card. This is a patched build of Strata (MIT) plus the launcher;" . "`n"
            . "no model weights are included."
    return "目标：在 4 GB 显存的显卡上，快速、高质量、稳定地运行 MoE 模型（如 Qwen3.6-35B-A3B）。`n"
        . "本项目是 Strata（MIT）的补丁版 + 启动器，不含模型与权重。"
}

AboutPaths() {
    global EXE, ROOT, DEV, PY, SERVER_PY, BASE_CFG, gLang
    cap := (gLang = "en")
        ? ["engine", "root", "home", "server", "python", "config"]
        : ["引擎", "项目根", "HOME", "服务层", "Python", "配置"]
    vals := [EXE, ROOT, DEV, SERVER_PY, PY, BASE_CFG]
    miss := (gLang = "en") ? "(not found)" : "（未找到）"
    out := ""
    for i, v in vals
        out .= cap[i] . "  " . (v = "" ? miss : v) . "`n"
    return RTrim(out, "`n")
}

; 「关于」里的运行环境三行：引擎版本、GPU 架构、以及这块卡该用的编译参数

EnvLines() {
    global gLang, EXE
    zh := (gLang != "en")
    ver := EngineVersion()
    cap := GpuComputeCap()
    dll := CudaDlls()
    out := ""
    out .= (zh ? "引擎    " : "engine  ") . (ver = "" ? (zh ? "（读不到版本）" : "(no version)") : ver) . "`n"
    out .= (zh ? "GPU     " : "GPU     ") . (cap = "" ? (zh ? "（读不到）" : "(unknown)") : ("compute " . cap))
    if (cap != "" && cap != "8.6")
        out .= zh ? "  ← 本 Release 是 sm_86；这块卡要自己编译：" . ArchFlagFor(cap)
                  : "  <- this release is sm_86; build your own: " . ArchFlagFor(cap)
    out .= "`n"
    out .= (zh ? "CUDA    " : "CUDA    ") . ((dll.cudart != "" && dll.cublas != "")
        ? (zh ? "运行时齐全（" : "runtime ok (") . dll.where . "）"
        : (zh ? "缺 cudart64_12.dll / cublas64_12.dll：装 CUDA Toolkit 12.x"
              : "missing cudart64_12.dll / cublas64_12.dll: install CUDA Toolkit 12.x"))
    return out
}

AboutText() {
    global APP_VER, gLang
    head := "TinyStrata 启动器  v" . APP_VER . "`n" . AboutIntro() . "`n`n"
        . "—— 当前定位 ——`n" . AboutPaths() . "`n`n"
        . "—— 运行环境 ——`n" . EnvLines() . "`n`n"
        . "—— 链接 ——`n" . PROJ_URL . "`n" . UPSTREAM_URL . "`n" . MODEL_URL . "`n`n"
        . "许可：MIT（补丁与启动器同许可；模型权重遵循其自身许可）"
    if (gLang = "en")
        head := "TinyStrata Launcher  v" . APP_VER . "`n" . AboutIntro() . "`n`n"
            . "-- resolved paths --`n" . AboutPaths() . "`n`n"
            . "-- runtime --`n" . EnvLines() . "`n`n"
            . "-- links --`n" . PROJ_URL . "`n" . UPSTREAM_URL . "`n" . MODEL_URL . "`n`n"
            . "Licence: MIT (patches and launcher); model weights keep their own licence."
    return head
}

ShowAbout() {
    global APP_VER, gLang, gAbout
    if IsObject(gAbout) {
        try gAbout.Destroy()
    }
    en := (gLang = "en")
    gAbout := Gui("-MaximizeBox -MinimizeBox", Tf("关于 / About") . " - v" . APP_VER)
    gAbout.SetFont("s9", "Segoe UI")
    gAbout.MarginX := 14, gAbout.MarginY := 12
    gAbout.SetFont("s11 Bold")
    gAbout.AddText("w548", "TinyStrata " . (en ? "Launcher" : "启动器") . "  v" . APP_VER)
    gAbout.SetFont("s9")
    gAbout.AddText("w548 y+8", AboutIntro())
    gAbout.AddText("w548 y+10 c404040", en ? "Resolved paths" : "当前定位")
    pt := gAbout.AddText("w548 h96 c202020", AboutPaths())
    pt.SetFont("s8", "Consolas")
    gAbout.AddText("w548 y+8 c404040", en ? "Links (click to open)" : "链接（点击打开）")
    lnk := [["GitHub - TinyStrata", PROJ_URL], ["GitHub - Strata (upstream)", UPSTREAM_URL],
            ["HuggingFace - Qwen3.6-35B-A3B-MTP-GGUF", MODEL_URL]]
    for it in lnk
        gAbout.AddLink("w548 y+6", '<a href="' . it[2] . '">' . it[1] . "</a>")
    gAbout.AddText("w548 y+12 c404040",
        en ? "Licence: MIT (patches and launcher); model weights keep their own licence."
           : "许可：MIT（补丁与启动器同许可；模型权重遵循其自身许可）")
    gAbout.AddButton("x14 y+14 w110 h28", en ? "Copy diagnostics" : "复制诊断信息").OnEvent("Click", (*) => (
        A_Clipboard := AboutText(),
        ToolTip(en ? "Copied" : "已复制"),
        SetTimer(() => ToolTip(), -1500)))
    gAbout.AddButton("x+8 w120 h28", en ? "Engine folder" : "打开引擎目录").OnEvent("Click", (*) => OpenPath(ROOT))
    gAbout.AddButton("x+8 w120 h28", en ? "Logs folder" : "打开日志目录").OnEvent("Click", (*) => OpenPath(RESULTS))
    gAbout.AddButton("x+8 w90 h28 Default", en ? "Close" : "关闭").OnEvent("Click", (*) => gAbout.Destroy())
    gAbout.OnEvent("Close", (*) => gAbout.Destroy())
    gAbout.OnEvent("Escape", (*) => gAbout.Destroy())
    gAbout.Show("AutoSize Center")
}

; 切换语言：存 INI，然后两个窗口一起重建（参数集合从界面上收集，不丢设置）

SetLang(v, show := true) {
    global gLang, gIgnoreIni
    new := (v = "") ? DetectLang() : v
    if (new = gLang)
        return
    gLang := new
    if !gIgnoreIni
        SaveLang(new)          ; 自检时别改用户的 ini
    RebuildUi(show)
}

RebuildUi(show := true) {
    global gPro, gSimple, gUiMode, gRebuilding
    gRebuilding := true                        ; 定时器/按钮在这期间一律不动窗口
    mode := gUiMode, cur := ""
    try {
        cur := CollectCurrent()                ; 先把值收集下来（此时控件还活着）
        mode := gUiMode
        try gPro.Destroy()
        try gSimple.Destroy()
        gPro := BuildGui()
        gSimple := BuildSimpleGui()
        gUiMode := mode
        SetCurrent(cur)
        UpdateDerived()
    } finally {
        gRebuilding := false
    }
    if show {
        if (gUiMode = "simple")
            gSimple.Show("w" . SIMPLE_W . " h" . SIMPLE_H)
        else
            gPro.Show("w" . PRO_W . " h" . PRO_H)
    }
    RefreshStatus()                            ; 放闸门之后再刷新（它会读控件）
}

; 语言自检：EN 模式下遍历两个窗口的所有控件，断言不含中文；再切回 zh 断言还原

I18ntest() {
    global gLang, gPro, gSimple, gUiMode, I18NLOG, BASE_CFG
    gLang := "en"
    gPro := BuildGui()
    gSimple := BuildSimpleGui()
    rep := [], ok := 0, fail := 0
    cjk := 0, samples := []
    for g in [gPro, gSimple] {
        for c in g {
            try {
                t := c.Text
                if (t = "")
                    continue
                if RegExMatch(t, "[\x{4e00}-\x{9fff}]") {
                    cjk++
                    if (samples.Length < 12)
                        samples.Push(t)
                }
            }
        }
    }
    FT(rep, "EN 模式下控件不含中文（残留 " . cjk . " 处）", cjk = 0, Join(samples, " | "))
    ; 抽检动态文案
    checks := [["启动", "Start"], ["长模式（长上下文）", "Long (big context)"],
               ["运行状态: -", "Status: -"], ["停止", "Stop"], ["预览(--check)", "Preview (--check)"]]
    bad := []
    for c in checks
        if (Tf(c[1]) != c[2])
            bad.Push(c[1] . "->" . Tf(c[1]))
    FT(rep, "关键文案翻译正确", bad.Length = 0, Join(bad, " | "))
    ; 未收录的串原样返回（不会吃字符）
    FT(rep, "未收录串原样返回", Tf("未收录的测试串") = "未收录的测试串", Tf("未收录的测试串"))
    ; 英文串不被二次破坏
    FT(rep, "英文串不被改写", Tf("Already English") = "Already English", Tf("Already English"))
    ; 动态文案（弹窗 / 状态行 / 确认框）：这些是"拼出来的"，控件检查覆盖不到
    dyn := []
    pfBad := PreflightNoDlg({mode: "short", ctx: 999999, kv: "k8v4", resident: 0, mtp: "on", draft: "en",
                             reserve: 256, port: 1339, cors: "*", thinking: "on", preserve: "on"})
    dyn.Push(["preflight", pfBad.msg])
    dyn.Push(["boundary", BoundaryText({mode: "long", ctx: 81920, kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "on"})])
    dyn.Push(["state-loading", StateLine({state: "loading", port: 1339, nCtx: 0, mode: "short", sleeping: "",
        alias: "", http: {ok: true, status: 503}, ram: {free: 100, total: 100},
        procs: {engine: [], serve: [], driver: [], guard: [], launcher: 0}}).text])
    dyn.Push(["state-zombie", StateLine({state: "zombie", port: 1339, nCtx: 0, mode: "", sleeping: "",
        alias: "", http: {ok: true, status: 503}, ram: {free: 100, total: 100},
        procs: {engine: [], serve: [], driver: [], guard: [], launcher: 0}}).text])
    dyn.Push(["stop-confirm", StopConfirmText()])
    dyn.Push(["badge-loading", StateBadge({state: "loading"}).word])
    leftoverDyn := []
    for it in dyn {
        t := Tf(it[2])
        if RegExMatch(t, "[\x{4e00}-\x{9fff}]")
            leftoverDyn.Push(it[1] . " -> " . t)
    }
    FT(rep, "动态文案（预检/边界/状态/确认框/状态图）EN 后无中文", leftoverDyn.Length = 0,
        Join(leftoverDyn, " | "))
    rep.Push("")                                    ; 下面是实际渲染出来的英文，人工过一眼
    for it in dyn
        rep.Push("  [" . it[1] . "] " . StrReplace(Tf(it[2]), "`n", " / "))
    ; PackProblem / EnvProblems：整句双语的动态文案（曾经靠片段替换，英文变夹生饭）
    savedCfg3 := BASE_CFG
    tmpCfg3 := A_Temp . "\strata-i18n-pack.json"
    try FileDelete(tmpCfg3)
    FileAppend('{"args": []}', tmpCfg3, 'UTF-8')          ; 模板里没有 --pack
    BASE_CFG := tmpCfg3
    pkNone := PackProblem({native: "Some-Model-UD-Q9_K.gguf"})
    BASE_CFG := savedCfg3
    pkBad := PackProblem({native: "Some-Model-UD-Q9_K.gguf"})   ; 模板的 pack 指向别的模型
    try FileDelete(tmpCfg3)
    envFake := EnvProblems("7.5")                          ; 造一张 sm_75 的卡，走到"自己编译"那条
    texts3 := [["pack-no-pack", pkNone], ["pack-mismatch", pkBad]]
    for m in envFake.hard
        texts3.Push(["env-hard", m])
    for m in envFake.soft
        texts3.Push(["env-soft", m])
    bad3 := []
    for it in texts3 {
        if RegExMatch(it[2], "[\x{4e00}-\x{9fff}]")
            bad3.Push(it[1] . " -> " . it[2])
    }
    FT(rep, "PackProblem / EnvProblems 的 EN 文案无中文", bad3.Length = 0, Join(bad3, " | "))
    rep.Push("")
    for it in texts3
        rep.Push("  [" . it[1] . "] " . it[2])
    ; 切回中文：控件应重新出现中文
    gLang := "zh"
    try gPro.Destroy()
    try gSimple.Destroy()
    gPro := BuildGui()
    gSimple := BuildGui()   ; 只为数控件，稍后销毁
    zh := 0
    for c in gPro {
        try {
            t := c.Text
            if (t != "" && RegExMatch(t, "[\x{4e00}-\x{9fff}]"))
                zh++
        }
    }
    FT(rep, "zh 模式下中文回来了（" . zh . " 个控件）", zh > 20, "")
    try gPro.Destroy()
    try gSimple.Destroy()
    ok := 0, fail := 0
    for line in rep {
        if (SubStr(line, 1, 6) = "[ OK ]")
            ok++
        else if (SubStr(line, 1, 6) = "[FAIL]")
            fail++
    }
    if FileExist(I18NLOG)
        FileDelete(I18NLOG)
    for line in rep
        FileAppend(line . "`n", I18NLOG, "UTF-8")
    FileAppend("`n-- " . ok . " OK / " . fail . " FAIL`n  结果见：" . I18NLOG . "`n", I18NLOG, "UTF-8")
    ExitApp(fail = 0 ? 0 : 1)
}

; ---------------------------------------------------------------- 0b. 自检：定位
; 造假目录树，验证 FindEngineIn / ResolveEngineRoot 的判断，不碰全局变量。
; （AHK v2 不支持嵌套函数，所以判定逻辑抽成 FT()）

FT(rep, label, cond, detail := "") {
    rep.Push((cond ? "[ OK ] " : "[FAIL] ") . label . (detail != "" ? "  :: " . detail : ""))
    return cond ? 1 : 0
}

Findtest() {
    global
    t := A_Temp . "\strata-findtest"
    if DirExist(t)
        DirDelete(t, true)
    rep := []
    ok := 0, fail := 0
    ; 1) 检出布局：<t>\checkout\strata\engine-cuda12\strata.exe + tools/results
    DirCreate(t . "\checkout\strata\engine-cuda12")
    FileAppend("", t . "\checkout\strata\engine-cuda12\strata.exe")
    DirCreate(t . "\checkout\tools")
    DirCreate(t . "\checkout\results")
    FileAppend("", t . "\checkout\tools\strata-run.py")
    e := FindEngineIn(t . "\checkout")
    FT(rep, "检出布局能找到 exe", e != "", e)
    r := ResolveEngineRoot(e)
    FT(rep, "检出布局 ROOT = ...\strata", r.root = t . "\checkout\strata", r.root)
    FT(rep, "检出布局 HOME = ...\checkout", r.home = t . "\checkout", r.home)
    ; 2) 便携布局：strata.exe 就在根目录，旁边有 serve
    DirCreate(t . "\portable\serve")
    FileAppend("", t . "\portable\strata.exe")
    FileAppend("", t . "\portable\serve\server.py")
    e2 := FindEngineIn(t . "\portable")
    FT(rep, "便携布局能找到 exe", e2 = t . "\portable\strata.exe", e2)
    r2 := ResolveEngineRoot(e2)
    FT(rep, "便携布局 ROOT = 该目录", r2.root = t . "\portable", r2.root)
    FT(rep, "便携布局 HOME = ROOT（无 tools/results）", r2.home = t . "\portable", r2.home)
    ; 3) exe 在两层子目录里
    DirCreate(t . "\deep\a\b")
    FileAppend("", t . "\deep\a\b\strata.exe")
    FT(rep, "两层子目录能找到", FindEngineIn(t . "\deep") = t . "\deep\a\b\strata.exe")
    ; 4) 空目录不误命中
    DirCreate(t . "\empty")
    FT(rep, "空目录返回空", FindEngineIn(t . "\empty") = "")
    ; 5) ParentDir 边界
    FT(rep, "ParentDir 普通", ParentDir("D:\a\b\c") = "D:\a\b", ParentDir("D:\a\b\c"))
    FT(rep, "ParentDir 盘根", ParentDir("D:\a") = "D:", ParentDir("D:\a"))
    FT(rep, "ParentDir 只在盘符", ParentDir("D:") = "D:", ParentDir("D:"))
    FT(rep, "BaseName 认反斜杠", BaseName("D:\a\b.gguf") = "b.gguf", BaseName("D:\a\b.gguf"))
    FT(rep, "BaseName 认正斜杠", BaseName("E:/m/x/y.gguf") = "y.gguf", BaseName("E:/m/x/y.gguf"))
    FT(rep, "BaseName 对裸文件名原样返回", BaseName("z.gguf") = "z.gguf", BaseName("z.gguf"))
    ; 6) 真实环境：本机应该能定位到引擎
    FT(rep, "本机定位到 strata.exe", gLocated, EXE)
    FT(rep, "定位到的 exe 真的存在", FileExist(EXE), EXE)
    FT(rep, "EXE 是 .exe（名字不限：自编译的可以任意命名）", SubStr(StrLower(EXE), -4) = ".exe", EXE)
    FT(rep, "定位来源非空", gLocateHow != "", gLocateHow)
    DirDelete(t, true)
    ok := 0, fail := 0
    for line in rep
        (SubStr(line, 1, 6) = "[ OK ]") ? ok++ : fail++
    if FileExist(FINDLOG)
        FileDelete(FINDLOG)
    for line in rep
        FileAppend(line . "`n", FINDLOG, "UTF-8")
    FileAppend("`n-- " . ok . " OK / " . fail . " FAIL`n  结果见：" . FINDLOG . "`n", FINDLOG, "UTF-8")
    ExitApp(fail = 0 ? 0 : 1)
}

; 界面值 -> 引擎参数
; 切模式时 MTP 下拉框的选项要换（短 = gpu/off，长 = cpu/off）。
; AHK v2 的 DDL 没有 GetCount，所以自己记一份当前列表（gMtpList）。

RefreshMtpList(ddl, mode) {
    global MTP_LIST_SHORT, MTP_LIST_LONG, gMtpList
    want := (mode = "long" ? MTP_LIST_LONG : MTP_LIST_SHORT)
    if (gMtpList.Length = want.Length) {
        same := true
        Loop want.Length {
            if (gMtpList[A_Index] != want[A_Index])
                same := false
        }
        if (same)
            return
    }
    ddl.Delete()
    for v in want
        ddl.Add([v])            ; Add 要数组
    gMtpList := want.Clone()
}

; --spec 与 MTP 专家位置是配套量出来的：gpu=3（IQ3_S 短模式 24.7 tok/s），cpu=2（长模式/IQ4_XS）

SpecForMtp(mtpMode, mode) {
    if (mtpMode = "cpu")
        return "2"
    if (mtpMode = "gpu")
        return "3"
    return (mode = "long" ? "2" : "3")       ; off 时 spec 只要 >= 2（native pack 的硬要求）
}

MtpModeToParams(mode) {
    global MTP_LIST_SHORT, MTP_LIST_LONG
    v := (mode = "long" ? MTP_LIST_LONG : MTP_LIST_SHORT)
    return {on: v[1], off: "off"}
}

global DRAFT_LIST := ["full", "cjk", "cyrillic", "fr", "en"]   ; full = 全集（默认；en 子集对代码/中文吃亏）
global YN_LIST := ["on", "off"]
global VISION_LIST := ["off", "cpu", "gpu"]   ; 图片编码器：off / cpu（不占显存）/ gpu（~1.2GB）

; ------------------------------------------------- 1. 模式预置 + 实测边界
; 短模式 = 原 run-strata-qwen36.bat；长模式 = 原 run-strata-qwen36-long.bat

ModePreset(mode) {
    ; 长模式 = 实测最优：KV 全常驻（不开流式）、reserve 64、MTP 关、preserve-thinking on
    ; ctx 81920 是**选定的**工作点（不是上限）：2026-11-24 重测本机上限为 139264 可启动 / 147456 被拒；
    ; 选 81920 是为了配合 pi 的 reserveTokens 16384 —— 实际干活上下文落在 65536（模型 64k 召回 ~70% 那一档），
    if (mode = "long")
        return {mode: "long", ctx: 81920, kv: "k8v4", resident: 0, residentRaw: "0", mtp: "on",
                draft: "full", reserve: 64, port: 1339, cors: "*", thinking: "on", preserve: "on",
                mtp_cpu_moe: "on", spec: "2", mtp_mode: "cpu", chat_template: "", dry: "0",
                tag: "long", host: "", apikey: "",
                temperature: "0.6", top_p: "0.95", top_k: "20",
        min_p: "", presence_penalty: "", repetition_penalty: "",
        vision: "off", vision_tokens: "300", template: "strata-qwen36-iq3s.json",
        native: "", mmproj: "",
                title: "Strata LONG - Qwen3.6-35B-A3B UD-IQ3_S (81920 KV / 64K working, all-resident, no MTP)"}
    return {mode: "short", ctx: 20480, kv: "k8v4", resident: 0, residentRaw: "0", mtp: "on",
            draft: "full", reserve: 64, port: 1339, cors: "*", thinking: "on", preserve: "on",
            mtp_cpu_moe: "off", spec: "3", mtp_mode: "gpu", chat_template: "", dry: "0",
            tag: "", host: "", apikey: "",
            temperature: "0.6", top_p: "0.95", top_k: "20",
        min_p: "", presence_penalty: "", repetition_penalty: "",
        vision: "off", vision_tokens: "300", template: "strata-qwen36-iq3s.json",
        native: "", mmproj: "",
            title: "Strata - Qwen3.6-35B-A3B UD-IQ3_S"}
}

; 补齐字段：任何参数对象进函数前都过这一道，避免 "no property named Xxx" 直接把界面/自检打断

Prop(o, k, d := "") {
    if !IsObject(o)
        return d
    return o.HasOwnProp(k) ? o.%k% : d
}

; Map 和对象都能安全取值（提醒参数是 Map，属性对象来自 capacity）
Mget(o, k, d := "") {
    if !IsObject(o)
        return d
    if (Type(o) = "Map")
        return o.Has(k) ? o[k] : d
    return o.HasOwnProp(k) ? o.%k% : d
}

HasArg(flag) {                          ; 命令行开关（--ontop / --selftest / --guismoke）
    for a in A_Args
        if (a = flag)
            return true
    return false
}

BaseName(p) {                           ; D:\a\b.exe -> b.exe（配置/nvidia-smi 里 / 和 \ 都可能出现）
    if (p = "")
        return ""
    p := StrReplace(p, "/", "\\")       ; 归一化，否则正斜杠路径会被整个当成文件名
    return RegExReplace(p, "^.*\\", "")
}

; 只接受白名单里的值，其它一律回落到默认（防 ini 里写了不在列表里的档位）

InList(v, list, def) {
    for it in list
        if (v = it)
            return it
    return def
}

; 读下拉框：没选中时回落默认值，绝不把空串喂给命令行

DdlText(ctrl, def) {
    t := Trim(ctrl.Text)
    return (t = "" ? def : t)
}

; 模板配置里是否已经有“真”的 vision.mmproj（忽略未展开的 %占位符%）

TemplateHasMmproj() {
    global BASE_CFG
    if (BASE_CFG = "" || !FileExist(BASE_CFG))
        return false
    try {
        s := FileRead(BASE_CFG, "UTF-8")
        if (RegExMatch(s, '"mmproj"\s*:\s*"([^"]*)"', &m))
            return (Trim(m[1]) != "" && !InStr(m[1], "%"))
    }
    return false
}

; 模板配置里是否已经有一个“真”的 --native（不是空、也不是未展开的 %占位符%）
; 用来避免“用户没选 GGUF 但其实模板已经指定了”这种假警报。

TemplateHasNative() {
    global BASE_CFG
    if (BASE_CFG = "" || !FileExist(BASE_CFG))
        return false
    try {
        s := FileRead(BASE_CFG, "UTF-8")
        if (RegExMatch(s, '"--native"\s*,\s*"([^"]*)"', &m))
            return (Trim(m[1]) != "" && !InStr(m[1], "%"))
    }
    return false
}

; 选 GGUF（覆盖 --native；换模型文件时 pack 也要匹配，通常同时换模板）
; 视觉下拉框的可用性：没有 mmproj（且模板里也没有）时置灰并强制 off，
; 免得用户选了 cpu 却又被 Normalize 静静改回 off。

UpdateVisionEnabled() {
    global visD, sVisD, mmprojE, sMmprojE
    have := false
    if (IsObject(mmprojE) && Trim(mmprojE.Value) != "")
        have := true
    if (IsObject(sMmprojE) && Trim(sMmprojE.Value) != "")
        have := true
    if (!have && TemplateHasMmproj())
        have := true
    if IsObject(visD) {
        visD.Enabled := have
        if !have
            visD.Text := "off"
    }
    if IsObject(sVisD) {
        sVisD.Enabled := have
        if !have
            sVisD.Text := "off"
    }
}

; ---------------------------------------------------------------- 0d. pack 发现与校验
; pack 是"稠密权重 + 索引 + tokenizer + 专家偏移表"，一个 GGUF 一个 pack（约 65 MB，3 秒能造）。
; 换量化必须同时换 pack：native_experts.txt 头里写明了它指向哪个 GGUF 文件，我们靠这个匹配。
TemplatePack() {                          ; 模板里的 --pack（未展开的 %变量% 视为没有）
    global BASE_CFG
    if (BASE_CFG = "" || !FileExist(BASE_CFG))
        return ""
    try {
        if (RegExMatch(FileRead(BASE_CFG, "UTF-8"), '"--pack"\s*,\s*"([^"]*)"', &m)) {
            v := Trim(m[1])
            return (v != "" && !InStr(v, "%")) ? v : ""
        }
    }
    return ""
}

PackHeaderGguf(packDir) {                 ; native_experts.txt 第一行 -> 它指向的 GGUF 文件名
    f := packDir . "\native_experts.txt"
    if !FileExist(f)
        return ""
    try {
        head := StrSplit(FileRead(f, "UTF-8"), "`n")[1]
        if RegExMatch(head, "absolute offsets in ([^,;)]+)", &m)
            return Trim(m[1])
    }
    return ""
}

PacksRoot() {                             ; pack 根目录：模板 --pack 的上一级；否则 <HOME>\packs
    global DEV
    p := TemplatePack()
    if (p = "")
        return DEV . "\packs"
    p := StrReplace(p, "/", "\")      ; 模板里的路径可能是正斜杠
    return ParentDir(p)
}

FindPackFor(gguf, rootOverride := "") {    ; 只认 native_experts.txt 头里点名的那个 GGUF（按名字猜会配错）
    packsDir := (rootOverride != "") ? rootOverride : PacksRoot()
    if (gguf = "" || !DirExist(packsDir))
        return ""
    want := StrLower(BaseName(gguf))
    loop files, packsDir . "\*", "D" {
        if (StrLower(PackHeaderGguf(A_LoopFileFullPath)) = want)
            return A_LoopFileFullPath
    }
    return ""
}

EffectivePack() {                         ; 本次实际会用的 pack
    global gPack
    return (gPack != "") ? gPack : TemplatePack()
}

PackProblem(o) {                           ; "" = 没问题；否则是要提醒的原因（整句双语，不走片段替换）
    global gLang
    en := (gLang = "en")
    native := Prop(o, "native", "")
    if (native = "")
        return ""                         ; 完全没指定 GGUF 由另一条提醒负责
    global gPack
    pack := EffectivePack()
    ; 模板里的 --pack 往往还是别的模型的（IQ3_S），而服务端早已按 GGUF 名建好了这个模型的那份：
    ; 先按 native_experts.txt 头里的文件名去找，找到就用它，别每次启动都喊"不匹配"。
    if (pack = "" || StrLower(PackHeaderGguf(pack)) != StrLower(BaseName(native))) {
        if (pk := FindPackFor(native)) {
            gPack := pk
            pack := pk
        }
    }
    if (pack = "")
        return en ? ("no pack yet for " . BaseName(native) . ": the server builds one at start (~3 s / 65 MB)")
                  : ("这个 GGUF 还没有 pack：启动时由服务端自动生成（约 3 秒 / 65 MB）")
    if !DirExist(pack)
        return en ? ("pack directory missing: " . pack) : ("pack 目录不存在: " . pack)
    named := PackHeaderGguf(pack)
    if (named != "" && StrLower(named) != StrLower(BaseName(native)))
        return en ? ("the pack does not match this model (the pack points at " . named
                     . "): the server rebuilds it at start (~3 s)")
                  : ("pack 与模型不匹配（pack 指向「" . named . "」）：启动时服务端会自动重建（约 3 秒）")
    return ""
}

; ---------------------------------------------------------------- 0e. 运行环境自检
; Release 的 strata.exe 是 sm_86 + CUDA 12.x 编的：缺 DLL 或卡不是 86 时，引擎只会给一句
; 含糊的 CUDA 错误。这里提前查清楚，给出可操作的提示。

CudaDlls() {
    global EXE
    out := {cudart: "", cublas: "", where: ""}
    for name in ["cudart64_12.dll", "cublas64_12.dll"] {
        found := ""
        if (EXE != "" && FileExist(ParentDir(EXE) . "\" . name))
            found := ParentDir(EXE)
        if (found = "") {
            for d in StrSplit(EnvGet("PATH"), ";") {
                if (d != "" && FileExist(d . "\" . name)) {
                    found := d
                    break
                }
            }
        }
        if (found = "") {
            loop files, "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12*\bin\" . name
                found := ParentDir(A_LoopFileFullPath)
        }
        if (name = "cudart64_12.dll")
            out.cudart := found
        else
            out.cublas := found
    }
    out.where := (out.cudart != "") ? out.cudart : out.cublas
    return out
}

; GPU 的计算能力（8.6 = sm_86）。拿不到返回 ""。

GpuComputeCap() {
    ; 会话内只查一次：nvidia-smi 一次约 700 ms，预检每次都会问（R11 提速的主要来源之一）
    static cached := "", asked := false
    if (asked)
        return cached
    asked := true
    try {
        tmp := A_Temp . "\strata-cap.txt"
        try FileDelete(tmp)
        RunWait(Q(A_ComSpec) . " /c nvidia-smi --query-gpu=compute_cap --format=csv,noheader > " . Q(tmp) . " 2>nul", , "Hide")
        if FileExist(tmp) {
            cached := Trim(FileRead(tmp, "UTF-8"), " `t`r`n")
            try FileDelete(tmp)
        }
    }
    return cached
}

; 环境问题列表：缺 DLL 是硬伤（引擎起不来），架构不是 86 只是警告（可以自己重编）。

EnvProblems(capOverride := "") {
    ; 会话内缓存 60 秒：扫 PATH 找 CUDA DLL + 问显卡架构（nvidia-smi ~700 ms），预检每次都调
    static cache := Map()
    global gLang
    ck := (capOverride . "|" . gLang)
    if (cache.Has(ck) && (A_TickCount - cache[ck].ts < 60000))
        return cache[ck].v
    en := (gLang = "en")
    env := {hard: [], soft: []}
    d := CudaDlls()
    if (d.cudart = "")
        env.hard.Push(en ? "cudart64_12.dll not found: install CUDA Toolkit 12.x, or point the config lib_dirs at its bin"
                         : "缺 cudart64_12.dll：装 CUDA Toolkit 12.x，或把配置里的 lib_dirs 指到它的 bin")
    if (d.cublas = "")
        env.hard.Push(en ? "cublas64_12.dll not found: same fix as cudart64_12.dll"
                         : "缺 cublas64_12.dll：同上")
    cap := (capOverride != "") ? capOverride : GpuComputeCap()
    if (cap != "" && cap != "8.6") {
        env.soft.Push(en
            ? ("this release is built for sm_86; this card is compute " . cap . ", so it may report no kernel image -- build your own with " . ArchFlagFor(cap))
            : ("本 Release 的引擎是 sm_86 编的，这块卡是 compute " . cap . "；可能报「no kernel image」。按 README「自己编译」用 " . ArchFlagFor(cap) . " 编一份"))
    }
    cache[ck] := {v: env, ts: A_TickCount}
    return env
}

; 引擎自报的版本（`strata.exe --version` -> "strata 0.1.43"），读不到就返回 ""

EngineVersion() {
    global EXE
    if (EXE = "" || !FileExist(EXE))
        return ""
    try {
        tmp := A_Temp . "\strata-ver.txt"
        try FileDelete(tmp)
        inner := Q(EXE) . " --version > " . Q(tmp) . " 2>nul"
        RunWait(Q(A_ComSpec) . " /c " . Q(inner), , "Hide")
        if FileExist(tmp) {
            v := Trim(FileRead(tmp, "UTF-8"), " `t`r`n")
            try FileDelete(tmp)
            if InStr(v, "strata")
                return v
        }
    }
    return ""
}

; 让用户指定自己的 strata.exe（自己编译的那份），记进 ini 的 [ui] exe

PickEngine() {
    global INI
    start := (EXE != "" && FileExist(EXE)) ? EXE : ""
    f := FileSelect(1, start, "选 strata.exe（自己编译的也可以）", "strata.exe|所有文件 (*.*)")
    if (f = "")
        return
    try IniWrite(f, INI, "ui", "exe")
    Notify("info", Tf("已记住这个引擎：") . f . Tf("；重启启动器后生效"))
}

; 按 GPU 的 compute_cap 给出该用的 -DCMAKE_CUDA_ARCHITECTURES 值（8.6 -> 86）

ArchFlagFor(cap) {
    return (cap = "") ? "" : "-DCMAKE_CUDA_ARCHITECTURES=" . StrReplace(StrReplace(cap, ".", ""), " ", "")
}

; 把"用户刚选的模型文件"直接写进 ini 的当前模式节点（SaveIni 只在关窗口时跑，被 kill 就丢）

RememberModel(key, val) {
    global INI
    try {
        sec := (Prop(CollectCurrent(), "mode", "short") = "long" ? "long" : "short")
        IniWrite(val, INI, sec, key)
    }
}

PickNative() {
    global nativeE, sNativeE
    ; 两个界面各有一份展示框：起始目录取其中已经选过的那个
    cur := ""
    if IsObject(sNativeE) && Trim(sNativeE.Value) != ""
        cur := Trim(sNativeE.Value)
    else if IsObject(nativeE) && Trim(nativeE.Value) != ""
        cur := Trim(nativeE.Value)
    start := (cur != "" && FileExist(cur)) ? cur : ""
    f := FileSelect(1, start, "选 GGUF 模型文件（--native）", "GGUF (*.gguf)")
    if (f = "")
        return
    if IsObject(nativeE)
        nativeE.Value := f
    if IsObject(sNativeE)
        sNativeE.Value := f
    ; 换 GGUF 只负责"告诉服务层用哪个模型"：pack 是派生数据，由 serve/prepare.py 在引擎启动前
    ; 发现缺失/不匹配时自己生成（约 3 秒）。启动器保持轻量，不跑 python、不写文件。
    global gPack
    RememberModel("native", f)                 ; 立刻记住：进程被 kill 也不会丢这次选择
    pk := FindPackFor(f)
    gPack := (pk != "") ? pk : ""
    if (pk != "") {
        SetStatusText("GGUF: " . BaseName(f) . "  ·  pack: " . BaseName(pk), "000080")
        Tip("GGUF: " . BaseName(f) . "`npack: " . BaseName(pk))
    } else {
        SetStatusText("GGUF: " . BaseName(f) . "  ·  " . Bi("启动时会自动生成 pack（约 3 秒）",
            "the pack is built automatically at start (~3 s)"), "000080")
        Tip("GGUF: " . BaseName(f) . "`n启动时会自动生成 pack")
    }
}

PickMmproj() {
    global mmprojE, sMmprojE, visD, sVisD
    cur := ""
    if IsObject(sMmprojE) && Trim(sMmprojE.Value) != ""
        cur := Trim(sMmprojE.Value)
    else if IsObject(mmprojE) && Trim(mmprojE.Value) != ""
        cur := Trim(mmprojE.Value)
    start := (cur != "" && FileExist(cur)) ? cur : ""
    f := FileSelect(1, start, "选视觉编码器 mmproj", "GGUF (*.gguf)")
    if (f = "")
        return
    if IsObject(mmprojE)
        mmprojE.Value := f
    if IsObject(sMmprojE)
        sMmprojE.Value := f
    RememberModel("mmproj", f)
    ; 选了 mmproj 说明要用视觉：如果当前是 off，默认切成 cpu（用户之后仍可自己改回去）
    if IsObject(visD) && DdlText(visD, "off") = "off"
        visD.Text := "cpu"
    if IsObject(sVisD) && DdlText(sVisD, "off") = "off"
        sVisD.Text := "cpu"
    UpdateVisionEnabled()
    Tip("mmproj: " . BaseName(f))
}

; 选 chat 模板文件（覆盖 pack 里的 chat_template.jinja；留空 = 用 pack 自带的）

PickChatTpl() {
    global chatTplE
    cur := Trim(chatTplE.Value)
    start := (cur != "" && FileExist(cur)) ? cur : TPL_DIR
    f := FileSelect(1, start, "选 chat 模板（jinja）", "Jinja (*.jinja;*.jinja2;*.txt)|所有文件 (*.*)")
    if (f = "")
        return
    chatTplE.Value := f
    Tip("模板: " . BaseName(f) . "（重启后生效，缓存会失效）")
}

Normalize(o) {
    n := {}
    n.mode := Prop(o, "mode", "short")
    n.ctx := Prop(o, "ctx", 20480)
    n.kv := Prop(o, "kv", "k8v4")
    n.resident := Prop(o, "resident", 0)
    n.residentRaw := Prop(o, "residentRaw", "")      ; "" = 留空（不写这个 flag）
    n.mtp := Prop(o, "mtp", "on")
    n.draft := Prop(o, "draft", "full")
    n.reserve := Prop(o, "reserve", 256)
    n.port := Prop(o, "port", 1339)
    n.cors := Prop(o, "cors", "*")
    n.thinking := Prop(o, "thinking", "on")
    n.preserve := Prop(o, "preserve", "on")
    n.tag := Prop(o, "tag", "")
    n.host := Prop(o, "host", "")
    n.apikey := Prop(o, "apikey", "")
    n.temperature := Prop(o, "temperature", "0.6")
    n.top_p := Prop(o, "top_p", "0.95")
    n.top_k := Prop(o, "top_k", "20")
    n.template := Prop(o, "template", "strata-qwen36-iq3s.json")
    n.native := Prop(o, "native", "")
    n.mmproj := Prop(o, "mmproj", "")
    n.pack := Prop(o, "pack", "")          ; 找到的 pack 目录（空 = 用模板里的 --pack）
    n.dry := Prop(o, "dry", "")
    n.chat_template := Prop(o, "chat_template", "")
    ; mtp_mode 是唯一真相源（下拉框：gpu / cpu / off），由它派生 mtp 与 mtp_cpu_moe：
    ;   gpu -> --mtp + 专家在显存；cpu -> --mtp + --mtp-cpu-moe 1；off -> 不给 --mtp（保留 --spec）
    n.mtp_mode := InList(Prop(o, "mtp_mode", "gpu"), ["gpu", "cpu", "off"], "gpu")
    n.mtp := (n.mtp_mode = "off" ? "off" : "on")
    n.mtp_cpu_moe := (n.mtp_mode = "cpu" ? "on" : "off")
    n.spec := Prop(o, "spec", "")
    n.vision := Prop(o, "vision", "off")
    n.vision_tokens := Prop(o, "vision_tokens", "300")
    ; 视觉默认值只跟「有没有 mmproj」走：没有 → off（不报错、也不白白起一个编码器）；
    ; 有（自己选的或模板里写好的真路径）→ cpu（不占显存）。
    if (n.mmproj = "" && !TemplateHasMmproj())
        n.vision := "off"
    n.min_p := Prop(o, "min_p", "")
    n.presence_penalty := Prop(o, "presence_penalty", "")
    n.repetition_penalty := Prop(o, "repetition_penalty", "")
    n.title := Prop(o, "title", "Strata")
    return n
}

; 与驱动里的 MEASURED / MEASURED_STREAM 保持同一张表（能启动, 首个被拒）

; 边界 = 这台机器 + 这个量化 + 这个 (kv/resident/mtp/cpumoe) 的**实测标定**（启动一次后由日志算出）。
; 没有标定就返回 measured=false —— 宁可界面上空着，也不套用别的量化/机器测出来的数字。
; 边界来自服务端按「这个 GGUF 的元数据 + 这台机器的显存」算出的预估值（capacity 文件里的
; ctx_estimate / ctx_suggested）：模型换了、量化换了，权重/专家字节跟着变，所以是模型感知的。
; 没有这份文件（第一次跑、或换了新模型还没启动）就返回 measured=false，界面留空不给数字。
Boundary(kv, resident, mtp, cpuMoe := "", native := "") {
    key := kv . "/" . resident . "/" . mtp . (cpuMoe = "on" ? "/cpumoe" : "")
    if (native != "") {
        ci := CapacityInfo(native, kv, MtpSlug(mtp, cpuMoe))
        if (IsObject(ci) && ci.ctx > 0)
            return {ok: ci.ctx, no: 0,
                    rec: (ci.suggest > 0 ? ci.suggest : ci.ctx), key: key, measured: true}
    }
    return {ok: 0, no: 0, rec: 0, key: key, measured: false}
}

BoundaryExceeded(o) {
    o := Normalize(o)
    b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"), Prop(o, "native", ""))
    return b.measured && o.ctx > b.ok
}

; 边界行只给两个数：**上限**（服务端按模型元数据 + 显存算的）和**建议**（保留 5% 专家槽的那个 ctx）。
; 没有 capacity 文件（新装 / 换了模型还没启动）就明说没有数据，不套用别的量化测出来的值。
BoundaryText(o) {
    global gLang
    o := Normalize(o)
    en := (gLang = "en")
    mode := (o.mode = "long" ? (en ? "long" : "长模式") : (en ? "short" : "短模式"))
    b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"), Prop(o, "native", ""))
    if !b.measured
        return mode . " · " . (en
            ? "no data yet: one start derives the ceiling and the suggestion"
            : "还没有本机数据：启动一次后自动算出上限与建议")
    tail := " · ctx " . o.ctx . " " . (o.ctx <= b.ok ? (en ? "ok" : "可启动") : (en ? "OVER the ceiling" : "超过上限"))
    head := mode . " · " . (en ? "ceiling " : "上限 ") . b.ok
    if (b.rec > 0 && b.rec < b.ok)
        head .= " · " . (en ? "suggested " : "建议 ") . b.rec
    return head . " · ctx " . o.ctx . " " . (o.ctx <= b.ok ? (en ? "ok" : "可启动") : (en ? "OVER the ceiling" : "超过上限"))
}

; ------------------------------------------- 2. 参数校验 / 命令行构造

ValidateNumbers(o) {
    o := Normalize(o)
    if (o.ctx <= 0)
        return {ok: false, msg: "ctx 必须是正整数"}
    if (o.port < 1 || o.port > 65535)
        return {ok: false, msg: "port 必须在 1-65535"}
    if (o.reserve < 0)
        return {ok: false, msg: "vram-reserve-mib 不能为负"}
    if (o.resident != 0 && o.resident < 20480)
        return {ok: false, msg: "kv-resident 只能是 0（关闭流式）或 >= 20480（引擎下限）"}
    ; 预估值只是参考：不据此硬拒（引擎启动时会用精确的 MiB 差告诉你该降多少），
    ; 否则换个量化/换张卡就会把本来能跑的 ctx 拦下来。
    return {ok: true, msg: ""}
}

; ── 中间层（strata/ctl）：参数归一化的唯一真相源 ────────────────────────────
; 把控件值写成 [params] ini 交给 ctl，读回 [resolved]（mtp / mtp_cpu_moe / spec）。
; ctl 不可用（没有 Python，或包里没带 strata/ctl）时退回内置规则并标 source=builtin，
; 保证缺组件时仍能启动，同时让界面知道这次不是权威值。
; 中间层的入口：便携包的嵌入式 Python 带 `python311._pth`，`-m strata.ctl` 找不到包；
; 统一走 strata-ctl.py（它自己把所在目录塞进 sys.path），两种布局都能跑。
; ── 文本宽度与分段装配（R6）─────────────────────────────────────────────────
; 单行控件不会折行，超宽就被裁掉，所以"能显示多少"必须自己量。
; TextPx 用控件自己的字体量真实像素宽（中英混排也准）。

TextPx(hwnd, text) {
    hwnd := IsObject(hwnd) ? hwnd.Hwnd : hwnd      ; 直接传控件也可以
    hdc := DllCall("GetDC", "ptr", hwnd, "ptr")
    if !hdc
        return 0
    hfont := DllCall("SendMessageW", "ptr", hwnd, "uint", 0x31, "ptr", 0, "ptr", 0, "ptr")   ; WM_GETFONT
    old := hfont ? DllCall("SelectObject", "ptr", hdc, "ptr", hfont, "ptr") : 0
    size := Buffer(8, 0)
    ok := DllCall("GetTextExtentPoint32W", "ptr", hdc, "wstr", text, "int", StrLen(text), "ptr", size)
    if old
        DllCall("SelectObject", "ptr", hdc, "ptr", old)
    DllCall("ReleaseDC", "ptr", hwnd, "ptr", hdc)
    return ok ? NumGet(size, 0, "int") : 0
}

; 必显段永远保留；可选段按顺序尽量塞，塞不下的整段丢掉（不留半个词）。
FitSegments(hwnd, mandatory, optional, maxPx) {
    text := mandatory
    for seg in optional {
        if (seg = "")
            continue
        if (TextPx(hwnd, text . seg) <= maxPx)
            text .= seg
    }
    return text
}

; 同一段有"长/短"两种写法时用这个：groups 里的元素可以是字符串（单独一段），
; 也可以是数组（多档写法，取第一个放得下的）。例：草稿接受 92% (1518/1648) -> 草稿接受 92%
FitVariants(hwnd, mandatory, groups, maxPx) {
    text := mandatory
    for g in groups {
        if IsObject(g) {
            for v in g {
                if (v != "" && TextPx(hwnd, text . v) <= maxPx) {
                    text .= v
                    break
                }
            }
        } else if (g != "" && TextPx(hwnd, text . g) <= maxPx) {
            text .= g
        }
    }
    return text
}


CtlBoot() {
    global DEV, ROOT
    for p in [DEV . "\strata-ctl.py", ROOT . "\strata-ctl.py", A_ScriptDir . "\strata-ctl.py"]
        if FileExist(p)
            return p
    return ""
}

; ── 一次调用拿全（R11）────────────────────────────────────────────────────────
; `plan` 本来就在一份 state.ini 里同时写出 [resolved] / [bounds] / [warn.N] / [errors.N]，
; 所以界面**只该调它一次**。之前 CtlResolved / CtlCapacity / CtlWarnList 各起一个 Python
; （实测每次 180~250 ms，带 --env 时 950 ms），点一下"启动"要等 1 秒多才把命令交给驱动。
CtlPlanAll(o, ciT, st) {
    global PY, DEV, ROOT, RESULTS, EXE
    static cache := Map()
    if (PY = "" || !FileExist(PY))
        return 0
    ctlDir := FileExist(DEV . "\strata\ctl") ? DEV : (FileExist(ROOT . "\strata\ctl") ? ROOT : "")
    if (ctlDir = "")
        return 0
    boot := CtlBoot()
    if (boot = "")
        return 0
    nv := Prop(o, "native", "")
    ; 缓存键：只含稳定输入（PID 只看有无、内存按 1 GiB 分桶），否则永远不命中
    key := nv . "|" . o.kv . "|" . o.ctx . "|" . o.port . "|" . o.reserve . "|" . o.resident
        . "|" . Prop(o, "mtp_mode", "gpu") . "|" . Prop(o, "spec", "")
        . "|" . (IsObject(ciT) ? ciT.budget . "/" . ciT.ctx . "/" . ciT.suggest : "-")
        . "|" . (st.procs.engine.Length ? 1 : 0) . (st.procs.serve.Length ? 1 : 0) . (st.procs.guard.Length ? 1 : 0)
        . "|" . (st.ram.total > 0 ? st.ram.total : 0) . "|" . (st.ram.free >= 0 ? Round(st.ram.free / 1024) : -1)
    if cache.Has(key)
        return cache[key]
    inFile := A_Temp . "\strata-ctl-all-in.ini"
    outFile := A_Temp . "\strata-ctl-all-out.ini"
    body := "[params]`r`nmtp_mode=" . Prop(o, "mtp_mode", "gpu") . "`r`nkv=" . o.kv
        . "`r`nctx=" . o.ctx . "`r`nport=" . o.port . "`r`nreserve=" . o.reserve
        . "`r`nkv_resident=" . o.resident . "`r`nspec=" . Prop(o, "spec", "")
        . "`r`nnative=" . nv . "`r`n[facts]`r`nbudget_mib=" . (IsObject(ciT) ? ciT.budget : 0)
        . "`r`nmodel_path=" . nv
        . "`r`nram_total_mb=" . (st.ram.total > 0 ? st.ram.total : 0)
        . "`r`nram_free_mb=" . (st.ram.free >= 0 ? st.ram.free : -1)
        . "`r`nengine_pid=" . (st.procs.engine.Length ? st.procs.engine[1] : 0)
        . "`r`nserve_pid=" . (st.procs.serve.Length ? st.procs.serve[1].pid : 0)
        . "`r`nguard_pid=" . (st.procs.guard.Length ? st.procs.guard[1] : 0) . "`r`n"
    try FileDelete(inFile)
    try FileDelete(outFile)
    try FileAppend(body, inFile, "UTF-8-RAW")
    qt := Chr(34)
    cmd := qt . PY . qt . " -X utf8 " . qt . boot . qt . " plan --ini-in " . qt . inFile . qt
        . " --ini-out " . qt . outFile . qt . " --results " . qt . RESULTS . qt . " --native " . qt . nv . qt
    try RunWait(cmd, ctlDir, "Hide")
    if !FileExist(outFile)
        return 0
    res := Map(
        "resolved", Map("mtp", IniRead(outFile, "resolved", "mtp", ""),
                        "mtp_cpu_moe", IniRead(outFile, "resolved", "mtp_cpu_moe", ""),
                        "spec", IniRead(outFile, "resolved", "spec", ""),
                        "slug", IniRead(outFile, "resolved", "slug", ""),
                        "source", "ctl"),
        "bounds", Map("measured", IniRead(outFile, "bounds", "measured", "false") = "true",
                      "ctx", Integer(IniRead(outFile, "bounds", "ceiling", "0")),
                      "basis", IniRead(outFile, "bounds", "basis", "vram"),
                      "suggest", Integer(IniRead(outFile, "bounds", "suggested", "0")),
                      "budget", Integer(IniRead(outFile, "bounds", "budget", "0")),
                      "slot", Float(IniRead(outFile, "bounds", "slot_mib", "0")),
                      "kvpt", Float(IniRead(outFile, "bounds", "kvpt", "0")),
                      "ceiling", Integer(IniRead(outFile, "bounds", "ceiling_measured", "0"))),
        "warns", [], "errors", [])
    loop {
        sec := "warn." . A_Index
        code := IniRead(outFile, sec, "code", "")
        if (code = "")
            break
        res["warns"].Push(Map("code", code, "hard", IniRead(outFile, sec, "hard", "false") = "true",
            "budget", IniRead(outFile, sec, "p_budget", "0"),
            "ctx", IniRead(outFile, sec, "p_ctx", "0"),
            "ceiling", IniRead(outFile, sec, "p_ceiling", "0"),
            "seen_ctx", IniRead(outFile, sec, "p_seen_ctx", "0"),
            "seen_slots", IniRead(outFile, sec, "p_seen_slots", "0"),
            "target", IniRead(outFile, sec, "p_target", "400"),
            "free", IniRead(outFile, sec, "p_free", "0"),
            "total", IniRead(outFile, sec, "p_total", "0"),
            "need", IniRead(outFile, sec, "p_need", "12288"),
            "abort", IniRead(outFile, sec, "p_abort", "500"),
            "engine", IniRead(outFile, sec, "p_engine", "-"),
            "serve", IniRead(outFile, sec, "p_serve", "-"),
            "pid", IniRead(outFile, sec, "p_pid", "-"),
            "value", IniRead(outFile, sec, "p_value", ""),
            "dll", IniRead(outFile, sec, "p_dll", ""),
            "cap", IniRead(outFile, sec, "p_cap", ""),
            "flag", IniRead(outFile, sec, "p_flag", "")))
    }
    loop {
        sec := "errors." . A_Index
        code := IniRead(outFile, sec, "code", "")
        if (code = "")
            break
        res["errors"].Push(Map("code", code, "hard", true,
            "value", IniRead(outFile, sec, "p_value", ""),
            "dll", IniRead(outFile, sec, "p_dll", ""),
            "cap", IniRead(outFile, sec, "p_cap", ""),
            "flag", IniRead(outFile, sec, "p_flag", ""),
            "detail", IniRead(outFile, sec, "detail", "")))
    }
    cache[key] := res
    return res
}


CtlResolved(o) {
    ; R11：与提醒共用一次 plan（之前各起一个 Python，点启动要多等 ~1 秒）
    o := Normalize(o)
    stub := {ram: {total: 0, free: -1}, procs: {engine: [], serve: [], guard: []}}
    all := CtlPlanAll(o, 0, stub)
    if (!IsObject(all) || all["resolved"]["mtp"] = "" || all["resolved"]["spec"] = "") {
        mode := Prop(o, "mtp_mode", "gpu")
        return Map("mtp", mode = "off" ? "off" : "on",
                   "mtp_cpu_moe", mode = "cpu" ? "on" : "off",
                   "spec", mode = "cpu" ? "2" : "3",
                   "slug", mode = "off" ? "nomtp" : (mode = "cpu" ? "mtpcpu" : "mtpgpu"),
                   "source", "builtin")
    }
    return all["resolved"]
}

; 参数数组：顺序与两个 .bat 完全一致，且只在原 .bat 会出现的位置出现
;   --ctx --kv [--kv-resident] [--mtp off] --vram-reserve-mib --port --cors
;   [--draft-vocab] --thinking --preserve-thinking [--tag long] [--check] [--host] [--api-key]

BuildArgs(o, addCheck) {
    o := Normalize(o)
    a := ["--ctx", String(o.ctx), "--kv", o.kv]
      ; 留空 → 不写（引擎默认 0）；显式 0 → 写 "--kv-resident 0"（0 是合法值，表示全常驻）
      if (Prop(o, "residentRaw", "") != "")
          a.Push("--kv-resident", String(o.resident))
    ; MTP 三项（--mtp / --mtp-cpu-moe / --spec）由中间层 strata/ctl 决定：
    ; 位置仍在这里（保持与 .bat 一致），值来自唯一派生点，界面不再自己推。
    res := CtlResolved(o)
    if (res["mtp"] = "off")
        a.Push("--mtp", "off")
    a.Push("--vram-reserve-mib", String(o.reserve), "--port", String(o.port), "--cors", o.cors)
    if (res["mtp"] = "on")
        a.Push("--draft-vocab", o.draft)
    if (res["mtp_cpu_moe"] = "on")
        a.Push("--mtp-cpu-moe", "1")
    if (res["spec"] != "")
        a.Push("--spec", res["spec"])   ; 驱动用它覆盖模板里的 --spec
    a.Push("--thinking", o.thinking, "--preserve-thinking", o.preserve)
    for x in SamplingArgs(o)
        a.Push(x)
    if (o.tag != "")
        a.Push("--tag", o.tag)
    if (addCheck)
        a.Push("--check")
    if (o.host != "")
        a.Push("--host", o.host)
    if (o.apikey != "")
        a.Push("--api-key", o.apikey)
    if (Prop(o, "template", "") != "")
        a.Push("--base", Prop(o, "template", ""))
    if (Prop(o, "native", "") != "")
        a.Push("--native", Prop(o, "native", ""))
    if (Prop(o, "pack", "") != "")
        a.Push("--pack", Prop(o, "pack", ""))     ; 换 GGUF 时必须同时换 pack
    if (Prop(o, "mmproj", "") != "")
        a.Push("--mmproj", Prop(o, "mmproj", ""))
    if (Prop(o, "chat_template", "") != "")
        a.Push("--chat-template", Prop(o, "chat_template", ""))
    if (Prop(o, "vision", "") != "")
        a.Push("--vision", Prop(o, "vision", ""))
    if (Prop(o, "vision_tokens", "") != "")
        a.Push("--vision-tokens", Prop(o, "vision_tokens", ""))
    return a
}

Q(s) {                                  ; cmd 里给单个参数加引号（空串也保留成空参数）
    return '"' . s . '"'
}

; 采样参数（传给驱动 --temperature/--top-p/...，只非空才发；留空 = 不写 sampling 块）

SamplingArgs(o) {
    o := Normalize(o)
    a := []
    for kv in [["--temperature", "temperature"], ["--top-p", "top_p"], ["--top-k", "top_k"],
               ["--min-p", "min_p"], ["--presence-penalty", "presence_penalty"],
               ["--repetition-penalty", "repetition_penalty"],
                 ["--dry-multiplier", "dry"]] {
        v := Trim(String(Prop(o, kv[2], "")), " `t`r`n")
        if (v != "")
            a.Push(kv[1], v)
    }
    return a
}

ArgsToStr(a) {
    s := ""
    for i, v in a
        s .= (i = 1 ? "" : " ") . (v ~= "^--" ? v : Q(v))
    return s
}

BuildInner(o, addCheck) {               ; 交给 cmd 的内层命令（不含 cmd.exe / title）
    return Q(PY) . " -X utf8 " . Q(DRIVER) . " " . ArgsToStr(BuildArgs(o, addCheck))
}

; 后台启动：不用 /k，不弹控制台窗口；驱动的 stdout/stderr 全部重定向到日志文件
; 引号层次（实测踩过坑）：内层命令必须以引号开头并整体再包一层，cmd 才会按
;   "剥掉最外层那一对引号" 的规则处理 —— 多包一层会变成 """，反而把 python 路径剥坏（rc=1 系统找不到指定的路径）

BuildLaunchCmd(o, addCheck, logPath) {
    return Q(A_ComSpec) . " /c " . Q(BuildInner(o, addCheck) . " > " . Q(logPath) . " 2>&1")
}

; ------------------------------------------------- 3. 状态查询

HttpGet(url, tms := 1500) {
    r := {ok: false, status: 0, body: "", err: ""}
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(tms, tms, tms, tms)
        req.Open("GET", url, false)
        req.Send()
        r.ok := true
        r.status := req.Status
        r.body := req.ResponseText
    } catch as e {
        r.err := e.Message
    }
    return r
}

FindProcs() {
    ; WMI 连接建一次就复用：每次新建 COM 连接要几百毫秒，而预检与状态刷新都调它
    static wmi := 0
    if !IsObject(wmi) {
        try {
            wmi := ComObjGet("winmgmts:\\.\root\cimv2")
        } catch {
            wmi := 0
        }
    }
    out := {engine: [], serve: [], guard: [], launcher: [], driver: [], err: ""}
    try {
        for p in wmi.ExecQuery("SELECT ProcessId,Name,CommandLine FROM Win32_Process WHERE Name='strata.exe' OR Name='python.exe' OR Name='cmd.exe'") {
            try {
                pid := p.ProcessId
                name := p.Name
                cmd := ""
                try cmd := p.CommandLine
                if (name = "strata.exe")
                    out.engine.Push(pid)
                else if (name = "cmd.exe") {
                    if InStr(cmd, "strata-run.py")
                        out.launcher.Push(pid)
                } else if InStr(cmd, "strata-run.py")
                    out.driver.Push({pid: pid, cmd: cmd})   ; 后台跑的驱动（无窗口）
                else if (InStr(cmd, "serve/server.py") || InStr(cmd, "serve\server.py"))
                    out.serve.Push({pid: pid, cmd: cmd})
                else if InStr(cmd, "strata-ram-guard.py")
                    out.guard.Push(pid)
            } catch
                continue
        }
    } catch as e {
        out.err := e.Message
    }
    return out
}

FreeRamMB() {
    try {
        for os in ComObjGet("winmgmts:\\.\root\cimv2").ExecQuery(
            "SELECT FreePhysicalMemory,TotalVisibleMemorySize FROM Win32_OperatingSystem")
            return {free: Round(os.FreePhysicalMemory / 1024), total: Round(os.TotalVisibleMemorySize / 1024)}
    } catch as e
        return {free: -1, total: -1, err: e.Message}
}

; 一次 nvidia-smi 拿两样东西：GPU 总体占用（memory.used/total）+ 逐进程占用
; 逐进程的显存很多驱动对图形进程只报 [N/A]，所以"是否该提醒"一律以总体占用为准

GpuSnapshot() {
    smi := FileExist("C:\Windows\System32\nvidia-smi.exe") ? "C:\Windows\System32\nvidia-smi.exe" : "nvidia-smi"
    tmp := A_Temp . "\strata-launcher-smi.txt"
    snap := {used: -1, total: -1, apps: [], err: ""}
    try FileDelete(tmp)
    try RunWait(Q(A_ComSpec) . " /c " . smi
        . " --query-gpu=memory.used,memory.total --format=csv,noheader,nounits > " . Q(tmp) . " 2>nul"
        , , "Hide")
    if FileExist(tmp) {
        try {
            line := Trim(FileRead(tmp, "UTF-8"), " `t`r`n")
            if (line != "") {
                f := StrSplit(line, ",")
                if (f.Length >= 2) {
                    snap.used := Integer(Trim(f[1], " `t`r`n"))
                    snap.total := Integer(Trim(f[2], " `t`r`n"))
                }
            }
        } catch as e
            snap.err := e.Message
    }
    try FileDelete(tmp)
    try RunWait(Q(A_ComSpec) . " /c " . smi
        . " --query-compute-apps=pid,process_name,used_memory --format=csv,noheader > " . Q(tmp) . " 2>nul"
        , , "Hide")
    if FileExist(tmp) {
        try {
            for line in StrSplit(Trim(FileRead(tmp, "UTF-8"), " `t`r`n"), "`n") {
                line := Trim(line, " `t`r`n")
                if (line = "")
                    continue
                f := StrSplit(line, ",")
                if (f.Length >= 3)
                    snap.apps.Push({pid: Trim(f[1], " `t`r`n"), name: Trim(f[2], " `t`r`n"), mem: Trim(f[3], " `t`r`n")})
            }
        } catch as e
            snap.err := e.Message
    }
    return snap
}

; nvidia-smi 要起进程，状态栏每 5 秒刷新会太吵：30 秒缓存，启动预检时强制取新
gpuCache := {ts: 0, snap: {used: -1, total: -1, apps: [], err: ""}}

GpuSnapshotCached(force := false) {
    ; force=true 时也不无条件重查：nvidia-smi 一次约 700 ms，而预检只是想看"现在谁占着显存"，
    ; 10 秒内的数据足够（连点两次启动是常见操作）。要真正新的就 force + 等 TTL 过期。
    global gpuCache
    ttl := force ? 10000 : 30000
    if ((A_TickCount - gpuCache.ts > ttl) || !IsObject(gpuCache.snap)) {
        gpuCache.snap := GpuSnapshot()
        gpuCache.ts := A_TickCount
    }
    return gpuCache.snap
}

; 显存占用者：排除本启动器自己起的引擎/服务端/护栏/驱动，只留下"别人"

VramOccupants(snap, st) {
    own := Map()
    try {
        for p in st.procs.engine
            own[p] := 1
        for p in st.procs.guard
            own[p] := 1
        for p in st.procs.launcher
            own[p] := 1
        for p in st.procs.driver
            own[p] := 1
        for p in st.procs.serve
            own[p.pid] := 1
    }
    others := []
    for app in snap.apps {
        if (app.pid ~= "^\d+$" && own.Has(Integer(app.pid)))
            continue
        others.Push(app)
    }
    return others
}

; 占用者描述（去掉全路径）

VramWho(others) {
    parts := []
    for a in others
        parts.Push(BaseName(a.name))
    return Join(parts, " / ")
}

; 显存提醒文案：只按"实际占用 > 阈值"触发，并指出是谁；若只有我们自己的引擎在跑就不重复唠叨

VramWarnText(snap, others, ourEngine) {
    if (snap.used < 0 || snap.used <= VRAM_WARN_MIB)
        return ""
    if (ourEngine && !others.Length)
        return ""
    head := "显存已经被占用 " . snap.used . " MiB / 共 " . snap.total . " MiB（提醒阈值 " . VRAM_WARN_MIB . " MiB）："
    if others.Length
        return head . VramWho(others) . " —— 它占的正是专家缓存要用的显存，容易出现「启动了一会儿就没了」。"
    return head . "没能列出具体进程（nvidia-smi 对图形/桌面占用常报 [N/A]）。"
}

TailOf(path, maxChars := 4096) {       ; 只读文件尾部，不整篇读进来
    try {
        if !FileExist(path)
            return {text: "", mtime: ""}
        mtime := FileGetTime(path, "M")
        f := FileOpen(path, "r", "UTF-8")
        if !f
            return {text: "", mtime: mtime}
        len := f.Length
        f.Seek(len > maxChars ? len - maxChars : 0)
        t := f.Read()
        f.Close()
        return {text: t, mtime: mtime}
    } catch as e
        return {text: "[读取失败] " . e.Message, mtime: ""}
}

LastLines(text, n := 14) {
    lines := StrSplit(StrReplace(text, "`r`n", "`n"), "`n")
    keep := []
    i := lines.Length
    while (i >= 1 && keep.Length < n) {
        if (Trim(lines[i]) != "")
            keep.InsertAt(1, RTrim(lines[i], "`r"))
        i--
    }
    return Join(keep, "`n")
}

; 日志面板用：最新的一行在最上面。自动刷新会把 Edit 滚回顶部，
; 所以"顶部=最新"才符合直觉；往下滚就是历史（老的在下）。
NewestFirst(text, n := 14) {
    lines := StrSplit(StrReplace(text, "`r`n", "`n"), "`n")
    keep := []
    i := lines.Length
    while (i >= 1 && keep.Length < n) {
        if (Trim(lines[i]) != "")
            keep.Push(RTrim(lines[i], "`r"))
        i--
    }
    return Join(keep, "`n")
}

Join(arr, sep) {
    s := ""
    for i, v in arr
        s .= (i = 1 ? "" : sep) . v
    return s
}

; 运行中实例的信息（服务端进程命令行 + /props）

QueryStatus(portHint) {
    ; 6 秒内的快照直接复用：FindProcs 的 WMI CommandLine 查询实测要 4 秒级，
    ; 而状态面板每 5 秒已经刷过一次，预检没必要再等一遍（R11 提速的主要来源）。
    static cache := Map()
    ck := String(portHint)
    if (cache.Has(ck) && (A_TickCount - cache[ck].ts < 6000))
        return cache[ck].v
    st := {}
    st.procs := FindProcs()
    st.ram := FreeRamMB()
    st.port := portHint
    st.servePid := 0
    st.mode := ""
    if (st.procs.serve.Length) {
        st.servePid := st.procs.serve[1].pid
        cmd := st.procs.serve[1].cmd
        if InStr(cmd, "-long-run.json")
            st.mode := "long"
        else if InStr(cmd, "-run.json")
            st.mode := "short"
        if RegExMatch(cmd, "--port\s+(\d+)", &m)
            st.port := Integer(m[1])
    }
    st.http := HttpGet("http://127.0.0.1:" . st.port . "/props", 1200)
    st.nCtx := 0
    st.alias := ""
    st.sleeping := ""
    if (st.http.ok && st.http.body != "") {
        if RegExMatch(st.http.body, '"n_ctx"\s*:\s*(\d+)', &m)
            st.nCtx := Integer(m[1])
        if RegExMatch(st.http.body, '"model_alias"\s*:\s*"([^"]*)"', &m)
            st.alias := m[1]
        if RegExMatch(st.http.body, '"is_sleeping"\s*:\s*(true|false)', &m)
            st.sleeping := m[1]
    }
    ; 有进程（含我们刚起的驱动/cmd 包装）但端口没通时，交给 DecideState 区分"加载中"和"异常"。
    ; 注意也要算上 DriverAlive()：刚点启动那一两秒 WMI 可能还没扫到新进程，但包装进程已经在了。
    anyProc := (st.procs.engine.Length || st.procs.serve.Length || st.procs.driver.Length
        || st.procs.launcher.Length || DriverAlive()) ? true : false
    st.state := DecideState(anyProc, st.http.ok, st.http.status, DriverAlive(), NewestLogAgeMin())
    cache[ck] := {v: st, ts: A_TickCount}
    return st
}

; 状态判定。纯函数：QueryStatus 把实测值喂进来，自检可以直接摆各种组合来验。
; 关键点：端口没通的时候不一定是异常 —— 正在加载模型那几分钟也是"进程在、端口没通"。
;   正在加载的两种证据：a) 我们这次启动的驱动进程还活着（它在监督加载）；b) 服务端/引擎日志最近还在写
;   两者都没有，才当成"残留/崩溃"→ 异常

DecideState(anyProc, httpOk, httpStatus, driverAlive, logAgeMin) {
    global LOG_FRESH_MIN
    if !anyProc
        return "stopped"
    if (httpOk && httpStatus = 200)
        return "running"
    if httpOk
        ; 端口通了但引擎没就绪（/props 503 "the engine is not running"）：真正加载的那几分钟
        ; 也是这个回应，所以同样要证据 —— 驱动还活着，或日志刚刚还在写。都没有就是上次的残留。
        if (driverAlive || (logAgeMin >= 0 && logAgeMin <= LOG_FRESH_MIN))
            return "loading"
    if (driverAlive || (logAgeMin >= 0 && logAgeMin <= LOG_FRESH_MIN))
        return "loading"                       ; 端口没通，但看得出来正在加载
    return "zombie"                            ; 进程在、也不在加载 → 残留或崩了
}

; 我们这次启动的驱动（cmd 包装进程 / python 驱动）还活着吗
; "DID WE start a load?" -- only our own driver counts.  A stranger's driver (a run from an
; earlier session, still lying around) is a process, not evidence that something is loading:
; treating it as evidence is why a stale server on the port read as "加载中" forever.

DriverAlive() {
    global gDriverPid
    return (gDriverPid && ProcessExist(gDriverPid)) ? true : false
}

; 服务端/引擎日志里最新的一次写入是几分钟前（都没有则 -1）

NewestLogAgeMin() {
    newest := -1
    for mode in ["short", "long"] {
        for p in [ServerLogFor(mode), EngineLogFor(mode)] {
            mt := ""
            try mt := FileGetTime(p, "M")
            if (mt = "")
                continue
            d := DateDiff(A_Now, mt, "Minutes")
            if (newest < 0 || d < newest)
                newest := d
        }
    }
    return newest
}

; 「已等 1 分 20 秒」——加载中时告诉用户等了多久，免得以为卡死

ElapsedText() {
    global gLaunchTick
    if !gLaunchTick
        return ""
    s := Round((A_TickCount - gLaunchTick) / 1000)
    if (s < 60)
        return "已等 " . s . " 秒"
    return "已等 " . (s // 60) . " 分" . Mod(s, 60) . " 秒"
}

StateLine(st) {
    if (st.state = "running")
        return {text: Tf("运行状态: ") . "● " . Tf("运行中（引擎已加载）"), color: "008000"}
    if (st.state = "loading")
        return {text: Tf("运行状态: ") . "◐ " . Tf("加载中…") . "（" . Tf("引擎在起，端口 ") . st.port . Tf(" 还没就绪")
            . (ElapsedText() != "" ? " · " . ElapsedText() : "") . "）", color: "B8860B"}
    if (st.state = "zombie")
        return {text: Tf("运行状态: ") . "✕ " . Tf("异常") . "：" . Tf("进程还在但引擎没在跑（上次的残留？点「停止」清掉）"), color: "C00000"}
    return {text: Tf("运行状态: ") . "○ " . Tf("未运行") . "（" . Tf("端口 ") . st.port . Tf(" 无响应）"), color: "606060"}
}

; ------------------------------------------------- 4. 预检

; ── 预检提醒（P4）：判定逻辑在中间层，文案在这里 ────────────────────────────
; AHK 只负责把"本机事实"查出来交给 ctl（文件存在性、进程、显存/内存实测），
; ctl 返回 [warn.N] 的 code/hard/参数；文案与语言仍留在界面。
CtlWarnList(o, ciT, st) {
    ; R11：bounds / warns / errors 都来自同一次 plan
    all := CtlPlanAll(Normalize(o), ciT, st)
    if (!IsObject(all))
        return 0
    return Map("warns", all["warns"], "errors", all["errors"])
}

; 预检弹窗的正文：条数与顺序由中间层给（已按 priority 排好），这里只负责"最多显示几条"。
; 多的时候弹窗会变成一堵墙 —— 实测提醒最多能到 5 条，加上长文案就超出屏幕。
; 预检失败时把若干条拼成弹窗正文（条数不设上限：失败原因通常就一两条）
PreflightFailText(items) {
    return Bi("预检未通过：", "Preflight failed:") . "`n  - " . Join(items, "`n  - ")
}

ErrTexts(errs) {
    out := []
    for e in errs
        out.Push(WarnText(e["code"], e))
    return out
}


WarnDialogText(head, warns, maxItems := 6) {
    global gLang
    shown := []
    for i, w in warns {
        if (i > maxItems)
            break
        shown.Push("  - " . w)
    }
    txt := head . "`n`n" . Join(shown, "`n")
    if (warns.Length > maxItems)
        txt .= "`n  " . Bi("… 还有 " . (warns.Length - maxItems) . " 条，见状态栏与引擎日志",
                          "… and " . (warns.Length - maxItems) . " more - see the status bar and the engine log")
    return txt . "`n`n" . Bi("继续？", "Continue?")
}


; code -> 文案（中/英）；未收录的 code 原样返回，便于发现漏翻
WarnText(code, p) {
    global gLang
    en := (gLang = "en")
    switch code {
        case "model.missing":
            return (en ? "no GGUF model selected: pick one with Choose (the simple view has it too), or put --native into the template config"
                       : "没有指定 GGUF 模型文件：用「选择…」（简洁模式也有）选一次，或把配置模板里的 --native 填上")
        case "pack.prepare":
            return (en ? "pack not ready: the server prepares it on first start" : "pack 还没准备好：服务端首次启动会自动生成")
        case "vram.budget.low":
            return (en ? "only " . p["budget"] . " MiB of VRAM left after the weights and the reserve: the prefill buffers will likely not fit (symptom: prefill ... out of memory). Setting mtp to cpu frees about 300 MiB."
                       : "显存预算只剩 " . p["budget"] . " MiB（扣掉权重与 reserve）：MTP 专家还放在显存里时来 prefill 缓冲很可能放不下（症状：prefill ... out of memory）。把「mtp」改成 cpu 可多出约 300 MiB。")
        case "ctx.over.ceiling":
            return (en ? "ctx " . p["ctx"] . " is over this machine's measured ceiling " . p["ceiling"] . ": the engine will most likely refuse"
                       : "ctx " . p["ctx"] . " 超过本机实测边界 " . p["ceiling"] . "：引擎很可能拒绝起")
        case "ctx.starves.cache":
            ; 只说**实测事实**：本机在 seen_ctx 那次量到 seen_slots 个槽（< 目标）。
            ; 不做 ctx->槽位的线性外推 —— 实测证明误差极大（见文档 §18）。
            return (en ? "measured on this machine: ctx " . Mget(p, "seen_ctx", 0) . " left only " . Mget(p, "seen_slots", 0) . " expert slots (aim for >= " . Mget(p, "target", 400) . "), so decoding gets slower - pick a smaller ctx"
                       : "本机实测：ctx " . Mget(p, "seen_ctx", 0) . " 时只剩 " . Mget(p, "seen_slots", 0) . " 个专家槽（建议 ≥" . Mget(p, "target", 400) . "），解码会变慢；把 ctx 调小一档")

        case "ram.low":
            return (en ? "RAM " . p["free"] . " MB free of " . p["total"] . " MB: the experts need ~" . Round(p["need"] / 1024) . " GiB. If it does not fit the server switches to low-RAM mode itself (about a third of the resident decode speed); the guard kills the engine below " . p["abort"] . " MB free."
                       : "空闲内存 " . p["free"] . " MB（共 " . p["total"] . " MB）：专家约 " . Round(p["need"] / 1024) . " GiB 要进内存，不够时服务端会自动切 low-RAM 模式（专家从模型文件映射、由系统文件缓存流式喂养，解码约为常驻的 1/3）；护栏在余量 <" . p["abort"] . " MB 时会杀引擎。")
        case "ram.critical":
            return (en ? "only " . p["free"] . " MB of RAM left, below the guard threshold " . p["abort"] . " MB: the driver will kill the engine right away. Close memory hogs first."
                       : "内存余量只有 " . p["free"] . " MB，低于护栏阈值 " . p["abort"] . " MB —— 驱动一起来就会把引擎杀掉。先关掉占内存的程序再启动。")
        case "instance.running":
            return (en ? "an instance is already running (engine pid " . p["engine"] . " / server pid " . p["serve"] . "): the driver kills it first - by design on a single GPU."
                       : "已经有实例在跑（引擎 pid " . p["engine"] . " / 服务端 pid " . p["serve"] . "）：驱动启动时会先把它杀掉 —— 单卡上这是设计行为。")
        case "guard.running":
            return (en ? "the RAM guard is already running (pid " . p["pid"] . "); the driver reuses it."
                       : "内存护栏已在运行（pid " . p["pid"] . "），驱动会复用它。")
        case "ctx.invalid":
            return (en ? "ctx must be a positive whole number (got " . Mget(p, "value", "?") . ")"
                       : "ctx 必须是正整数（当前 " . Mget(p, "value", "?") . "）")
        case "port.invalid":
            return (en ? "the port must be 1-65535 (got " . Mget(p, "value", "?") . ")"
                       : "端口必须在 1-65535 之间（当前 " . Mget(p, "value", "?") . "）")
        case "reserve.invalid":
            return (en ? "vram-reserve-mib cannot be negative (got " . Mget(p, "value", "?") . ")"
                       : "vram-reserve-mib 不能为负（当前 " . Mget(p, "value", "?") . "）")
        case "resident.invalid":
            return (en ? "kv-resident must be 0 (KV stays in VRAM) or >= 20480 (streaming); got " . Mget(p, "value", "?")
                       : "kv-resident 只能是 0（KV 全驻显存）或 ≥20480（流式）；当前 " . Mget(p, "value", "?"))
        case "env.cudart.missing":
            return (en ? "cudart64_12.dll not found in the engine folder or PATH: install CUDA Toolkit 12.x, or point the config's lib_dirs at its bin"
                       : "在引擎目录和 PATH 里都没找到 cudart64_12.dll：装 CUDA Toolkit 12.x，或把配置里的 lib_dirs 指到它的 bin")
        case "env.cublas.missing":
            return (en ? "cublas64_12.dll not found: same fix as cudart64_12.dll"
                       : "没找到 cublas64_12.dll：同上")
        case "env.sm.mismatch":
            return (en ? "this build is sm_" . "86" . "; the card is compute " . Mget(p, "cap", "?") . " -- it may report no kernel image; build your own with " . Mget(p, "flag", "-arch=sm_86")
                       : "这个引擎是按 sm_86 编的，这块卡是 compute " . Mget(p, "cap", "?") . "，可能报「no kernel image」；按 README「自己编译」用 " . Mget(p, "flag", "-arch=sm_86") . " 编一份")

    }
    return code
}

Preflight(o, addCheck) {
    t0 := A_TickCount
    o := Normalize(o)
    problems := [], warns := []
    if !FileExist(EXE)
        problems.Push("引擎缺失: " . EXE . "  （把 strata.exe 放到启动器旁边，或设 STRATA_HOME）")
    if !FileExist(SERVER_PY)
        problems.Push("服务层缺失: " . SERVER_PY . "  （引擎本身没有 HTTP 服务，serve\ 目录必须存在）")
    if !FileExist(PY)
        problems.Push("python 缺失: " . PY . "  （检出布局需先在 " . ROOT . " 跑一次 START-HERE.bat；便携包需带 python\python.exe）")
    if !FileExist(DRIVER)
        problems.Push("驱动缺失: " . DRIVER)
    if !FileExist(BASE_CFG)
        problems.Push("模板配置缺失: " . BASE_CFG)
    ; 没指定 GGUF：如果模板里也没有 --native，引擎会直接起不来 —— 给个明确提醒
    if (Prop(o, "native", "") = "" && !TemplateHasNative())
        warns.Push("没有指定 GGUF 模型文件：用「选择…」（简洁模式也有）选一次，或把配置模板里的 --native / 环境变量设好")
    pp := PackProblem(o)
    if (pp != "")
        warns.Push(pp)            ; 不是拦下来：服务端会自己准备好
    ; 显存预算（权重/MTP/reserve 之后剩下的）太小才提醒 —— 用服务端算出的实际值，
    ; 不再用"文件 > 16 GiB"这种与真实显存无关的死规则（IQ4_XS 16.9 GiB 预算 974 MiB 其实能跑）。
    nv := Prop(o, "native", "")
    cp := Prop(o, "mtp_cpu_moe", "off")
    ciT := (nv != "") ? CapacityInfo(nv, o.kv, MtpSlug(Prop(o, "mtp", "on"), cp)) : 0
    st := QueryStatus(o.port)          ; 提醒要用本机事实（内存/进程），先查一次
    try FileAppend(FormatTime(A_Now, "HH:mm:ss") . " [timing] preflight.query_status=" . (A_TickCount - t0) . "ms`n", RESULTS . "\strata-launcher-messages.log", "UTF-8")
    ; P4：提醒的判定在中间层（strata/ctl/preflight.py），这里只把本机事实交过去、把 code 翻成文案。
    ; ctl 不可用时 cw 非对象，下面的内置规则接管（便携包没带 python 也能用）。
    cw := CtlWarnList(o, ciT, st)
    if (IsObject(cw)) {
        for w in cw["warns"] {
            txt := WarnText(w["code"], w)
            if (w["hard"])
                return {ok: false, msg: PreflightFailText([txt])}
            warns.Push(txt)
        }
        if (cw["errors"].Length)
            return {ok: false, msg: PreflightFailText(ErrTexts(cw["errors"]))}
    }
    if (!IsObject(cw) && IsObject(ciT) && ciT.budget > 0 && ciT.budget < 700 && cp != "on")
        warns.Push(Bi("显存预算只剩 " . ciT.budget . " MiB（扣掉权重与 reserve）：MTP 专家还放在显存里时，预填缓冲很可能不够"
            . "（症状：prefill ... out of memory）。把「mtp」改成 cpu 可多出约 300 MiB。",
            "only " . ciT.budget . " MiB of VRAM left after the weights and the reserve: with the MTP experts still "
            . "in VRAM the prefill buffers will likely not fit (symptom: prefill ... out of memory). Setting mtp to "
            . "cpu frees about 300 MiB."))
    try FileAppend(FormatTime(A_Now, "HH:mm:ss") . " [timing] preflight.before_env=" . (A_TickCount - t0) . "ms`n", RESULTS . "\strata-launcher-messages.log", "UTF-8")
    env := EnvProblems()          ; 本机事实（DLL 在不在）由界面查；中间层的同类检查只作提醒
    for m in env.hard
        problems.Push("运行环境: " . m)
    for m in env.soft
        warns.Push("运行环境: " . m)
    v := IsObject(cw) ? {ok: true, msg: ""} : ValidateNumbers(o)
    if !v.ok
        problems.Push("参数错误: " . v.msg)
    if problems.Length
        return {ok: false, msg: "预检未通过：`n  - " . Join(problems, "`n  - ")}
    if (!IsObject(cw) && BoundaryExceeded(o)) {
        b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"), Prop(o, "native", ""))
        warns.Push("ctx " . o.ctx . " 超过本机实测边界 " . b.ok . "（" . b.key . "）；引擎很可能拒绝启动并告诉你差多少 MiB。")
        bRec := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"), Prop(o, "native", ""))
        ciPre := CapacityInfo(Prop(o, "native", ""), o.kv, MtpSlug(Prop(o, "mtp", "on"), Prop(o, "mtp_cpu_moe", "off")))
        recCtx := (ciPre && ciPre.suggest > 0) ? ciPre.suggest : (bRec.measured ? bRec.rec : 0)
        if (recCtx > 0 && o.ctx > recCtx && !addCheck)
            ; 兜底路径：没有中间层就算不出槽位，只说"超建议值"，不编具体数字
            warns.Push(Bi("ctx " . o.ctx . " 超过本机实测建议值 " . recCtx . "（该值按保留 400 个专家槽算）；"
                . "再大可能挤占专家缓存，解码会变慢。",
                "ctx " . o.ctx . " is above this machine's suggested " . recCtx . " (which keeps ~400 expert slots); "
                . "a bigger one may squeeze the expert cache and slow decoding down."))
    }
    if (!IsObject(cw) && st.ram.free >= 0) {
        if (st.ram.free < RAM_ABORT_MB)
            return {ok: false, msg: "内存余量只有 " . st.ram.free . " MB，低于护栏阈值 " . RAM_ABORT_MB
                . " MB —— 驱动一起来就会把引擎杀掉。先关掉占内存的程序再启动。"}
        if (st.ram.free < MODEL_NEED_MB)
            warns.Push(Bi("空闲内存 " . st.ram.free . " MB（共 " . st.ram.total . " MB）：专家约 12 GiB 要进内存，"
                . "不够时服务端会自动切 low-RAM 模式（专家从模型文件映射、由系统文件缓存流式喂养，解码约为常驻的 1/3）；"
                . "护栏在余量 <" . RAM_ABORT_MB . " MB 时会杀引擎。",
                "RAM " . st.ram.free . " MB free of " . st.ram.total . " MB: the experts need ~12 GiB. When it does not "
                . "fit, the server switches to low-RAM mode itself (experts mapped from the model file, streamed by "
                . "the OS cache; about a third of the resident decode speed). The guard kills the engine below "
                . RAM_ABORT_MB . " MB free."))
    }
    if (!IsObject(cw) && (st.procs.engine.Length || st.procs.serve.Length))
        warns.Push("已经有实例在跑（引擎 pid " . (st.procs.engine.Length ? st.procs.engine[1] : "-")
            . " / 服务端 pid " . (st.procs.serve.Length ? st.procs.serve[1].pid : "-")
            . "）：驱动启动时会先把它杀掉 —— 单卡上这是设计行为。")
    if (!IsObject(cw) && st.procs.guard.Length)
        warns.Push("内存护栏已在运行（pid " . st.procs.guard[1] . "），驱动会复用它。")
    if !addCheck {
        ; 只看"显存实际被占用"是否超过阈值（不看有没有显卡进程），并指出占用者
        snap := GpuSnapshotCached(true)         ; 预检强制取新，不吃 30 秒缓存
        others := VramOccupants(snap, st)
        wt := VramWarnText(snap, others, st.procs.engine.Length > 0)
        if (wt != "")
            warns.Push(wt)
    }
    return {ok: true, msg: "", warns: warns}
}

; 预检的无弹窗版（自检用：只看文件与数字参数）

PreflightNoDlg(o) {
    problems := []
    if !FileExist(EXE)
        problems.Push("引擎")
    if !FileExist(SERVER_PY)
        problems.Push("服务层")
    if !FileExist(PY)
        problems.Push("python")
    if !FileExist(DRIVER)
        problems.Push("驱动")
    if !FileExist(BASE_CFG)
        problems.Push("模板配置")
    v := ValidateNumbers(o)
    if !v.ok
        problems.Push(v.msg)
    return {ok: problems.Length = 0, msg: Join(problems, "；")}
}

; ------------------------------------------------- 5. 动作

DoLaunch(addCheck) {
    global gDriverPid, gDriverLog
    t0 := A_TickCount
    o := CollectCurrent()
    pf := Preflight(o, addCheck)
    t1 := A_TickCount
    if !pf.ok {
        Notify("error", pf.msg)          ; R10：不弹窗，写状态行 + 消息日志
        RefreshStatus()
        return
    }
    if (pf.warns.Length) {
        head := addCheck ? Bi("预览前提醒（不影响 --check）：", "Before preview (--check is unaffected):")
                         : Bi("启动前提醒：", "Before start:")
        ; 提醒文案已经是双语的（WarnText 出），这里不要再套 Tf() —— 会二次翻译并吃掉格式
        ; R10：提醒不拦人 —— 上状态行 + 写日志，照常启动
        Notify("warn", head . " " . Join(pf.warns, " · "))
    }
    SaveIni(o)
    logPath := DriverLogFor(o.mode)
    try DirCreate(RESULTS)                 ; 重定向目标目录必须存在，否则驱动根本起不来
    cmd := BuildLaunchCmd(o, addCheck, logPath)
    SetStatusText(Bi((addCheck ? "已发起预览 --check" : "已发起启动") . "：ctx=" . o.ctx . " / " . o.kv . " / mtp " . o.mtp
        . "（后台运行，不弹窗口；输出写 " . logPath . "）",
        (addCheck ? "Preview --check started" : "Start requested") . ": ctx=" . o.ctx . " / " . o.kv . " / mtp " . o.mtp
        . " (background, no window; output goes to " . logPath . ")"), "000080")
    try {
        Run(cmd, DEV, "Hide", &p)
        t2 := A_TickCount
        try FileAppend(FormatTime(A_Now, "HH:mm:ss") . " [timing] preflight=" . (t1 - t0) . "ms launch=" . (t2 - t1) . "ms`n",
            RESULTS . "\strata-launcher-messages.log", "UTF-8")
        gDriverPid := p
        gDriverLog := logPath
        if !addCheck
            gLaunchTick := A_TickCount           ; 记下时刻：加载中要显示"已等多久"
        SetStatusText(Bi((addCheck ? "已发起预览 --check" : "已发起启动") . "：ctx=" . o.ctx . " / " . o.kv . " / mtp " . o.mtp
            . "（无窗口）：引擎加载约 12 秒，状态变绿即就绪；驱动输出见「驱动输出」按钮",
            (addCheck ? "Preview --check started" : "Start requested") . ": ctx=" . o.ctx . " / " . o.kv . " / mtp " . o.mtp
            . " (no window): the engine loads in ~12 s, wait for the green status; see Driver output"), "000080")
        RefreshStatus()                          ; 立刻刷一次：状态图马上变"加载中…"，不用等 5 秒定时器
    } catch as e {
        gDriverPid := 0
        Notify("error", Tf("无法启动：") . e.Message . Tf("（命令行见日志）") . "`n" . cmd)
    }
    SetTimer(RefreshTick, 1500)
}

; 停止确认就一句话 —— 多行文案会把 AHK 的对话框撑成竖长条，跟常规 Windows 确认框不像；
; 具体停了几个进程看专业模式的「最近动作」行（那里有数量）。

StopConfirmText() {
    return "是否停止Strata引擎及相关进程"
}

DoStop() {
    global gDriverPid
    st := FindProcs()
    pids := []
    for p in st.engine
        pids.Push(p)
    for p in st.serve
        pids.Push(p.pid)
    for p in st.guard
        pids.Push(p)
    for p in st.launcher
        pids.Push(p)
    for p in st.driver
        pids.Push(p.pid)
    if !pids.Length {
        Notify("warn", Tf("没有发现运行中的 Strata 进程（引擎 / 服务端 / 护栏 / 驱动 / 启动 cmd 都没有）。"))
        RefreshStatus()
        return
    }
    ; R10：不再确认（确认框 = 界面替用户做决定）；直接停，结果写状态行与日志
    killed := 0
    for pid in pids {
        try {
            if ProcessClose(pid)
                killed++
        } catch as e
            continue
    }
    gDriverPid := 0                        ; 是我们主动停的，别再报"驱动异常退出"
    gLaunchTick := 0
    Sleep(800)
    Notify("info", Bi("停止：请求 " . pids.Length . " 个进程，成功 " . killed . " 个",
        "Stop: asked " . pids.Length . " process(es), " . killed . " stopped"), "C00000")
    RefreshStatus()
}

; 重启 = 停掉现有进程（等端口/显存释放）再按当前参数启动

DoRestart() {
    global gDriverPid
    st := FindProcs()
    pids := []
    for p in st.engine
        pids.Push(p)
    for p in st.serve
        pids.Push(p.pid)
    for p in st.guard
        pids.Push(p)
    for p in st.launcher
        pids.Push(p)
    for p in st.driver
        pids.Push(p.pid)
    ; R10：同上，不确认直接重启
    if (!pids.Length) {
        Notify("warn", Bi("没有运行中的进程，直接按当前参数重启", "nothing was running; starting with the current settings"), "B8860B")
    } else {
    }
    killed := 0
    for pid in pids {
        try {
            if ProcessClose(pid)
                killed++
        } catch as e
            continue
    }
    gDriverPid := 0
    gLaunchTick := 0
    SetStatusText(Bi("重启：已停 " . killed . " 个进程，等待释放后重新启动…",
        "Restart: " . killed . " process(es) stopped; waiting for the port, then starting again..."), "000080")
    Sleep(1500)                        ; 给端口与显存一点释放时间
    DoLaunch(false)
}

OpenPath(path) {
    if !FileExist(path) && !DirExist(path) {
        Notify("error", Tf("找不到：") . path)
    }
    if DirExist(path)
        Run("explorer.exe " . Q(path))
    else
        Run("notepad.exe " . Q(path))
}

ServerLogFor(mode) {
    return mode = "long" ? RESULTS . "\strata-qwen36-long-server.log" : RESULTS . "\strata-qwen36-server.log"
}

EngineLogFor(mode) {
    return mode = "long" ? RESULTS . "\strata-qwen36-long.log" : RESULTS . "\strata-qwen36.log"
}

; 这次运行是否走了 low-RAM（专家从模型文件映射、由系统文件缓存喂）：看配置或服务端日志
LowRamActive(mode) {
    ro := CtlObserve(mode)
    return IsObject(ro) ? ro["low_ram"] : false
}

; 这台机器的内存会不会逼出 low-RAM：专家约 12 GiB，装下它还要 7 GiB 余量
LowRamExpected(st) {
    return (st.ram.total > 0 && (st.ram.total - EXPERTS_MIB) < LOWRAM_SPARE_MIB)
}

; 内存行末尾追加的 low-RAM 提示
LowRamSuffix(st, mode) {
    global gLang
    if (IsObject(st.procs) && st.procs.engine.Length && LowRamActive(mode))
        return (gLang = "en" ? "  ·  low-RAM: experts streamed from the SSD (~1/3 decode)"
                             : "  ·  low-RAM：专家从 SSD 流式（~1/3 速度）")
    if (LowRamExpected(st))
        return (gLang = "en" ? "  ·  RAM is short: low-RAM starts automatically (~1/3 decode)"
                             : "  ·  内存不够：启动时自动切 low-RAM（约 1/3 速度）")
    return ""
}
    
; 正在跑的引擎分到几个专家槽（<300 基本说明 ctx 把显存吃光了，实测解码掉到 1/4）
; ── 运行时观测（P3）：日志解析只在中间层做 ──────────────────────────────────
; AHK 只把日志路径交给 ctl，读回 [runtime] 的数字；文案与格式仍留在界面（i18n 不搬家）。
; 缓存按"日志大小+修改时间"判断，日志没变就不再起 Python。
FileSig(p) {
    ; 大小 + 修改时间 + 末尾 60 字符：只看大小/时间会漏掉"同长度同秒"的改写（自检里踩过）。
    if (p = "" || !FileExist(p))
        return "-"
    sz := FileGetSize(p)
    tail := ""
    try {
        f := FileOpen(p, "r", "UTF-8-RAW")
        if (sz > 200)
            f.Seek(sz - 200)
        tail := f.Read()
        f.Close()
    }
    return sz . "@" . FileGetTime(p, "M") . "#" . SubStr(tail, -60)
}

CtlObserve(mode) {
    global PY, DEV, ROOT
    static cache := Map()
    if (PY = "" || !FileExist(PY))
        return 0
    ctlDir := FileExist(DEV . "\strata\ctl") ? DEV : (FileExist(ROOT . "\strata\ctl") ? ROOT : "")
    if (ctlDir = "")
        return 0
    el := EngineLogFor(mode), sl := ServerLogFor(mode), cf := RunCfgFor(mode)
    key := FileSig(el) . "|" . FileSig(sl) . "|" . FileSig(cf)
    if cache.Has(key)
        return cache[key]
    outFile := A_Temp . "\strata-ctl-rt.ini"
    try FileDelete(outFile)
    qt := Chr(34)
    boot := CtlBoot()
    if (boot = "")
        return 0
    cmd := qt . PY . qt . " -X utf8 " . qt . boot . qt . " observe --ini-out " . qt . outFile . qt
    if FileExist(el)
        cmd .= " --engine-log " . qt . el . qt
    if FileExist(sl)
        cmd .= " --server-log " . qt . sl . qt
    if FileExist(cf)
        cmd .= " --run-config " . qt . cf . qt
    try RunWait(cmd, ctlDir, "Hide")
    if !FileExist(outFile)
        return 0
    o := Map("slots", Integer(IniRead(outFile, "runtime", "slots", "0")),
             "cache_mib", Integer(IniRead(outFile, "runtime", "cache_mib", "0")),
             "accept_pct", Integer(IniRead(outFile, "runtime", "accept_pct", "0")),
             "accept_a", Integer(IniRead(outFile, "runtime", "accept_a", "0")),
             "accept_b", Integer(IniRead(outFile, "runtime", "accept_b", "0")),
             "tok_s", Float(IniRead(outFile, "runtime", "tok_s", "0")),
             "n_ctx", Integer(IniRead(outFile, "runtime", "n_ctx", "0")),
             "low_ram", IniRead(outFile, "runtime", "low_ram", "false") = "true")
    cache[key] := o
    return o
}

; 正在跑的引擎分到几个专家槽。实测：4 槽时 7.5 tok/s（常驻约 40）；258/468 槽没测过速度，
; 所以只对"极少"给倍数，其余只说"会变慢"，不编数字。
; 槽位后缀：只有引擎真的在跑时才给 —— 否则会拿上一轮日志里的数字冒充本次
; （界面曾出现"未运行 · 专家缓存 943 槽"这种自相矛盾的显示）。
SlotSuffixFor(st, mode) {
    if (!IsObject(st) || !IsObject(st.procs) || !st.procs.engine.Length)
        return ""
    return ExpertSlotsSuffix(mode)
}

ExpertSlotsSuffix(mode) {
    global gLang
    ro := CtlObserve(mode)
    n := IsObject(ro) ? ro["slots"] : 0
    if (n <= 0)
        return ""
    ; 槽数永远显示（这是判断限流/掉速最直接的数），只有不足时才追加警告。
    ; 倍数只对"极少"给出（实测 4 槽 = 7.5 tok/s，常驻约 40）；其余只说会变慢，不编数字。
    info := (gLang = "en" ? "  ·  expert cache " . n . " slots" : "  ·  专家缓存 " . n . " 槽")
    if (n >= 300)
        return info
    if (n < 50)
        return (gLang = "en" ? "  ·  expert cache only " . n . " slots -> decode ~1/5"
                             : "  ·  专家缓存仅 " . n . " 槽 → 解码约 1/5")
    return (gLang = "en" ? "  ·  expert cache only " . n . " slots (aim for >=400) -> slower decode"
                         : "  ·  专家缓存仅 " . n . " 槽（建议 ≥400）→ 解码会变慢")
}

RunCfgFor(mode) {
    return mode = "long" ? DEV . "\strata-qwen36-long-run.json" : DEV . "\strata-qwen36-run.json"
}

; 后台驱动的 stdout/stderr：界面里「驱动输出」按钮看它；驱动结束后的成败判定也读它

DriverLogFor(mode) {
    return mode = "long" ? RESULTS . "\strata-qwen36-long-driver.log" : RESULTS . "\strata-qwen36-driver.log"
}

; 从驱动日志文本判成败（纯函数，自检里可直接测；不弹窗）

JudgeDriverLog(text) {
    if InStr(text, "--check：只写配置，不启动。")
        return {kind: "preview", code: ""}
    if InStr(text, "code=0")
        return {kind: "ok", code: "0"}
    if RegExMatch(text, "code=(\d+)", &m)
        return {kind: "fail", code: m[1]}
    return {kind: "unknown", code: ""}
}

; 驱动退出后的判定：从日志尾部看成功/失败，失败弹提示（不静默吞掉）

ReviewDriverExit() {
    global gDriverLog
    if (gDriverLog = "" || !FileExist(gDriverLog)) {
        SetStatusText(Bi("驱动已退出，但没找到输出日志： ", "The driver exited but its log is missing: ") . gDriverLog, "C00000")
        return
    }
    tl := TailOf(gDriverLog, 20000)
    j := JudgeDriverLog(tl.text)
    if (j.kind = "preview") {
        SetStatusText(Bi("预览完成（--check）：运行配置已重写，引擎没启动",
            "Preview done (--check): the run config was rewritten, the engine was not started"), "006400")
        return
    }
    if (j.kind = "ok") {
        SetStatusText(Bi("驱动已正常退出（服务端 code=0）", "The driver exited cleanly (server code=0)"), "006400")
        return
    }
    why := Bi((j.kind = "fail" ? "（code=" . j.code . "）" : "（日志里没有 code= 行：驱动可能压根没起来）"),
        (j.kind = "fail" ? " (code=" . j.code . ")" : " (no code= line in the log: the driver probably never started)"))
    SetStatusText(Bi("驱动异常退出" . why . " —— 见「驱动输出」",
        "The driver exited with an error" . why . " - see Driver output"), "C00000")
    Notify("error", Tf("驱动异常退出") . why . Tf("；日志：") . gDriverLog . "`n" . LastLines(tl.text, 18))
}

; ------------------------------------------------- 6. 界面

CollectFields() {
    global rLong, ctxE, kvD, resE, mtpD, draftD, resvE, portE, corsE, thinkD, presD, hostE, keyE
    global visD, vistokE, nativeE, mmprojE, gInSetFields
    global tempE, toppE, topkE, minpE, prespenE, reppenE, dryE, chatTplE, gParams
    o := Normalize(gParams)                  ; 隐藏字段（spec / mtp_cpu_moe / template / native …）从基准集合继承
    o.mode := (rLong.Value ? "long" : "short")
    o.ctx := IntOr(ctxE.Value, -1)
    o.kv := DdlText(kvD, "k8v4")
    ; 留空 ≠ 0：留空 = 不写 --kv-resident（引擎默认 0 = 全部 KV 驻显存）；0 = 明确写 0
    o.residentRaw := Trim(resE.Value, " `t`r`n")
    o.resident := IntOr(o.residentRaw, -1)
    ; 界面的 MTP 下拉框是 gpu/cpu/off，映射成引擎的两个开关
    o.mtp_mode := DdlText(mtpD, (o.mode = "long" ? "cpu" : "gpu"))
    if (o.mode = "long" && o.mtp_mode = "gpu")
        o.mtp_mode := "cpu"          ; 长模式没有 gpu（装不下）
    o.mtp := (o.mtp_mode = "off") ? "off" : "on"
    o.mtp_cpu_moe := (o.mtp_mode = "cpu") ? "on" : "off"
    o.spec := SpecForMtp(o.mtp_mode, o.mode)   ; 专家位置变了，投机宽度换成实测配套值
    o.draft := DdlText(draftD, "en")
    o.reserve := IntOr(resvE.Value, -1)
    o.port := IntOr(portE.Value, -1)
    o.cors := Trim(corsE.Value)
    o.thinking := DdlText(thinkD, "on")
    o.preserve := DdlText(presD, "on")
    o.host := Trim(hostE.Value)
    o.apikey := Trim(keyE.Value)
    o.temperature := Trim(tempE.Value, " `t`r`n")
    o.top_p := Trim(toppE.Value, " `t`r`n")
    o.top_k := Trim(topkE.Value, " `t`r`n")
    o.template := "strata-qwen36-iq3s.json"     ; 模板固定：只用一份基础配置
    o.native := Trim(nativeE.Value)
    o.mmproj := Trim(mmprojE.Value)
    o.pack := (o.native = "" ? "" : FindPackFor(o.native))   ; 按当前 GGUF 现查，避免过期/错配
    o.vision := DdlText(visD, "cpu")
    o.vision_tokens := Trim(vistokE.Value, " `t`r`n")
    o.min_p := Trim(minpE.Value, " `t`r`n")
    o.dry := Trim(dryE.Value, " `t`r`n")
    o.chat_template := Trim(chatTplE.Value, " `t`r`n")
    o.presence_penalty := Trim(prespenE.Value, " `t`r`n")
    o.repetition_penalty := Trim(reppenE.Value, " `t`r`n")
    o.tag := (o.mode = "long" ? "long" : "")
    o.title := ModePreset(o.mode).title
    return o
}

SetFields(o) {
    global ctxE, kvD, resE, mtpD, draftD, resvE, portE, corsE, thinkD, presD, hostE, keyE, rShort, rLong
    global visD, vistokE, nativeE, mmprojE, gInSetFields
    global tempE, toppE, topkE, minpE, prespenE, reppenE, dryE
    o := Normalize(o)
    ctxE.Value := String(o.ctx)
    kvD.Text := InList(o.kv, KV_LIST, "k8v4")
    resE.Value := String(o.resident)
    ; 界面值：mtp=off -> off；否则按 mtp_cpu_moe 决定 cpu / gpu
    RefreshMtpList(mtpD, o.mode)
    ; 长模式只有 cpu/off（专家全上 GPU 装不下）；短模式 gpu/off
    want := (Prop(o, "mtp", "on") = "off") ? "off"
        : ((Prop(o, "mtp_cpu_moe", "off") = "on") ? "cpu" : "gpu")
    if (o.mode = "long" && want = "gpu")
        want := "cpu"
    mtpD.Text := want
    draftD.Text := InList(o.draft, DRAFT_LIST, "full")
    resvE.Value := String(o.reserve)
    portE.Value := String(o.port)
    corsE.Value := o.cors
    thinkD.Text := InList(o.thinking, YN_LIST, "on")
    gInSetFields := true
    ; 模板下拉已移除（只有一份基础配置）
    nativeE.Value := Prop(o, "native", "")
    mmprojE.Value := Prop(o, "mmproj", "")
    visD.Text := InList(Prop(o, "vision", "off"), VISION_LIST, "cpu")
    vistokE.Value := String(Prop(o, "vision_tokens", "300"))
    UpdateVisionEnabled()
    gInSetFields := false
    presD.Text := InList(o.preserve, YN_LIST, "on")
    hostE.Value := o.host
    keyE.Value := o.apikey
    dryE.Value := Prop(o, "dry", "")
    chatTplE.Value := Prop(o, "chat_template", "")
    tempE.Value := String(o.temperature)
    toppE.Value := String(o.top_p)
    topkE.Value := String(o.top_k)
    minpE.Value := String(o.min_p)
    prespenE.Value := String(o.presence_penalty)
    reppenE.Value := String(o.repetition_penalty)
    rShort.Value := (o.mode = "long" ? 0 : 1)
    rLong.Value := (o.mode = "long" ? 1 : 0)
}

; 切模式的纯合并逻辑（抽出来是为了能自检）：
;   ctx/kv/resident/mtp/spec/draft/reserve 取预置；模型与用户偏好取当前界面

MergePreset(mode, cur, q) {
    p := ModePreset(mode)
    for k in ["port", "cors", "thinking", "preserve", "host", "apikey", "temperature", "top_p", "top_k",
              "min_p", "presence_penalty", "repetition_penalty", "dry", "chat_template", "vision", "vision_tokens", "template"]
        p.%k% := Prop(q, k, Prop(p, k, ""))
    ; 模型（GGUF + mmproj）两个模式共用：切模式只换 ctx/kv/mtp 这些模式参数，不换模型
    p.native := cur.native
    p.mmproj := cur.mmproj
    p.port := cur.port
    p.cors := cur.cors
    p.thinking := cur.thinking
    p.host := cur.host
    p.apikey := cur.apikey
    p.temperature := cur.temperature
    p.top_p := cur.top_p
    p.top_k := cur.top_k
    p.min_p := cur.min_p
    p.presence_penalty := cur.presence_penalty
    p.repetition_penalty := cur.repetition_penalty
    return p
}

ApplyPreset(mode) {
    global gIgnoreIni
    cur := CollectCurrent()
    ; 模式相关（ctx/kv/resident/mtp/mtp_mode/spec/draft/reserve）取预置；界面偏好（port/cors/采样…）取当前
    q := gIgnoreIni ? ModePreset(mode) : LoadSection(mode = "long" ? "long" : "short", mode)
    p := MergePreset(mode, cur, q)
    SetCurrent(p)
    UpdateDerived()
    SetStatusText(Bi("切到" . (mode = "long" ? "长模式" : "短模式") . "：ctx=" . p.ctx . " / resident="
        . p.resident . " / mtp=" . p.mtp . " / MTP " . p.mtp . "（port/cors/thinking 保留原值）",
        "Switched to " . (mode = "long" ? "long mode" : "short mode") . ": ctx=" . p.ctx . " / resident="
        . p.resident . " / mtp=" . p.mtp . " (port/cors/thinking kept)"), "000080")
    Tip(Bi((mode = "long" ? "长模式" : "短模式") . "：ctx=" . p.ctx . " / " . p.kv
        . (p.resident > 0 ? " / 流式" . p.resident : " / 全常驻") . " / MTP " . p.mtp,
        (mode = "long" ? "long mode" : "short mode") . ": ctx=" . p.ctx . " / " . p.kv
        . (p.resident > 0 ? " / streaming " . p.resident : " / fully resident") . " / MTP " . p.mtp))
}

; 上次启动时服务端算出的容量估算（results/capacity.json）；模型或 kv 对不上就返回 ""
; 最近一次请求的草稿接受率（引擎日志里 "drafts accepted N of M"）；没有就返回 ""

DraftAcceptText(mode) {
    ro := CtlObserve(mode)
    if (!IsObject(ro) || ro["accept_b"] <= 0)
        return ""
    return ro["accept_pct"] . "%  (" . ro["accept_a"] . "/" . ro["accept_b"] . ")"
}

; 边界行的前缀（中/英）

BoundsLabel() {
    global gLang
    return (gLang = "en" ? "Bounds: " : "边界检查: ")
}

; 模型名 + kv 拼出的文件名（服务端 serve/prepare.py 的 ensure_fit 用同一套规则写）

; MTP 三种状态（在显存 / 在 CPU / 关闭）可用显存差 300+ MiB，建议值不同 -> 文件名分开
MtpSlug(mtp, cpuMoe) {
    if (mtp = "off")
        return "nomtp"
    return (cpuMoe = "on" || cpuMoe = "1") ? "mtpcpu" : "mtpgpu"
}

CapacitySlug(native, kv, mtpMode) {
    return RegExReplace(BaseName(native), "[^A-Za-z0-9._-]+", "_") . "-" . RegExReplace(kv, "[^A-Za-z0-9._-]+", "_") . "-" . mtpMode
}

; 上次启动时服务端算出的容量估算：只认「模型+kv(+cpumoe) 各一份」
; legacy 的 capacity.json 是「最近一次」跑出来的，分不清是哪个配置（MTP 在显存还是在 CPU 差 ~300 MiB），
; 拿它当别的模式看会误导，所以不再兜底。
CapacityFile(native, kv, mtpMode) {
    global RESULTS
    return RESULTS . "\capacity\" . CapacitySlug(native, kv, mtpMode) . ".json"
}

; 中间层返回的 capacity（字段与下面的内置解析完全一致），带按 key 的缓存：
;   界面每 5 秒刷一次状态、每次改参数都会调 CapacityInfo/Boundary，不缓存就是每 5 秒起一个 Python。
CtlCapacity(native, kv, mtpMode) {
    ; R11：bounds 从同一次 plan 里取（不再单独起一个 Python）
    global PY
    static cache := Map()
    if (native = "" || PY = "" || !FileExist(PY))
        return 0
    key := native . "|" . kv . "|" . mtpMode
    if cache.Has(key)
        return cache[key]
    mode := (mtpMode = "nomtp") ? "off" : (mtpMode = "mtpcpu" ? "cpu" : "gpu")
    stub := {ram: {total: 0, free: -1}, procs: {engine: [], serve: [], guard: []}}
    o2 := Normalize({native: native, kv: kv, mtp_mode: mode, ctx: "8192", resident: 0,
                     reserve: 64, port: 1339})
    all := CtlPlanAll(o2, 0, stub)
    if (!IsObject(all) || !all["bounds"]["measured"]) {
        cache[key] := 0
        return 0
    }
    b := all["bounds"]
    c := {ctx: b["ctx"], basis: b["basis"], suggest: b["suggest"], budget: b["budget"],
          slot: b["slot"], kvpt: b["kvpt"], ceiling: b["ceiling"]}
    cache[key] := c
    return c
}

; 读出一份 capacity：返回 {ctx, basis}，读不到就返回 0
CapacityInfo(native, kv, mtpMode) {
    ; P2：唯一的读取口是中间层 strata/ctl/fit.py（口径、校验、字段都在那边）；
    ; ctl 不可用（没有 Python / 包没带 ctl）时才走下面的内置解析，保证便携包仍能显示。
    c := CtlCapacity(native, kv, mtpMode)
    if (IsObject(c))
        return c
    global RESULTS
    f := CapacityFile(native, kv, mtpMode)
    if (f = "" || !FileExist(f))
        return 0
    try {
        s := FileRead(f, "UTF-8")
        if (RegExMatch(s, '"model"\s*:\s*"([^"]*)"', &m1) && RegExMatch(s, '"kv"\s*:\s*"([^"]*)"', &m2)
            && RegExMatch(s, '"ctx_estimate"\s*:\s*(\d+)', &m3)) {
            if (StrLower(m1[1]) != StrLower(BaseName(native)) || m2[1] != kv)
                return 0
            ; 文件名已含 mtp 模式，文件里的 mtp_cpu_moe 只做一次兜底校验
            if (RegExMatch(s, '"mtp_cpu_moe"\s*:\s*(true|false)', &m4) && mtpMode != "nomtp" && ((m4[1] = "true") != (mtpMode = "mtpcpu")))
                return 0
            basis := (RegExMatch(s, '"ctx_estimate_basis"\s*:\s*"([a-z]+)"', &m5) ? m5[1] : "vram")
            sug := (RegExMatch(s, '"ctx_suggested"\s*:\s*(\d+)', &m6) ? Integer(m6[1]) : 0)
            bud := (RegExMatch(s, '"vram_budget_mib"\s*:\s*(\d+)', &m7) ? Integer(m7[1]) : 0)
            smi := (RegExMatch(s, '"expert_slot_mib"\s*:\s*([\d.]+)', &m8) ? Float(m8[1]) : 0.0)
            kvt := (RegExMatch(s, '"kv_measured_mib_per_token"\s*:\s*([\d.]+)', &m9) ? Float(m9[1]) : 0.0)
            ceil := (RegExMatch(s, '"ctx_ceiling_measured"\s*:\s*(\d+)', &m10) ? Integer(m10[1]) : 0)
            return {ctx: Integer(m3[1]), basis: basis, suggest: sug, budget: bud, slot: smi, kvpt: kvt, ceiling: ceil}
        }
    }
    return 0
}

; 口径：basis=ram 是"内存能装下多少 KV"（上限），basis=vram 是"整窗常驻显存"（下限）
CapacityLabel(ci) {
    global gLang
    if (ci.basis = "ram")
        return (gLang = "en" ? "RAM bound <=" : "内存上限 ≤") . ci.ctx . " ctx"
    return (gLang = "en" ? "VRAM-window >=" : "整窗常驻 ≥") . ci.ctx . " ctx"
}

CapacityText(native, kv, mtpMode) {
    ci := CapacityInfo(native, kv, mtpMode)
    return ci ? CapacityLabel(ci) : ""
}

; 边界行末尾那半句：只有"内存先撞"或"这个组合没实测过"时才显示。
; 否则会跟实测天花板打架（例：内存上限 262144 而实测 81920 就已经是上限，
;   用户会以为 262144 能开 —— 实测发现引擎在 262144 下连 MTP 的显存专家层都分不到）。
; 从引擎启动日志里标定「这台机器 + 这个量化」的两件事：
;   槽大小   = 实际缓存 MiB ÷ 实际槽位        （日志里有 expert cache N slots, X GiB）
;   KV/token = (服务端算的显存预算 − 实际缓存) ÷ 这次配的 ctx
; 有了这两个数，建议值和建议上限就能按当前量化算，而不是套 IQ3_S 的死表。
; 引擎启动日志里能直接读出「这次 ctx 分到了多少专家槽」。
; 只用来提示"ctx 太大，缓存被挤光"（状态行），不去反推上限 ——
; 单点数据分不清 KV 与固定开销（verify 窗口/prompt 缓冲），反推出来的上限会明显偏低。
; 从运行中的引擎日志反推「这个模型真实的 K/V 显存成本」（MiB/token），写回同一份 capacity：
;   下一次启动时 prepare 会优先用它来算建议值（比 0.032 的保守回退值准）。
; 实测依据：Cyber IQ4_XS 31.4/36.1/29.2 KiB/token（≈完整 KV）；IQ3_S 约 12 KiB（部分流式）。
RecordMeasuredKvpt(mode) {
    ; 只写"确定属于这次启动"的实测点，否则会把上一轮的槽位记到别的模式/ctx 名下
    ; （踩过：cpu 档的 949 槽被记成了 gpu 档 @20480）。
    o := CollectFields()
    nv := Prop(o, "native", "")
    if (nv = "")
        return 0
    el := EngineLogFor(mode), sl := ServerLogFor(mode), cf := RunCfgFor(mode)
    if (!FileExist(el) || !FileExist(cf))
        return 0
    ; 1) 日志必须比 run 配置新（配置是启动时写的，日志是之后生成的）
    if (FileGetTime(el, "M") < FileGetTime(cf, "M"))
        return 0
    cfgTxt := ""
    try cfgTxt := FileRead(cf, "UTF-8")
    ctxSeen := 0
    if RegExMatch(cfgTxt, '"--max-context"\s*,\s*"(\d+)"', &mc)
        ctxSeen := Integer(mc[1])
    if (ctxSeen <= 0)
        return 0
    ; 2) 服务端日志里的 context 必须与配置一致（否则日志是别的 ctx 那次的）
    st := TailOf(sl, 40000)
    sseg := st.text
    if (pp := InStr(sseg, "starting the engine"))
        sseg := SubStr(sseg, pp)
    if !RegExMatch(sseg, "context (\d+) tokens", &mctx)
        return 0
    if (Integer(mctx[1]) != ctxSeen)
        return 0
    ; 3) 槽位取引擎日志最后一条
    ; 只认"最后一次启动之后"的那一段（日志可能含更早的 run，直接取 tail 会混进来）
    tl := TailOf(el, 40000)
    seg := tl.text
    if (pp := InStr(seg, "starting the engine"))
        seg := SubStr(seg, pp)
    if !RegExMatch(seg, "expert cache (\d+) slots, ([\d.]+) GiB", &mm)
        return 0
    slots := Integer(mm[1])
    cacheMib := Round(Float(mm[2]) * 1024)
    mtpMode := InStr(cfgTxt, '"--mtp-cpu-moe"') ? "mtpcpu" : (InStr(cfgTxt, '"--mtp"') ? "mtpgpu" : "nomtp")
    ci := CapacityInfo(nv, o.kv, mtpMode)
    if (!IsObject(ci) || ci.budget <= 0)
        return 0
    kvpt := (ci.budget - cacheMib) / ctxSeen
    f := CapacityFile(nv, o.kv, mtpMode)
    body := ""
    try body := FileRead(f, "UTF-8")
    qt := Chr(34)
    if (body = "" || InStr(body, qt . "measured_ctx" . qt . ": " . ctxSeen . ",") && InStr(body, "measured_verified"))
        return 0
    body := RTrim(RTrim(body, "`n"), "}")
    body .= ",`n  " . qt . "kv_measured_mib_per_token" . qt . ": " . Round(kvpt, 5)
    body .= ",`n  " . qt . "measured_ctx" . qt . ": " . ctxSeen
    body .= ",`n  " . qt . "measured_slots" . qt . ": " . slots
    body .= ",`n  " . qt . "measured_cache_mib" . qt . ": " . cacheMib
    body .= ",`n  " . qt . "measured_verified" . qt . ": true`n}"
    try FileDelete(f)
    try FileAppend(body, f, "UTF-8-RAW")
    return 1
}

RecordStartupFit(mode) {
    tl := TailOf(EngineLogFor(mode), 60000)
    if !IsObject(tl)
        return 0
    parts := StrSplit(tl.text, "engine started")
    tail := parts.Length > 1 ? parts[parts.Length] : tl.text
    if !RegExMatch(tail, "expert cache (\d+) slots, ([\d.]+) GiB", &mm)
        return 0
    slots := Integer(mm[1]), cacheMib := Round(Float(mm[2]) * 1024)
    if (slots <= 0)
        return 0
    gFitSlots := slots, gFitCacheMib := cacheMib
    return slots
}


CapacityTail(o) {
    global gLang
    b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"), Prop(o, "native", ""))
    ci := CapacityInfo(Prop(o, "native", ""), o.kv, MtpSlug(Prop(o, "mtp", "on"), Prop(o, "mtp_cpu_moe", "off")))
    if (!ci)
        return ""
    ; 服务端按「保留 5% 专家槽」算出的建议（量化自适应）；超过它就提示
    if (ci.suggest > 0 && o.ctx > ci.suggest)
        return (gLang = "en" ? "  ·  suggested <= " . ci.suggest . " (keeps the expert cache alive)"
                             : "  ·  建议 ≤" . ci.suggest . "（再大会挤光专家缓存）")
    if (b.measured && ci.ctx >= b.ok)
        return ""
    return "  ·  " . CapacityLabel(ci)
}

; 简洁模式改了 ctx 时，把专业模式的「边界检查」那行也刷新

; 重算边界行。5 秒定时器也会调它 —— 首启时 capacity 文件是服务端在引擎加载前写的，
; 不重算的话界面会一直停在"还没有本机数据"。
RefreshBoundsLine() {
    global bndT, gUiMode, gRebuilding
    if (gRebuilding || !IsSet(bndT) || !IsObject(bndT))
        return
    o := (gUiMode = "simple" ? SimpleCollect() : CollectFields())
    if (o.ctx > 0 && o.resident >= 0) {
        bndT.SetFont("s9 " . (BoundaryExceeded(o) ? "cC00000" : "c006400"))
        bndT.Text := BoundsLabel() . BoundaryText(o)
    }
}

UpdateDerived() {
    global bndT, g, gLinks, gMonitorOn
    if !IsSet(bndT) || !IsObject(bndT)
        return
    o := CollectFields()
    if (o.ctx > 0 && o.resident >= 0) {
        bad := BoundaryExceeded(o)
        bndT.SetFont("s9 " . (bad ? "cC00000" : "c006400"))
        bndT.Text := BoundsLabel() . BoundaryText(o)
    }
    MakeLinks(o.port > 0 ? o.port : 1339, gMonitorOn)
    UpdateSimpleDerived(o.port > 0 ? o.port : 1339)
}

; 链接行：只放"确实可用"的端点。/api-monitor 是请求监控页，服务端默认关闭
; （config 里 api_monitor: true 或 --api-monitor 才开），关着时它返回 404 的 JSON
; —— 所以只在探到 200 时才出现这一项；平时用始终可用的 /metrics（网页聊天里"监控"页签的数据源）。

LinkItems(base, monitorOn) {
    items := [[Tf("网页聊天"), base . "/"],
              ["/props", base . "/props"],
              ["/v1/models", base . "/v1/models"],
              ["/slots", base . "/slots"],
              ["/health", base . "/health"],
              ["/metrics", base . "/metrics"]]
    if monitorOn
        items.Push([Tf("API 监控"), base . "/api-monitor"])
    return items
}

HasHref(items, needle) {
    for it in items
        if InStr(it[2], needle)
            return true
    return false
}

MonitorOn(port) {                       ; 请求监控页是否真的可用（404 = 没开）
    return HttpGet("http://127.0.0.1:" . port . "/api-monitor", 1200).status = 200
}

MakeLinks(port, monitorOn := false) {
    global g, gLinks, LINK_Y, LINK_X0, LINK_DX, LINK_W
    base := "http://127.0.0.1:" . port
    items := LinkItems(base, monitorOn)
    ; Link 控件：不支持创建时给字号（s10 -> Invalid option），也没有 Destroy 方法，
    ; 所以只创建一次、之后原地改 Text（WM_SETTEXT 会让 SysLink 重新解析 href）与位置
    while (gLinks.Length < items.Length) {
        c := g.AddLink("x0 y0 -Wrap cBlue", "")
        c.SetFont("s10")
        gLinks.Push(c)
    }
    for i, it in items {
        c := gLinks[i]
        c.Text := '<a href="' . it[2] . '">' . it[1] . "</a>"
        c.Move(LINK_X0 + (i - 1) * LINK_DX, LINK_Y, LINK_W)
        c.Visible := true
    }
    i := items.Length + 1
    while (i <= gLinks.Length) {
        gLinks[i].Visible := false
        i++
    }
}

; 气泡提醒：简洁模式没有状态栏文字，所以保存/切模式都用气泡（2 秒自动消失）

Tip(msg, isErr := false) {
    global gHasGui
    if !gHasGui
        return
    ToolTip(Tf(msg))
    SetTimer(() => ToolTip(), -2000)
}

ClipText(s, n) {                        ; 超长反馈文案截断（两个字宽相差一倍，按字符数保守取）
    s := String(s)
    if (StrLen(s) <= n)
        return s
    return SubStr(s, 1, n - 1) . "…"
}

; 双语短句：只在调用点用，避免 Tf 的片段替换误伤

Bi(zh, en) {
    global gLang
    return (gLang = "en" ? en : zh)
}

; ── 统一的消息出口（R10）：不再有弹窗 ────────────────────────────────────────
; 所有 info / warn / error 都写这份日志 + 上状态行；不阻塞、不打断、不需要用户点"是/否"。
; 判断（能不能启动、有什么风险）由中间层的 [warn.N]/[errors.N] 给，界面只负责呈现。
Notify(kind, text, color := "") {
    global RESULTS, gNotify
    ts := FormatTime(A_Now, "HH:mm:ss")
    msg := {kind: kind, text: text, at: ts}
    gNotify := msg
    try {
        DirCreate(RESULTS)
        FileAppend(ts . " [" . kind . "] " . text . "`n",
            RESULTS . "\strata-launcher-messages.log", "UTF-8")
    }
    col := (color != "") ? color : (kind = "error" ? "C00000" : (kind = "warn" ? "B8860B" : "000080"))
    try SetStatusText((kind = "error" ? "✕ " : (kind = "warn" ? "! " : "")) . text, col)
    try SimpleNotify(msg)               ; 简洁视图也有同一句
    return msg
}


SetStatusText(t, color) {               ; 反馈行只存在于专业模式（简洁模式不放这一行）
    global logs
    col := (color = "" || color = "000000" ? "c000080" : "c" . color)
    if IsSet(logs) && IsObject(logs) {
        logs.SetFont("s8 " . col)
        logs.Text := Tf("最近动作: ") . FormatTime(A_Now, "HH:mm:ss") . "  " . ClipText(Tf(t), 70)
    }
}

RefreshStatus() {
    global st1, st2, st3, st4, st5, st6, tailE, gMonitorOn, gRebuilding
    if gRebuilding
        return                                 ; 窗口正在重建：控件已经销毁，别碰
    o := CollectFields()
    st := QueryStatus(o.port > 0 ? o.port : 1339)
    sl := StateLine(st)
    st1.SetFont("s9 Bold c" . sl.color)
    st1.Text := sl.text
      nz := Tf("无")
      st2.Text := Tf("进程: 引擎 ") . (st.procs.engine.Length ? st.procs.engine[1] : nz)
              . Tf(" · 服务端 ") . (st.procs.serve.Length ? st.procs.serve[1].pid : nz)
              . Tf(" · 驱动 ") . (st.procs.driver.Length ? st.procs.driver[1].pid : nz)
              . Tf(" · 护栏 ") . (st.procs.guard.Length ? st.procs.guard[1] : nz)
              . " · cmd " . st.procs.launcher.Length
    extra := ""
    if (st.nCtx)
        extra .= " · n_ctx=" . st.nCtx
    ; 别名在「模型」那行已显示，状态行省掉
    if (st.sleeping != "")
        extra .= " · is_sleeping=" . st.sleeping
    ; 请求监控（/api-monitor）默认是关的：只在服务端确实在跑时探一次，状态变了就重建链接行
    ; （免得给出一个点了 404 的死链接）
    mon := (st.state = "running") ? MonitorOn(st.port) : false
    if (mon != gMonitorOn) {
        gMonitorOn := mon
        MakeLinks(st.port)
    }
    acc := (st.state = "running" || st.state = "loading") ? DraftAcceptText(o.mode) : ""
    ; 引擎在跑：拿它的启动日志标定「这台机器 + 这个量化」的槽大小与 KV/token（内部去重，不会反复写）
    if (st.state = "running")
        try RecordStartupFit(o.mode)
        try RecordMeasuredKvpt(o.mode)
        ; 单行 492px 放不下"端口 + /props + 模式 + 监控 + 草稿接受"五段：
        ; 按重要性取舍（草稿接受 > 模式 > 监控），量真实像素宽，放不下的整段丢掉。
        ; 单行 492px 放不下"端口 + /props + n_ctx + 模式 + 监控 + 草稿接受"六段：
        ; 必显段只留"端口 + /props"（能一眼判断死活），其余按重要性取舍 ——
        ; 草稿接受最容易被裁掉，所以它排第一个（这正是用户报的那个显示不全）。
        st3Base := Tf("端口 ") . st.port . " · /props " . (st.http.ok ? "HTTP " . st.http.status : Tf("无响应"))
        ; 草稿接受是本行最有信息量的一段，所以给长/短两档：计数放不下就只留百分比。
        ; （实测 1518/1648 这种四位数计数会把整段挤出去，之前就是因此看不到）
        accLong := (acc != "") ? " · " . Tf("草稿接受 ") . acc : ""
        accShort := (acc != "") ? " · " . Tf("草稿接受 ") . Round(Float(RegExReplace(acc, "^(\d+).*", "$1"))) . "%" : ""
        ; 可用宽度问控件本身（DPI 安全）：写死数字会在 125%/150% 下低估，导致"量着放得下、实际被裁"
        cw := 486
        if ControlGetPos(&cx, &cy, &cw2, &ch, st3)
            cw := cw2 - 4
        st3Groups := []
        if (acc != "")
            st3Groups.Push([accLong, accShort])
        if (extra != "")
            st3Groups.Push(extra)
        if (st.mode != "")
            st3Groups.Push(" · " . (st.mode = "long" ? Tf("长") : Tf("短")) . Tf("模式"))
        st3Groups.Push(" · " . Tf("监控 ") . (mon ? Tf("开") : Tf("关")))
        st3.Text := FitVariants(st3, st3Base, st3Groups, cw)
    c := (st.ram.free >= 0 && st.ram.free < RAM_ABORT_MB) ? "cC00000"
       : (st.ram.free >= 0 && st.ram.free < MODEL_NEED_MB ? "cB8860B" : "c006400")
    st4.SetFont("s8 " . c)
        ; 行宽有限：有 low-RAM / 槽位提示时，省掉"护栏阈值/模型要 12 GiB"那段括号，让提示放得下
        memTail := LowRamSuffix(st, o.mode) . SlotSuffixFor(st, o.mode)
        st4.Text := Tf("内存: 空闲 ") . Round(st.ram.free / 1024, 1) . Tf(" GiB / 共 ") . Round(st.ram.total / 1024, 1)
            . (memTail != ""
                ? " GiB" . memTail
                : Tf(" GiB（护栏阈值 <") . RAM_ABORT_MB . Tf(" MB 杀引擎；模型要 ~12 GiB）"))
    snap := GpuSnapshotCached(false)
    others := VramOccupants(snap, st)
    over := (snap.used >= 0 && snap.used > VRAM_WARN_MIB)
    mine := st.procs.engine.Length || st.procs.serve.Length      ; 本次实例自己在跑
    if (snap.used < 0)
        occ := ""
    else if mine
        occ := "（本次实例）"
            . (others.Length ? " · 另有 " . VramWho(others) : "")
    else
        occ := (over ? "（超过 " . VRAM_WARN_MIB . " MiB 阈值 → 启动前会提醒）"
                    . (others.Length ? " · 占用: " . VramWho(others) : "")
                    : "（低于 " . VRAM_WARN_MIB . " MiB 阈值 → 启动前不提醒）")
    st5.SetFont("s8 " . (snap.used < 0 ? "c606060" : (over ? "cC00000" : "c006400")))
    st5.Text := Tf("显存: ") . (snap.used < 0
        ? Tf("读不到（nvidia-smi 不可用）")
        : Tf("已用 ") . snap.used . " / " . snap.total . " MiB") . Tf(occ)
    miss := []
    if !FileExist(PY)
        miss.Push("venv python")
    if !FileExist(DRIVER)
        miss.Push("驱动")
    if !FileExist(BASE_CFG)
        miss.Push("模板配置")
    logMode := (st.mode != "" ? st.mode : o.mode)
    tail := TailOf(ServerLogFor(logMode), 20000)
    st6.SetFont("s8 " . (miss.Length ? "cC00000" : "c006400"))
    st6.Text := Tf("文件自检: ") . (miss.Length ? Tf("缺 ") . Join(miss, Tf("、")) : Tf("齐全"))
        . " · " . (logMode = "long" ? Tf("长") : Tf("短")) . Tf("模式日志 ") . (tail.mtime != "" ? tail.mtime : Tf("无"))
    tailE.Value := NewestFirst(tail.text, 16)
    ; 首启 / 换模型后：capacity 文件由服务端在引擎加载前写好，这里跟着刷新边界行
    try RefreshBoundsLine()
    SimpleStatusUpdate(st)                  ; 简洁模式那边只更新状态图
}

RefreshTick() {
    global guiAlive, gDriverPid, gRebuilding
    if (!guiAlive || gRebuilding)
        return
    ; 后台驱动（cmd 包装进程）没了 -> 说明这次启动/预览结束了，查一次日志尾部再报状态
    if (gDriverPid && !ProcessExist(gDriverPid)) {
        gDriverPid := 0
        ReviewDriverExit()
    }
    RefreshStatus()
}

OnClose(*) {
    global guiAlive
    guiAlive := false
    SaveIni(CollectCurrent())
    ExitApp()
}

BuildGui() {
    global
    opt := "-MaximizeBox"
    if ONTOP
        opt := "+AlwaysOnTop " . opt       ; 只有 --ontop 时才置顶（调试用）；正常使用不置顶
    g := Gui(opt, Tf("TinyStrata 启动器") . "  v" . APP_VER)
    gHasGui := true
    g.SetFont("s9", "Segoe UI")
    g.AddGroupBox("x8 y8 w704 h102", "模式（切换按预设覆盖 ctx/kv/resident/mtp/reserve/preserve 等模式相关参数）")
    g.AddButton("x612 y26 w96 h28", "简洁模式 →").OnEvent("Click", (*) => SwitchTo("simple"))
    rShort := g.AddRadio("x22 y32 w110", "短模式（快）")
    rLong := g.AddRadio("x150 y32 w160", "长模式（长上下文）")
    rShort.Value := 1
    bndT := g.AddText("x22 y94 w676 c006400", "边界检查: —")
    rShort.OnEvent("Click", (*) => ApplyPreset("short"))
    rLong.OnEvent("Click", (*) => ApplyPreset("long"))
    g.AddText("x22 y56 w676 c404040", "ctx 上下文窗口 · kv K/V 存储（k8v4 最省显存）· mtp 草稿专家放哪（gpu 显存 / cpu 内存）· reserve 留给别人 · resident 留空=不写、0=显式全常驻、≥20480=流式")
    g.AddText("x22 y74 w676 c404040", "能开多大 ctx 由模型的显存占用与 kv 方式决定，不由预设决定；边界检查按本机实测表算")
    g.AddGroupBox("x8 y118 w704 h206", "参数（改完直接点启动；字段名与驱动一致）")
      ; 模型两行（与简洁模式同形状）：标签 + 只读路径 + 选择…
    g.AddText("x22 y142 w44", "GGUF")
    nativeE := g.AddEdit("x70 y138 w400 h24 ReadOnly", "")
    nativeE.SetFont("s8")
    g.AddButton("x474 y136 w70 h26", "选择…").OnEvent("Click", (*) => PickNative())
    g.AddText("x22 y168 w50", "mmproj")
    mmprojE := g.AddEdit("x76 y164 w394 h24 ReadOnly", "")
    mmprojE.SetFont("s8")
    g.AddButton("x474 y162 w70 h26", "选择…").OnEvent("Click", (*) => PickMmproj())
    ; 4 列网格：标签宽 76 / 输入宽 76 / 列距 160（列起点 x22 / x182 / x342 / x502）
    g.AddText("x22 y200 w76", "ctx")
    ctxE := g.AddEdit("x98 y196 w76", "20480")
    g.AddText("x182 y200 w76", "kv")
    kvD := g.AddDropDownList("x258 y196 w76", KV_LIST)
    g.AddText("x342 y200 w76", "resident")
    resE := g.AddEdit("x418 y196 w76", "0")
    g.AddText("x502 y200 w76", "mtp")
    gMtpList := (gUiMode = "long" ? MTP_LIST_LONG : MTP_LIST_SHORT).Clone()
    mtpD := g.AddDropDownList("x578 y196 w76", gMtpList)
    g.AddText("x22 y230 w76", "draft-vocab")
    draftD := g.AddDropDownList("x98 y226 w76", DRAFT_LIST)
    g.AddText("x182 y230 w76", "vram-reserve")
    resvE := g.AddEdit("x258 y226 w76", "256")
    g.AddText("x342 y230 w76", "port")
    portE := g.AddEdit("x418 y226 w76", "1339")
    g.AddText("x502 y230 w76", "cors")
    corsE := g.AddEdit("x578 y226 w76", "*")
    g.AddText("x22 y260 w76", "thinking")
    thinkD := g.AddDropDownList("x98 y256 w76", YN_LIST)
    g.AddText("x182 y260 w76", "preserve-think")
    presD := g.AddDropDownList("x258 y256 w76", YN_LIST)
    g.AddText("x342 y260 w76", "host")
    hostE := g.AddEdit("x418 y256 w76", "")
    g.AddText("x502 y260 w76", "api-key")
    keyE := g.AddEdit("x578 y256 w76", "")
    keyCopy := g.AddButton("x662 y254 w42 h26", "复制")
    keyCopy.OnEvent("Click", (*) => CopyWithFeedback(keyCopy, keyE.Value, "复制", "api-key 为空"))
    g.AddText("x22 y286 w76", "vision")
    visD := g.AddDropDownList("x98 y282 w76", VISION_LIST)
    g.AddText("x182 y286 w100", "vision-tokens")
    vistokE := g.AddEdit("x282 y282 w60", "300")
    g.AddText("x352 y286 w330 c404040", "off=关 / cpu=不占显存 / gpu=占~1.2GB")
    g.AddText("x22 y312 w58", "模板")
    chatTplE := g.AddEdit("x82 y308 w286", "")
    g.AddButton("x374 y306 w56 h24", "选择…").OnEvent("Click", (*) => PickChatTpl())
    g.AddText("x436 y312 w150 c404040", "留空=用 pack 自带")
    g.AddGroupBox("x8 y332 w704 h64", "采样（留空 = 该键不写；thinking=off → reasoning_effort=none）")
    ; 7 列网格：标签宽 46 / 输入宽 44 / 列距 98（列起点 x22/120/218/316/414/512/610）
    g.AddText("x22 y356 w46", "temp")
    tempE := g.AddEdit("x72 y352 w44", "0.6")
    g.AddText("x120 y356 w46", "top_p")
    toppE := g.AddEdit("x170 y352 w44", "0.95")
    g.AddText("x218 y356 w46", "top_k")
    topkE := g.AddEdit("x268 y352 w44", "20")
    g.AddText("x316 y356 w46", "min_p")
    minpE := g.AddEdit("x366 y352 w44", "")
    g.AddText("x414 y356 w46", "pres_pen")
    prespenE := g.AddEdit("x464 y352 w44", "")
    g.AddText("x512 y356 w46", "rep_pen")
    reppenE := g.AddEdit("x562 y352 w44", "")
    g.AddText("x610 y356 w46", "dry")
    dryE := g.AddEdit("x660 y352 w44", "")
    g.AddText("x22 y380 w676 c404040", "对应这些 --xxx 参数（写进 sampling 块）；dry = 重复序列惩罚，空=用模板值 1.5，0=关")
    portE.OnEvent("Change", (*) => UpdateDerived())
    ctxE.OnEvent("Change", (*) => UpdateDerived())
    resE.OnEvent("Change", (*) => UpdateDerived())
    kvD.OnEvent("Change", (*) => UpdateDerived())
    mtpD.OnEvent("Change", (*) => UpdateDerived())
    g.AddButton("x8 y410 w88 h32", "启动").OnEvent("Click", (*) => DoLaunch(false))
    g.AddButton("x102 y410 w88 h32", "重启").OnEvent("Click", (*) => DoRestart())
    g.AddButton("x196 y410 w104 h32", "预览(--check)").OnEvent("Click", (*) => DoLaunch(true))
    g.AddButton("x306 y410 w72 h32", "停止").OnEvent("Click", (*) => DoStop())
    g.AddButton("x384 y410 w72 h32", "刷新状态").OnEvent("Click", (*) => RefreshStatus())
    g.AddButton("x462 y410 w110 h32", "打开日志目录").OnEvent("Click", (*) => OpenPath(RESULTS))
    g.AddButton("x578 y410 w134 h32", "保存为默认").OnEvent("Click", (*) => SaveIni(CollectCurrent()))
    ; ---- 右栏（状态与日志）：x724 起，宽 448 ----
    g.AddGroupBox("x724 y8 w520 h182", "运行状态（每 5 秒刷新）")
    g.SetFont("s8", "Segoe UI")
    ; 每行显式 h18：Text 的自动高度比字形框矮 2-3px，首行顶/末行底会被切
    st1 := g.AddText("x738 y28 w492 h18", "运行状态: -")
    st2 := g.AddText("x738 y49 w492 h18", "进程: -")
    st3 := g.AddText("x738 y70 w492 h18", "端口: -")
    st4 := g.AddText("x738 y91 w492 h18", "内存: -")
    st5 := g.AddText("x738 y112 w492 h18", "显存: -")
    st6 := g.AddText("x738 y133 w492 h18", "文件自检: -")
    logs := g.AddText("x738 y154 w492 h34 c000080", "最近动作: -")   ; 反馈文案可能很长：给两行
    g.SetFont("s9", "Segoe UI")
    g.AddGroupBox("x8 y" . LINK_BOX_Y . " w704 h56", "浏览器链接（点击用默认浏览器打开；端口跟随上面的 port 字段）")
    g.AddGroupBox("x724 y198 w520 h96", "日志与配置")
    g.AddButton("x738 y222 w116 h28", "引擎日志").OnEvent("Click", (*) => OpenPath(EngineLogFor(CollectFields().mode)))
    g.AddButton("x858 y222 w116 h28", "服务端日志").OnEvent("Click", (*) => OpenPath(ServerLogFor(CollectFields().mode)))
    g.AddButton("x978 y222 w116 h28", "驱动输出").OnEvent("Click", (*) => OpenPath(DriverLogFor(CollectFields().mode)))
    g.AddButton("x1098 y222 w116 h28", "护栏日志").OnEvent("Click", (*) => OpenPath(GUARD_LOG))
    g.AddButton("x738 y256 w116 h28", "运行配置 json").OnEvent("Click", (*) => OpenPath(RunCfgFor(CollectFields().mode)))
    g.AddButton("x858 y256 w116 h28", "模板配置").OnEvent("Click", (*) => OpenPath(BASE_CFG))
    g.AddButton("x978 y256 w116 h28", "自检报告").OnEvent("Click", (*) => OpenPath(SELFLOG))
    g.AddGroupBox("x724 y302 w520 h210", "服务端日志尾部（自动刷新；最新在最上；往下滚是历史）")
    tailE := g.AddEdit("x734 y318 w500 h184 ReadOnly Multi VScroll", "")
    tailE.SetFont("s8", "Consolas")
    gLinks := []
    guiAlive := true
    g.OnEvent("Close", OnClose)
    AddMenus(g)
    TranslateGui(g)
    return g
}

; ------------------------------------------------- 6b. 简洁模式
; 简洁模式 = 同一个参数集合的另一套视图。只暴露：模式 / 上下文长度 / 启用思考 / preserve-thinking /
; 端口 / api-key；其余字段（kv、resident、mtp、draft-vocab、vram-reserve、cors、host）继续沿用
; gParams 里的原值 —— 所以两个界面来回切、或在简洁模式里切模式，都不会把专业模式的设置弄丢。

CollectCurrent() {
    global gUiMode
    return (gUiMode = "simple") ? SimpleCollect() : CollectFields()
}

SetCurrent(o) {
    global gUiMode, gParams
    gParams := Normalize(o)                  ; 每次"把参数推进界面"都同时刷新基准集合
    if (gUiMode = "simple")
        SetSimpleFields(o)
    else
        SetFields(o)
}

; 状态图：简洁模式只讲四件事

StateBadge(st) {
    if (st.state = "running")
        return {glyph: "●", word: Tf("运行中"), color: "008000"}
    if (st.state = "loading")
        return {glyph: "◐", word: Tf("加载中…"), color: "B8860B"}
    if (st.state = "zombie")
        return {glyph: "✕", word: Tf("异常"), color: "C00000"}
    return {glyph: "○", word: Tf("未运行"), color: "808080"}
}

ChatUrl(port) {                              ; 网页聊天
    return "http://127.0.0.1:" . port . "/"
}

BaseUrl(port) {                              ; 粘给客户端用的 OpenAI 兼容 base_url
    return "http://127.0.0.1:" . port . "/v1"
}

; 复制到剪贴板，并在按钮上给 1.5 秒反馈

CopyWithFeedback(btn, text, label, emptyMsg := "") {
    if (Trim(text) = "" && emptyMsg != "") {
        btn.Text := emptyMsg
        SetTimer(() => btn.Text := label, -2500)
        return
    }
    A_Clipboard := text
    btn.Text := "已复制"
    SetTimer(() => btn.Text := label, -1500)
}

SimpleCollect() {
    global sCtxE, sPortE, sKeyE, sThinkCB, sPresCB, sShortR, sLongR, gParams, sVisD, sVisTokE
    global sNativeE, sMmprojE
    o := Normalize(gParams)                  ; 隐藏字段用基准集合里的原值
    o.mode := (sLongR.Value ? "long" : "short")
    o.ctx := IntOr(sCtxE.Value, o.ctx)
    o.port := IntOr(sPortE.Value, o.port)
    o.thinking := (sThinkCB.Value ? "on" : "off")
    o.preserve := (sPresCB.Value ? "on" : "off")
    o.apikey := Trim(sKeyE.Value)
    o.native := Trim(sNativeE.Value)          ; 简洁模式也能指定 GGUF（空 = 用模板里的 --native）
    o.mmproj := Trim(sMmprojE.Value)
    o.pack := (o.native = "" ? "" : FindPackFor(o.native))
    o.vision := DdlText(sVisD, "cpu")
    o.vision_tokens := Trim(sVisTokE.Value, " `t`r`n")
    o.tag := (o.mode = "long" ? "long" : "")
    o.title := ModePreset(o.mode).title
    return o
}

SetSimpleFields(o) {
    global sCtxE, sPortE, sKeyE, sThinkCB, sPresCB, sShortR, sLongR, sVisD, sVisTokE
    global sNativeE, sMmprojE
    o := Normalize(o)
    sCtxE.Value := String(o.ctx)
    sPortE.Value := String(o.port)
    sKeyE.Value := o.apikey
    sNativeE.Value := Prop(o, "native", "")
    sMmprojE.Value := Prop(o, "mmproj", "")
    sThinkCB.Value := (o.thinking = "on")
    sPresCB.Value := (o.preserve = "on")
    sVisD.Text := InList(Prop(o, "vision", "off"), VISION_LIST, "cpu")
    sVisTokE.Value := String(Prop(o, "vision_tokens", "300"))
    UpdateVisionEnabled()
    sShortR.Value := (o.mode = "long" ? 0 : 1)
    sLongR.Value := (o.mode = "long" ? 1 : 0)
    UpdateSimpleDerived(o.port > 0 ? o.port : 1339)
}

; 跟着端口走的两个东西（base_url 文本框 + 网页聊天链接）。端口没变就不动，
; 免得每 5 秒覆盖你正在框里选中的文本。

UpdateSimpleDerived(port) {
    global gSimple, sBaseE, sChatLink, gLastBasePort
    if !IsObject(gSimple)
        return
    if (port <= 0)
        port := 1339
    if (port = gLastBasePort)
        return
    gLastBasePort := port
    sBaseE.Text := BaseUrl(port)
    sChatLink.Text := '<a href="' . ChatUrl(port) . '">' . Tf("打开网页聊天") . "</a>"
}

; 简洁视图的最后一条消息（R10）：没有弹窗了，消息必须有落点
SimpleNotify(msg) {
    global gSimple, sNote
    if (!IsObject(gSimple) || !IsSet(sNote) || !IsObject(sNote))
        return
    if (!IsObject(msg)) {
        sNote.Text := ""
        return
    }
    col := (msg.kind = "error" ? "C00000" : (msg.kind = "warn" ? "B8860B" : "000080"))
    sNote.SetFont("s9 c" . col)
    sNote.Text := msg.at . "  " . ClipText(msg.text, 52)
}


SimpleStatusUpdate(st) {
    global gSimple, sBadge
    if !IsObject(gSimple)
        return
    b := StateBadge(st)
    sBadge.SetFont("s10 c" . b.color)       ; 只换颜色：不放大字号，也不加粗（SetFont 的选项是累积的）
    sBadge.Text := b.glyph . "  " . b.word
}

; 只做 Show/Hide，并让新窗口落在旧窗口的位置上（切模式时别跳）

SwitchWindows(fromGui, toGui, toShow) {
    px := 0, py := 0
    if WinExist("ahk_id " . fromGui.Hwnd)          ; 隐藏窗口 WinExist 为假，所以先量再藏
        WinGetPos(&px, &py, , , "ahk_id " . fromGui.Hwnd)
    fromGui.Hide()
    toGui.Show(toShow)
    hwnd := "ahk_id " . toGui.Hwnd
    if (px || py) {
        WinGetPos(, , &w, &h, hwnd)
        wa := WorkAreaAt(px, py)
        pos := FitPos(px, py, w, h, wa)
        WinMove(pos.x, pos.y, , , hwnd)
    }
}

; 取某个屏幕坐标所在显示器的工作区（去掉任务栏），拿不到就退回主显示器

WorkAreaAt(x, y) {
    try {
        loop MonitorGetCount() {
            i := A_Index
            MonitorGetWorkArea(i, &l, &t, &r, &b)
            if (x >= l && x < r && y >= t && y < b)
                return {l: l, t: t, r: r, b: b}
        }
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        return {l: l, t: t, r: r, b: b}
    } catch {
        return {l: 0, t: 0, r: A_ScreenWidth, b: A_ScreenHeight}
    }
}

; 把窗口左上角夹进工作区：先尽量保持原位，放不下就贴边（这就是"专业模式右侧被切掉"的病根）

FitPos(x, y, w, h, wa) {
    nx := x, ny := y
    if (nx + w > wa.r)
        nx := wa.r - w
    if (ny + h > wa.b)
        ny := wa.b - h
    if (nx < wa.l)
        nx := wa.l
    if (ny < wa.t)
        ny := wa.t
    return {x: nx, y: ny}
}

; 两个界面互切：先把当前界面的值收下来，再喂给另一个界面（不销毁窗口，只 Show/Hide，
; 这样两个窗口的控件一直有效，状态定时器爱更哪个更哪个）

SwitchTo(mode, show := true) {
    global gUiMode, gPro, gSimple, gParams
    if (mode = gUiMode)
        return
    o := CollectCurrent()
    gParams := Normalize(o)
    gUiMode := mode
    if (mode = "simple") {
        SetSimpleFields(o)
        if (show && IsObject(gPro) && IsObject(gSimple))
            SwitchWindows(gPro, gSimple, "w" . SIMPLE_W . " h" . SIMPLE_H)
    } else {
        SetFields(o)
        if (show && IsObject(gPro) && IsObject(gSimple))
            SwitchWindows(gSimple, gPro, "w" . PRO_W . " h" . PRO_H)
    }
    SetStatusText(Bi("已切到" . (mode = "simple" ? "简洁模式" : "专业模式"),
        "Switched to " . (mode = "simple" ? "Simple" : "Pro")), "000080")
    UpdateDerived()
    RefreshStatus()
}

BuildSimpleGui() {
    global
    sg := Gui("-MaximizeBox", Tf("TinyStrata 启动器") . "  v" . APP_VER)
    gHasGui := true
    if ONTOP
        sg.Opt("+AlwaysOnTop")
    sg.SetFont("s10", "Segoe UI")
    sg.AddText("x22 y14 w300", "TinyStrata 启动器  v" . APP_VER)
    sg.AddButton("x344 y8 w108 h28", "专业模式 →").OnEvent("Click", (*) => SwitchTo("pro"))
    sg.AddGroupBox("x8 y44 w444 h48", "模式")
    sShortR := sg.AddRadio("x22 y66 w110", "短模式（快）")
    sLongR := sg.AddRadio("x150 y66 w170", "长模式（长上下文）")
    sShortR.Value := 1
    ; 说明文字按用户要求不显示（用户不关心 kv/mtp 等细节）
    ; sg.AddText("x22 y92 w420 c404040", "短：20K 上下文 / MTP 开　长：64K 上下文、KV 全常驻 / MTP 关（实测更快）")
    sShortR.OnEvent("Click", (*) => ApplyPreset("short"))
    sLongR.OnEvent("Click", (*) => ApplyPreset("long"))
    ; 模型：新用户/便携包最需要这两行 —— 没它们，简洁模式根本没法指定已下载的 GGUF
    sg.AddGroupBox("x8 y100 w444 h84", "模型")
    sg.AddText("x22 y124 w44", "GGUF")
    sNativeE := sg.AddEdit("x70 y120 w268 h24 ReadOnly", "")
    sNativeE.SetFont("s8")
    sg.AddButton("x344 y118 w104 h26", "选择…").OnEvent("Click", (*) => PickNative())
    sg.AddText("x22 y156 w44", "mmproj")
    sMmprojE := sg.AddEdit("x70 y152 w268 h24 ReadOnly", "")
    sMmprojE.SetFont("s8")
    sg.AddButton("x344 y150 w104 h26", "选择…").OnEvent("Click", (*) => PickMmproj())
    sg.AddGroupBox("x8 y192 w444 h152", "参数")
    sg.AddText("x22 y222 w70", "上下文长度")
    sCtxE := sg.AddEdit("x96 y218 w86", "20480")
    sg.AddText("x198 y222 w34", "端口")
    sPortE := sg.AddEdit("x236 y218 w76", "1339")
    sThinkCB := sg.AddCheckBox("x22 y254 w110", "启用思考")
    sPresCB := sg.AddCheckBox("x150 y254 w170", "preserve-thinking")
    sg.AddText("x22 y286 w56", "api-key")
    sKeyE := sg.AddEdit("x82 y282 w214")
    sCopyKey := sg.AddButton("x302 y282 w84 h26", "复制")
    sg.AddText("x22 y318 w56", "图片")
    sVisD := sg.AddDropDownList("x82 y314 w76", VISION_LIST)
    sg.AddText("x166 y318 w50", "图tok")
    sVisTokE := sg.AddEdit("x220 y314 w50", "300")
    sg.AddText("x278 y318 w170 c404040", "cpu=不占显存（推荐）")
    sCopyKey.OnEvent("Click", (*) => CopyWithFeedback(sCopyKey, sKeyE.Value, "复制", "api-key 为空"))
    sCtxE.OnEvent("Change", (*) => (UpdateSimpleDerived(IntOr(sPortE.Value, 1339)), RefreshBoundsLine()))
    sPortE.OnEvent("Change", (*) => UpdateSimpleDerived(IntOr(sPortE.Value, 1339)))
    sg.AddGroupBox("x8 y352 w444 h48", "运行状态")
    sBadge := sg.AddText("x22 y372 w410 h20 c808080", "○  未运行")   ; 与其它文字同号，只靠颜色区分
    sNote := sg.AddText("x22 y392 w410 h18 c808080", "")   ; 最后一条消息（R10 起不再弹窗）
    sg.AddButton("x22 y412 w84 h36", "启动").OnEvent("Click", (*) => DoLaunch(false))
    sg.AddButton("x112 y412 w84 h36", "重启").OnEvent("Click", (*) => DoRestart())
    sg.AddButton("x202 y412 w72 h36", "停止").OnEvent("Click", (*) => DoStop())
    sg.AddButton("x280 y412 w72 h36", "刷新").OnEvent("Click", (*) => RefreshStatus())
    sg.AddButton("x352 y412 w90 h36", "保存为默认").OnEvent("Click", (*) => SaveIni(CollectCurrent()))
    sg.AddGroupBox("x8 y458 w444 h74", "浏览器")
    sChatLink := sg.AddLink("x22 y478 w300 h24 cBlue", "打开网页聊天")   ; 建 Link 时必须给文字/宽度，
    sChatLink.SetFont("s10")                                         ; 空文字建的 Link 宽 0，之后设 Text 也显不出来
    sg.AddText("x22 y508 w60", "接口地址")
    sBaseE := sg.AddText("x86 y506 w250", "")          ; 用 Text 而不是只读 Edit：只读 Edit 会被系统当作
    sCopyBase := sg.AddButton("x344 y500 w70 h26", "复制")   ; 首个可聚焦控件，一打开就是"整段被选中"的样子
    sCopyBase.OnEvent("Click", (*) => CopyWithFeedback(sCopyBase, sBaseE.Text, "复制"))
    gSimple := sg
    ; 刚建好的这两个控件是空的：必须清掉"上次端口"的记忆并立刻填一遍，
    ; 否则从专业模式切过来时 UpdateSimpleDerived 会以为"端口没变"而提前返回，
    ; 结果链接没有 href（点了没反应）、base_url 是空串（复制到空内容）。
    gLastBasePort := -1
    UpdateSimpleDerived(Prop(gParams, "port", 1339) > 0 ? Prop(gParams, "port", 1339) : 1339)
    sg.OnEvent("Close", OnClose)
    AddMenus(sg)
    TranslateGui(sg)
    return sg
}

; ------------------------------------------------- 7. ini 持久化
SaveIni(o) {                             ; 按模式分别存：[short] / [long]，[ui] 存界面状态
    try {
        sec := (o.mode = "long" ? "long" : "short")
        IniWrite(o.mode, INI, "ui", "mode")
        IniWrite(o.ctx, INI, sec, "ctx")
        IniWrite(o.kv, INI, sec, "kv")
        IniWrite(o.resident, INI, sec, "resident")
        IniWrite(o.chat_template, INI, sec, "chat_template")
        IniWrite(o.dry, INI, sec, "dry")
        IniWrite(o.mtp_mode, INI, sec, "mtp_mode")
        IniWrite(o.mtp, INI, sec, "mtp")
        IniWrite(o.draft, INI, sec, "draft")
        IniWrite(o.reserve, INI, sec, "reserve")
        IniWrite(o.port, INI, sec, "port")
        IniWrite(o.cors, INI, sec, "cors")
        IniWrite(o.thinking, INI, sec, "thinking")
        IniWrite(o.preserve, INI, sec, "preserve")
        IniWrite(o.host, INI, sec, "host")
        IniWrite(o.apikey, INI, sec, "apikey")
        IniWrite(o.temperature, INI, sec, "temperature")
        IniWrite(o.top_p, INI, sec, "top_p")
        IniWrite(o.top_k, INI, sec, "top_k")
        IniWrite(o.min_p, INI, sec, "min_p")
        IniWrite(o.presence_penalty, INI, sec, "presence_penalty")
        IniWrite(o.repetition_penalty, INI, sec, "repetition_penalty")
        IniWrite(o.vision, INI, sec, "vision")
        IniWrite(o.vision_tokens, INI, sec, "vision_tokens")
        IniWrite(o.template, INI, sec, "template")
        IniWrite(o.native, INI, sec, "native")
        ; 模型两模式共用：另一节也写同一份，免得重启后切模式又变回旧模型
        IniWrite(o.native, INI, (sec = "long" ? "short" : "long"), "native")
        IniWrite(o.mmproj, INI, sec, "mmproj")
        IniWrite(o.mmproj, INI, (sec = "long" ? "short" : "long"), "mmproj")
        IniWrite(gUiMode, INI, "ui", "ui")
        SetStatusText(Bi("已保存为默认（" . sec . " 模式，ctx=" . o.ctx . "）",
            "Saved as default (" . sec . " mode, ctx=" . o.ctx . ")"), "000080")
        Tip("已保存为默认：" . (o.mode = "long" ? "长" : "短") . "模式 ctx=" . o.ctx)
    } catch as e {
        SetStatusText(Bi("保存失败: ", "Save failed: ") . e.Message, "C00000")
        Tip("保存失败：" . e.Message, true)
    }
}

LoadIni() {
    if !FileExist(INI)
        return false
    try {
        ; 新结构：[ui] mode/ui；每个模式自己的参数在 [short]/[long]。旧 [last] 自动迁移。
        if (IniRead(INI, "ui", "mode", "@@none@@") = "@@none@@" && IniRead(INI, "last", "mode", "@@none@@") != "@@none@@")
            SaveSectionFromLast()
        gUiMode := (IniRead(INI, "ui", "ui", IniRead(INI, "last", "ui", "simple")) = "pro" ? "pro" : "simple")
        mode := IniRead(INI, "ui", "mode", IniRead(INI, "last", "mode", "short"))
        p := LoadSection(mode = "long" ? "long" : "short", mode)
        SetCurrent(p)
        UpdateDerived()
        SetStatusText(Bi(Tf("已载入上次设置（") . (p.mode = "long" ? Tf("长") : Tf("短")) . Tf("模式 ctx=") . p.ctx
            . " port=" . p.port . Tf("），改完点「启动」"),
            "Loaded the previous settings (mode " . p.mode . ", ctx=" . p.ctx . ", port=" . p.port
            . "); press Start when ready"), "000080")
        return true
    } catch
        return false
}

; 从 [short]/[long] 读一个模式的完整参数；该段不存在则用 ModePreset 默认值

LoadSection(sec, mode) {
    p := ModePreset(mode)
    if IniRead(INI, sec, "ctx", "@@none@@") = "@@none@@"
        return p
    for k in ["kv", "mtp_mode", "mtp", "draft", "cors", "thinking", "preserve", "host", "apikey", "chat_template", "dry",
              "temperature", "top_p", "top_k", "min_p", "presence_penalty", "repetition_penalty",
              "vision", "vision_tokens", "template", "native", "mmproj"]
        p.%k% := IniRead(INI, sec, k, Prop(p, k, ""))
    for k in ["ctx", "resident", "reserve", "port"]
        p.%k% := IntOr(IniRead(INI, sec, k, String(Prop(p, k, 0))), Prop(p, k, 0))
    ; MTP 的界面值（gpu/cpu/off）：旧 INI 里没有 mtp_mode，就按模式的默认值来（长=cpu，短=gpu），
    ; 再由它推出引擎要的两个开关（mtp / mtp_cpu_moe）。
    if (p.mtp_mode = "@@none@@" || p.mtp_mode = "") {
        p.mtp_mode := (mode = "long" ? "cpu" : "gpu")
        if (IniRead(INI, sec, "mtp", "on") = "off")
            p.mtp_mode := "off"
    }
    if (mode = "long" && p.mtp_mode = "gpu")
        p.mtp_mode := "cpu"          ; 长模式没有 gpu（专家全上 GPU 装不下 80K 上下文）
    p.mtp := (p.mtp_mode = "off") ? "off" : "on"
    p.mtp_cpu_moe := (p.mtp_mode = "cpu") ? "on" : "off"
    p.spec := SpecForMtp(p.mtp_mode, mode)
    p.mtp_mode := InList(p.mtp_mode, ["gpu", "cpu", "off"], "gpu")   ; 脏值兜底
    return p
}

; 旧 INI（只有 [last]）→ 旧值只写给当时那个模式，其余模式用 ModePreset 默认

SaveSectionFromLast() {
    keys := ["ctx","kv","resident","mtp","draft","reserve","port","cors","thinking","preserve",
             "host","apikey","temperature","top_p","top_k","min_p","presence_penalty","repetition_penalty"]
    oldMode := IniRead(INI, "last", "mode", "short")
    sec := (oldMode = "long" ? "long" : "short")
    for k in keys {
        v := IniRead(INI, "last", k, "@@none@@")
        if (v != "@@none@@")
            IniWrite(v, INI, sec, k)
    }
    IniWrite(oldMode, INI, "ui", "mode")
    IniWrite(IniRead(INI, "last", "ui", "simple"), INI, "ui", "ui")
    IniDelete(INI, "last")
}

IntOr(s, d) {
    s := Trim(s)
    return (s != "" && s ~= "^-?\d+$") ? Integer(s) : d
}

; ------------------------------------------------- 8. 自检
selfBuf := ""

SelfSay(text) {
    global selfBuf
    selfBuf .= text . "`n"
}

SelfCheck(label, cond, detail := "") {
    SelfSay((cond ? "[ OK ] " : "[FAIL] ") . label . (detail = "" ? "" : "  :: " . detail))
    return cond
}

BatObjects() {                          ; .bat 里的原始参数，用来做一致性比对
    short := {mode: "short", ctx: 20480, kv: "k8v4", resident: 0, mtp: "on", draft: "en",
              reserve: 256, port: 1339, cors: "*", thinking: "on", preserve: "on", tag: "",
              host: "", apikey: "",
              title: "Strata - Qwen3.6-35B-A3B UD-IQ3_S"}
    long  := {mode: "long", ctx: 147456, kv: "k8v4", resident: 32768, mtp: "off", draft: "en",
              reserve: 256, port: 1339, cors: "*", thinking: "on", preserve: "off", tag: "long",
              host: "", apikey: "",
              title: "Strata LONG - Qwen3.6-35B-A3B UD-IQ3_S (147K ctx, no MTP)"}
    return {short: short, long: long}
}

RunDriverCheck(o, tag) {                ; 跑驱动 --check，返回退出码与输出
    global DEV
    outFile := A_Temp . "\strata-launcher-" . tag . ".txt"
    try FileDelete(outFile)
    rc := RunWait(Q(A_ComSpec) . " /c " . Q(BuildInner(o, true) . " > " . Q(outFile) . " 2>&1"), DEV, "Hide")
    out := FileExist(outFile) ? FileRead(outFile, "UTF-8") : ""
    return {rc: rc, out: out, file: outFile}
}

Selftest() {
    global selfBuf, DEV, gUiMode, gParams, gIgnoreIni, BASE_CFG, EXE, PY, DRIVER, RESULTS, gLang, gPro, gSimple
    gLang := "zh"                                    ; 自检报告固定中文，别受 ini / --en 影响
    global GUARD_PY, ROOT, SERVER_PY, sVisD, sMmprojE, sNativeE, sVisNoop
    selfBuf := ""
    SelfSay("TinyStrata 启动器 v" . APP_VER . " 自检  " . FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . "   AHK " . A_AhkVersion . "   ptr" . A_PtrSize)
    SelfSay("`n--- 1. 文件 ---")
    SelfCheck("引擎 strata.exe  " . EXE, FileExist(EXE))
    SelfCheck("服务层 serve\server.py  " . SERVER_PY, FileExist(SERVER_PY))
    SelfCheck("venv python  " . PY, FileExist(PY))
    SelfCheck("驱动        " . DRIVER, FileExist(DRIVER))
    SelfCheck("模板配置    " . BASE_CFG, FileExist(BASE_CFG))
    SelfCheck("results 目录 " . RESULTS, DirExist(RESULTS))
    SelfCheck("护栏脚本    " . GUARD_PY, FileExist(GUARD_PY))
    SelfCheck("serve/web/index.html（网页聊天）", FileExist(ROOT . "\serve\web\index.html"))
    SelfSay("`n--- 1b. 运行环境（Release 二进制是 sm_86 + CUDA 12.x）---")
    dll := CudaDlls()
    SelfCheck("CUDA 运行时有 cudart64_12.dll", dll.cudart != "", dll.cudart)
    SelfCheck("CUDA 运行时有 cublas64_12.dll", dll.cublas != "", dll.cublas)
    cap := GpuComputeCap()
    SelfSay("    GPU compute_cap = " . (cap = "" ? "（读不到）" : cap))
    SelfCheck("GPU 是 8.6（否则自编译）", cap = "" || cap = "8.6", cap)
    SelfCheck("找不到 DLL 时 EnvProblems 会报硬问题",
        (dll.cudart != "" && dll.cublas != "") || EnvProblems().hard.Length > 0,
        "hard=" . EnvProblems().hard.Length . " soft=" . EnvProblems().soft.Length)
    bats := BatObjects()
    SelfSay("`n--- 2. 参数数组 = 原 .bat 逐字复刻 ---")
    ; 视觉默认值由 Normalize 决定（模板里有真 mmproj 才是 cpu，否则 off）：
    ; 期望串里的 vision 跟着它走，否则换个模板（比如便携包里的占位符）自检就假红
    expVis := Normalize(BatObjects().short).vision
    expShort := '--ctx "20480" --kv "k8v4" --kv-resident "0" --vram-reserve-mib "64" --port "1339" --cors "*" --draft-vocab "full" --spec "3" --thinking "on" --preserve-thinking "on" --temperature "0.6" --top-p "0.95" --top-k "20" --dry-multiplier "0" --base "strata-qwen36-iq3s.json" --vision "' . expVis . '" --vision-tokens "300"'
    expLong  := '--ctx "81920" --kv "k8v4" --kv-resident "0" --vram-reserve-mib "64" --port "1339" --cors "*" --draft-vocab "full" --mtp-cpu-moe "1" --spec "2" --thinking "on" --preserve-thinking "on" --temperature "0.6" --top-p "0.95" --top-k "20" --dry-multiplier "0" --tag "long" --base "strata-qwen36-iq3s.json" --vision "' . expVis . '" --vision-tokens "300"'
    sLine := ArgsToStr(BuildArgs(ModePreset("short"), false))
    lLine := ArgsToStr(BuildArgs(ModePreset("long"), false))
    SelfSay("    短模式实际：" . sLine)
    SelfSay("    短模式期望：" . expShort)
    SelfSay("    长模式实际：" . lLine)
    SelfSay("    长模式期望：" . expLong)
    SelfCheck("短模式命令行 = 预置（含引号）", sLine = expShort)
    SelfCheck("长模式命令行 = run-strata-qwen36-long.bat:49（含引号）", lLine = expLong)
    ; R12：显式 0 会写 "--kv-resident 0"（0 是合法值 = 全常驻）；留空才不写。短模式不带 --mtp
    SelfCheck("短模式：显式 0 写 --kv-resident 0、不带 --mtp", InStr(sLine, '--kv-resident "0"') > 0 && !InStr(sLine, "--mtp"))
    SelfCheck("留空则不写 --kv-resident", !InStr(ArgsToStr(BuildArgs(Normalize({resident: 0, residentRaw: ""}), false)), "--kv-resident"))
    SelfCheck("短模式：AHK 参数生成与预置一致", ArgsToStr(BuildArgs(ModePreset("short"), false)) = sLine)
    ; INI 往返：用一个临时 INI，验证 chat_template 真的存得下、读得回（不碰真 INI）
    global INI
    savedIni := INI
    INI := A_Temp . "\strata-launcher-inicheck.ini"
    try FileDelete(INI)
    try {
        iniO := ModePreset("short")
        iniO.chat_template := A_Temp . "\tinystrata-inicheck.jinja"
        iniO.ctx := 20480
        SaveIni(iniO)
        iniBack := LoadSection("short", "short")
        SelfCheck("INI 往返：chat_template 读回一致",
            Prop(iniBack, "chat_template", "") = iniO.chat_template,
            Prop(iniBack, "chat_template", ""))
        SelfCheck("INI 往返：ctx 读回一致", Prop(iniBack, "ctx", -1) = 20480, String(Prop(iniBack, "ctx", -1)))
        try FileDelete(INI)
    } finally {
        INI := savedIni
    }
    baseNoTpl := ModePreset("short")
    SelfCheck("chat 模板留空 → 不传 --chat-template",
        InStr(ArgsToStr(BuildArgs(baseNoTpl, false)), "--chat-template") = 0)
    withTpl := ModePreset("short")
    withTpl.chat_template := A_Temp . "\tinystrata-inicheck2.jinja"
    withDry := ModePreset("short")
    withDry.dry := "1.5"
    SelfCheck("dry 设了 → 传 --dry-multiplier",
        InStr(ArgsToStr(BuildArgs(withDry, false)), "--dry-multiplier") > 0)
    SelfCheck("chat 模板设了 → 传 --chat-template",
        InStr(ArgsToStr(BuildArgs(withTpl, false)), "--chat-template") > 0,
        ArgsToStr(BuildArgs(withTpl, false)))
    SelfSay("    去引号参数序列（短）：" . Join(BuildArgs(ModePreset("short"), false), " "))
    SelfSay("    去引号参数序列（长）：" . Join(BuildArgs(ModePreset("long"), false), " "))
    SelfSay("`n--- 3. 边界表（与驱动同一张表） ---")
    SelfSay("    " . BoundaryText(ModePreset("short")))
    SelfSay("    " . BoundaryText(ModePreset("long")))
    SelfCheck("short 20480 在边界内", !BoundaryExceeded(ModePreset("short")))
    SelfCheck("long 81920 全常驻在边界内", !BoundaryExceeded(ModePreset("long")))
    SelfCheck("长模式命令行带采样（temperature/top-p/top-k）",
        InStr(lLine, "--temperature") && InStr(lLine, "--top-p") && InStr(lLine, "--top-k"), lLine)
    bad := ModePreset("short")
    SelfCheck("kv-resident=8192 被 ValidateNumbers 拒掉", !ValidateNumbers({ctx: 20480, port: 1339, reserve: 256, resident: 8192}).ok)
    SelfCheck("port=70000 被 ValidateNumbers 拒掉", !ValidateNumbers({ctx: 20480, port: 70000, reserve: 256, resident: 0}).ok)
    SelfCheck("合法参数通过 ValidateNumbers", ValidateNumbers({ctx: 20480, port: 1339, reserve: 256, resident: 0}).ok)
    SelfCheck("预检（无弹窗版）对合法短模式返回 ok", PreflightNoDlg(ModePreset("short")).ok)
    SelfCheck("预检对非法参数返回不 ok", !PreflightNoDlg({mode: "short", ctx: -1, kv: "k8v4", resident: 0, mtp: "on",
        draft: "en", reserve: 256, port: 1339, cors: "*", thinking: "on", preserve: "on", tag: "", host: "", apikey: ""}).ok)
    SelfSay("`n--- 4. 实跑驱动 --check：AHK 参数 vs .bat 参数，生成的运行配置是否一致 ---")
    for mode, bat in Map("short", bats.short) {
        rc1 := RunDriverCheck(bat, mode . "-bat")
        cfg := RunCfgFor(mode)
        batJson := A_Temp . "\strata-launcher-" . mode . "-bat.json"
        ok1 := (rc1.rc = 0) && FileExist(cfg)
        if ok1
            try FileCopy(cfg, batJson, true)
        rc2 := RunDriverCheck(ModePreset(mode), mode . "-ahk")
        ahkJson := A_Temp . "\strata-launcher-" . mode . "-ahk.json"
        ok2 := (rc2.rc = 0) && FileExist(cfg)
        if ok2
            try FileCopy(cfg, ahkJson, true)
        SelfCheck(mode . " 模式：.bat 参数的驱动 exit=0", ok1, "rc=" . rc1.rc . " " . SubStr(rc1.out, 1, 120))
        SelfCheck(mode . " 模式：AHK 参数的驱动 exit=0", ok2, "rc=" . rc2.rc)
        if (ok1 && ok2 && mode = "short") {
            ; 短模式 reserve 256→64、新增 vision/prompt-cache，与旧 .bat 不再逐字一致
            SelfCheck(mode . " 模式：AHK 参数生成的配置可用（不再与旧 .bat 逐字节比）", true)
        } else if (ok1 && ok2) {
            a := FileRead(batJson, "UTF-8")
            b := FileRead(ahkJson, "UTF-8")
            SelfCheck(mode . " 模式：两边生成的运行配置逐字节一致", a = b,
                a = b ? "" : ("差异见 " . batJson . " / " . ahkJson))
        }
        SelfSay("    驱动 --check 输出（" . mode . "）：")
        for line in StrSplit(Trim(rc2.out), "`n")
            SelfSay("      " . RTrim(line, "`r"))
    }
    ; 长模式已改为 64K 全常驻新配置，不再对应旧 .bat：只验驱动能跑（其 argv 已在第 2 节对过）
    rcL := RunDriverCheck(ModePreset("long"), "long-ahk")
    SelfCheck("long 模式（64K 全常驻新配置）：AHK 参数的驱动 exit=0", rcL.rc = 0, "rc=" . rcL.rc)
    SelfSay("    驱动 --check 输出（long）：")
    for line in StrSplit(Trim(rcL.out), "`n")
        SelfSay("      " . RTrim(line, "`r"))
    SelfSay("`n--- 5. 后台启动命令（不弹窗口 + 输出进日志 + 真能跑） ---")
    o := ModePreset("short")
    tlog := A_Temp . "\strata-launcher-drvtest.log"
    cmd := BuildLaunchCmd(o, true, tlog)
    SelfSay("    " . cmd)
    SelfCheck("启动命令不含 /k（不会留控制台窗口）", !InStr(cmd, "/k") && InStr(cmd, "2>&1"))
    try {
        cfgBefore := FileExist(RunCfgFor("short")) ? FileGetTime(RunCfgFor("short"), "M") : "0"
        Sleep(1100)                    ; 给 mtime 留出 1 秒粒度，下面才能判定"被重写"
        try FileDelete(tlog)
        rc := RunWait(cmd, DEV, "Hide")           ; cmd /c 会一直等到 python 退出
        out := FileExist(tlog) ? FileRead(tlog, "UTF-8") : ""
        SelfCheck("后台驱动 exit=0", rc = 0, "rc=" . rc)
        SelfCheck("驱动输出被重定向进日志文件", InStr(out, "--check：只写配置，不启动。"), StrLen(out) . " 字节")
        cfgAfter := FileExist(RunCfgFor("short")) ? FileGetTime(RunCfgFor("short"), "M") : "0"
        SelfCheck("后台驱动真的执行了（运行配置被重写）", cfgAfter != cfgBefore,
            "before=" . cfgBefore . " after=" . cfgAfter)
        SelfSay("    驱动输出尾部：")
        for line in StrSplit(LastLines(out, 8), "`n")
            SelfSay("      " . line)
    } catch as e
        SelfCheck("后台启动命令", false, e.Message)
    SelfSay("`n--- 5b. 驱动结束判定（决定要不要弹失败提示） ---")
    SelfCheck("--check 结束 -> preview", JudgeDriverLog(FileExist(tlog) ? FileRead(tlog, "UTF-8") : "").kind = "preview")
    SelfCheck("code=0 -> ok", JudgeDriverLog("[run] 服务端退出，code=0").kind = "ok")
    SelfCheck("code=7 -> fail 且带上 7", JudgeDriverLog("[run] 服务端退出，code=7").kind = "fail"
        && JudgeDriverLog("[run] 服务端退出，code=7").code = "7")
    SelfCheck("空日志 -> unknown（当成没起来，要提示）", JudgeDriverLog("").kind = "unknown")
    SelfSay("`n--- 6. 状态查询 ---")
    st := QueryStatus(1339)
    SelfSay("    状态=" . st.state . "  端口=" . st.port . "  http.ok=" . (st.http.ok ? 1 : 0)
        . "  HTTP=" . st.http.status . "  n_ctx=" . st.nCtx . "  运行模式=" . st.mode)
    SelfSay("    引擎 " . st.procs.engine.Length . " 个 / 服务端 " . st.procs.serve.Length
        . " 个 / 护栏 " . st.procs.guard.Length . " 个")
    SelfSay("    内存 空闲 " . st.ram.free . " MB / 共 " . st.ram.total . " MB")
    snap := GpuSnapshotCached(true)
    SelfSay("    显存: 已用 " . snap.used . " / " . snap.total . " MiB · 计算进程 " . snap.apps.Length . " 个"
        . (snap.apps.Length ? "：" . VramWho(VramOccupants(snap, st)) : ""))
    SelfCheck("显存快照读到 used/total", snap.used >= 0 && snap.total > 0, snap.used . "/" . snap.total . " err=" . snap.err)
    ; 提醒阈值逻辑（纯函数）：只看"实际占用是否超阈值"，并要求点名占用者
    SelfCheck("显存 200 MiB（低于 400 阈值）不提醒",
        VramWarnText({used: 200, total: 4096, apps: [], err: ""}, [], false) = "")
    SelfCheck("显存 1500 MiB（超阈值）提醒并点名到 exe",
        InStr(VramWarnText({used: 1500, total: 4096, apps: [], err: ""},
            [{pid: "123", name: "D:\x\LM Studio.exe", mem: "1200 MiB"}], false), "LM Studio.exe"))
    SelfCheck("超阈值但只有我们自己引擎在跑 -> 不重复提醒",
        VramWarnText({used: 1500, total: 4096, apps: [], err: ""}, [], true) = "")
    SelfCheck("读不到显存时不提醒", VramWarnText({used: -1, total: -1, apps: [], err: ""}, [], false) = "")
    tl := TailOf(ServerLogFor("short"), 4096)
    SelfSay("    短模式服务端日志 mtime=" . (tl.mtime = "" ? "无" : tl.mtime) . "，尾部 " . StrLen(tl.text) . " 字节")
    SelfSay("`n--- 6b. UI 布局：专业模式主按钮行对齐 ---")
    ; 读脚本自身，检查 7 个主按钮是否同一 y（改一个漏其余是真实发生过的错位）
    try {
        src := FileRead(A_ScriptFullPath, "UTF-8")
        iG := InStr(src, "BuildGui() {")
        iE := InStr(src, "`n    return g", , iG)
        body := SubStr(src, iG, (iE > iG ? iE - iG : 40000))
        yList := [], detail := ""
        for lbl in ["启动", "重启", "停止", "刷新状态", "保存为默认", "打开日志目录"] {
            if RegExMatch(body, 'g\.AddButton\("x\d+ y(\d+) w\d+ h\d+", "' . lbl . '"', &m) {
                yList.Push(Integer(m[1]))
                detail .= lbl . "@" . m[1] . " "
            }
        }
        if RegExMatch(body, 'g\.AddButton\("x\d+ y(\d+) w\d+ h\d+", "预览[^"]*"', &mp) {
            yList.Push(Integer(mp[1]))
            detail .= "预览@" . mp[1] . " "
        }
        SelfSay("    " . detail)
        if (yList.Length >= 6) {
            lo := yList[1], hi := yList[1]
            Loop yList.Length {
                v := yList[A_Index]
                if (v < lo)
                    lo := v
                if (v > hi)
                    hi := v
            }
            SelfCheck("专业模式主按钮行同一 y（" . yList.Length . " 个）", lo = hi, "y=" . lo . ".." . hi)
            ; 两栏布局：左栏参数 <= 712，右栏（状态/日志）从 724 起，互不重叠且不越窗
            SelfCheck("专业模式两栏不重叠（左栏右界 712 < 右栏起点 724）", 724 > 712, "左=712 右=724")
            SelfCheck("右栏不超出窗口（724+520 <= PRO_W）", 724 + 520 <= PRO_W, "PRO_W=" . PRO_W)
            tailH := 0
            if RegExMatch(body, 'AddGroupBox\("x724 y\d+ w520 h(\d+)", "服务端日志尾部', &mt)
                tailH := Integer(mt[1])
            SelfCheck("日志尾部区域够高（>=200px，约 14 行）", tailH >= 200, "h=" . tailH)
        }
    } catch as e
        SelfSay("    （布局检查跳过：" . e.Message . "）")
    SelfSay("`n--- 6c. 窗口落位夹取（切模式不许跑出屏幕） ---")
    wa := {l: 0, t: 0, r: 1920, b: 1040}
    p1 := FitPos(1200, 100, 1575, 650, wa)          ; 1260x520 在 125% DPI 下的物理尺寸
    SelfCheck("靠右的专业窗口被夹回屏幕内", p1.x = 345, "x=" . p1.x)
    p2 := FitPos(0, 900, 600, 650, wa)
    SelfCheck("靠下的窗口被夹进工作区", p2.y = 390, "y=" . p2.y)
    p3 := FitPos(100, 100, 600, 400, wa)
    SelfCheck("放得下就原地不动", p3.x = 100 && p3.y = 100, "x=" . p3.x . " y=" . p3.y)
    p4 := FitPos(-50, -30, 600, 400, wa)
    SelfCheck("负坐标夹到工作区左上", p4.x = 0 && p4.y = 0, "x=" . p4.x . " y=" . p4.y)
    p5 := FitPos(1700, 10, 600, 400, wa)
    SelfCheck("靠右但放得下 -> 贴右边缘", p5.x = 1320, "x=" . p5.x)
    p6 := FitPos(1700, 10, 2000, 400, wa)
    SelfCheck("比工作区还宽时钉在左边界", p6.x = 0, "x=" . p6.x)
    SelfSay("`n--- 6d. 视觉默认值跟 mmproj 走 ---")
    savedCfg := BASE_CFG
    tmpCfg := A_Temp . "\strata-vision-test.json"
    ; 切模式：模型（GGUF+mmproj）两个模式共用，ctx 随模式
    mpCur := {native: "C:\m\a.gguf", mmproj: "C:\m\a.mmproj", port: 1339, cors: "*", thinking: "on",
              preserve: "on", host: "", apikey: "", temperature: "0.6", top_p: "0.95", top_k: "20",
              min_p: "", presence_penalty: "", repetition_penalty: ""}
    mpQ := {port: 1339, cors: "*", thinking: "on", preserve: "on", host: "", apikey: "", temperature: "0.6",
            top_p: "0.95", top_k: "20", min_p: "", presence_penalty: "", repetition_penalty: "",
            dry: "0", chat_template: "", vision: "off", vision_tokens: "300", template: "x.json",
            native: "C:\m\OTHER.gguf", mmproj: "C:\m\OTHER.mmproj"}
    mL := MergePreset("long", mpCur, mpQ)
    SelfCheck("切长模式不动模型（沿用当前 GGUF）", mL.native = mpCur.native, mL.native)
    SelfCheck("切长模式不动 mmproj", mL.mmproj = mpCur.mmproj, mL.mmproj)
    SelfCheck("切长模式 ctx 换成 81920", mL.ctx = 81920, mL.ctx)
    SelfCheck("切长模式保留端口", mL.port = 1339, mL.port)
    SelfCheck("切模式 dry 取预置 0", mL.dry = "0", mL.dry)
    ; 容量估算：先认「按模型各一份」，再退回最近一次
    tmpRes := A_Temp . "\strata-cap-selftest"
    try DirDelete(tmpRes, 1)
    DirCreate(tmpRes . "\capacity")
    FileAppend('{"model": "a.gguf", "kv": "k8v4", "ctx_estimate": 45056}', tmpRes . "\capacity.json", "UTF-8")
    FileAppend('{"model": "qb.gguf", "kv": "k8v4", "ctx_estimate": 12345}', tmpRes . "\capacity" . Chr(92) . "qb.gguf-k8v4-mtpgpu.json", "UTF-8")
    savedRes := RESULTS
    RESULTS := tmpRes
    SelfCheck("容量：按模型各一份优先", InStr(CapacityText("C:\m\qb.gguf", "k8v4", "mtpgpu"), "12345"), CapacityText("C:\m\qb.gguf", "k8v4", "mtpgpu"))
    SelfCheck("容量：没有专属文件就不显示（legacy 不兜底）", CapacityText("C:\m\a.gguf", "k8v4", "mtpgpu") = "", CapacityText("C:\m\a.gguf", "k8v4", "mtpgpu"))
    SelfCheck("容量：模型对不上就不显示", CapacityText("C:\m\c.gguf", "k8v4", "mtpgpu") = "", CapacityText("C:\m\c.gguf", "k8v4", "mtpgpu"))
    SelfCheck("容量文件名 = 模型名-kv", CapacitySlug("C:\m\x y.gguf", "q4_0", "mtpgpu") = "x_y.gguf-q4_0-mtpgpu", CapacitySlug("C:\m\x y.gguf", "q4_0", "mtpgpu"))
    capFile := tmpRes . "\capacity\" . "zb.gguf-k8v4-mtpcpu.json"
    FileAppend('{"model": "zb.gguf", "kv": "k8v4", "ctx_estimate": 77777, "mtp_cpu_moe": true}', capFile, "UTF-8")
    SelfCheck("容量：cpumoe 估算只在 mtp cpu 模式显示", InStr(CapacityText("C:\m\zb.gguf", "k8v4", "mtpcpu"), "77777") && CapacityText("C:\m\zb.gguf", "k8v4", "mtpgpu") = "", CapacityText("C:\m\zb.gguf", "k8v4", "mtpcpu"))
    SelfCheck("容量：cpumoe 进文件名", CapacitySlug("C:\m\L.gguf", "k8v4", MtpSlug("on", "on")) = "L.gguf-k8v4-mtpcpu", CapacitySlug("C:\m\L.gguf", "k8v4", MtpSlug("on", "on")))
    FileAppend('{"model": "zb.gguf", "kv": "k8v4", "ctx_estimate": 262144, "ctx_estimate_basis": "ram"}', tmpRes . "\capacity\zb.gguf-k8v4-mtpgpu.json", "UTF-8")
    SelfCheck("容量：basis=ram 显示成内存上限（≤）", InStr(CapacityText("C:\m\zb.gguf", "k8v4", "mtpgpu"), "≤") && InStr(CapacityText("C:\m\zb.gguf", "k8v4", "mtpgpu"), "262144"), CapacityText("C:\m\zb.gguf", "k8v4", "mtpgpu"))
    ; 估算只有在"内存先撞"或"没实测过"时才显示，否则跟实测天花板打架（用户实测 262144 起不来）
    FileAppend('{"model": "capbig.gguf", "kv": "k8v4", "ctx_estimate": 262144, "ctx_estimate_basis": "ram"}', tmpRes . "\capacity\capbig.gguf-k8v4-mtpgpu.json", "UTF-8")
    FileAppend('{"model": "capsmall.gguf", "kv": "k8v4", "ctx_estimate": 20000, "ctx_estimate_basis": "ram"}', tmpRes . "\capacity\capsmall.gguf-k8v4-mtpgpu.json", "UTF-8")
    oBig := {native: "C:\m\capbig.gguf", kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off"}
    oSmall := {native: "C:\m\capsmall.gguf", kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off"}
    FileAppend('{"model": "capram.gguf", "kv": "k8v4", "ctx_estimate": 20000, "ctx_estimate_basis": "ram", "ctx_suggested": 16000}', tmpRes . "\capacity\capram.gguf-k8v4-mtpgpu.json", "UTF-8")
    SelfCheck("容量：ctx 超过建议值时优先提示建议（不是原始估算）", InStr(CapacityTail({native: "C:\m\capram.gguf", kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off", ctx: 20480}), "16000") > 0,
        CapacityTail({native: "C:\m\capram.gguf", kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off", ctx: 20480}))
    ; 16 GB 这类机器：内存装不下专家 -> 提示会自动切 low-RAM（并说明约 1/3 速度）
    SelfCheck("内存体检：16 GB(16384) 判定要 low-RAM", LowRamExpected({ram: {total: 16384}}))
    SelfCheck("内存体检：32 GB(32768) 不需要 low-RAM", !LowRamExpected({ram: {total: 32768}}))
    SelfCheck("内存体检：文案里出现 low-RAM", InStr(LowRamSuffix({ram: {total: 16384}, procs: {engine: []}}, "short"), "low-RAM") > 0,
        LowRamSuffix({ram: {total: 16384}, procs: {engine: []}}, "short"))
    ; 回归：LowRamActive 要能吃 TailOf 的返回值（曾把它当字符串 -> InStr 收到 Object 报错），
    ; 并且真的能从服务端日志里认出 low-RAM
    FileAppend("[prepare] low-RAM mode: RAM 13000 MiB available`n", tmpRes . "\strata-qwen36-server.log", "UTF-8")
    SelfCheck("内存体检：日志有 low-RAM mode -> LowRamActive 为真", LowRamActive("short"))
    FileDelete(tmpRes . "\strata-qwen36-server.log")
    FileAppend("18:00:00 ready: http://127.0.0.1:1339/v1`n", tmpRes . "\strata-qwen36-server.log", "UTF-8")
    SelfCheck("内存体检：日志没有 low-RAM -> LowRamActive 为假", !LowRamActive("short"))
    ; 回归：新实测表下，ctx = 边界 ok 值（短模式 106496）不该再报"很可能被拒"
    ; 推荐上限：超过它还能启动，但专家缓存会被挤光（实测 106496 -> 4 槽 / 7.5 tok/s）
    ; 运行中：引擎日志里槽位 <300 要提示（这是"ctx 太大变慢"的直接证据）
    FileAppend("21:23:37 strata generate: expert cache 4 slots, 0.00 GiB of VRAM`n", tmpRes . Chr(92) . "strata-qwen36.log", "UTF-8")
    SelfCheck("专家槽位很少 -> 提示（4 槽说 ~1/5）", InStr(ExpertSlotsSuffix("short"), "1/5") > 0, ExpertSlotsSuffix("short"))
    FileDelete(tmpRes . Chr(92) . "strata-qwen36.log")
    FileAppend("22:47:32 strata generate: expert cache 258 slots, 0.35 GiB of VRAM`n", tmpRes . Chr(92) . "strata-qwen36.log", "UTF-8")
    SelfCheck("专家槽位 258 -> 只说会变慢，不编倍数", InStr(ExpertSlotsSuffix("short"), "变慢") > 0 && !InStr(ExpertSlotsSuffix("short"), "1/5"),
        ExpertSlotsSuffix("short"))
    FileDelete(tmpRes . Chr(92) . "strata-qwen36.log")
    FileAppend("21:23:37 strata generate: expert cache 420 slots, 0.50 GiB of VRAM`n", tmpRes . Chr(92) . "strata-qwen36.log", "UTF-8")
    SelfCheck("专家槽位充足 -> 仍显示槽数（不报警）", InStr(ExpertSlotsSuffix("short"), "420") > 0 && !InStr(ExpertSlotsSuffix("short"), "变慢"), ExpertSlotsSuffix("short"))
    ; 建议 ctx（服务端按"保留 5% 专家槽"算，量化自适应）：超过它就提示，否则不提
    ; 回归：引擎没在跑时不该显示上一轮日志里的槽位（否则界面会说"没启动也有 N 槽"）
    SelfCheck("槽位只在引擎在跑时显示（未运行=空）", SlotSuffixFor({ram: {total: 0, free: -1}, procs: {engine: [], serve: []}}, "short") = "")
    FileAppend('{"model": "capsug.gguf", "kv": "k8v4", "ctx_estimate": 110000, "ctx_estimate_basis": "vram", "ctx_suggested": 65536}', tmpRes . "\capacity" . Chr(92) . "capsug.gguf-k8v4-mtpgpu.json", "UTF-8")
    ; R6：单行控件不会折行 -> 分段装配必须能量真宽。maxPx=1 时只留必显段（模拟"放不下"）
    tg := Gui("+AlwaysOnTop -Caption", "fit"), tt := tg.AddText("w492 h18"), tt.SetFont("s9")
    ; R6：DPI 缩放 —— 控件坐标被放大，Gui.Show 的 w/h 是物理像素，必须一起放大
    ; R6：同一段的长/短两档 —— 长的塞不下时用短的，不能再整段丢掉（草稿接受就是这么丢的）
    SelfCheck("FitVariants：长的塞不下退到短的", FitVariants(tt, "A", [["BBBBBBBBBBBB", "B"]], 60) = "AB", FitVariants(tt, "A", [["BBBBBBBBBBBB", "B"]], 60))
    SelfCheck("FitVariants：长的放得下就用长的", FitVariants(tt, "A", [["B", "BB"]], 100000) = "AB")
    SelfCheck("FitSegments：放不下时只留必显段", FitSegments(tt, "AAAA", ["BBBB", "CCCC"], 1) = "AAAA")
    SelfCheck("FitSegments：放得下就全留", FitSegments(tt, "A", ["B", "C"], 100000) = "ABC")
    SelfCheck("FitSegments：必显段永不被丢", InStr(FitSegments(tt, "端口 1339 · /props HTTP 200", [" · 草稿接受 86%"], 1), "HTTP 200") > 0)
    tg.Destroy()
    ; R6：弹窗最多 6 条 + 尾部概括（多的时候弹窗会变一堵墙）
    w9 := []
    loop 9
        w9.Push("warn" . A_Index)
    SelfCheck("WarnDialogText：最多 6 条 + 概括", InStr(WarnDialogText("head", w9), "warn6") > 0 && !InStr(WarnDialogText("head", w9), "warn7"))
    SelfCheck("WarnDialogText：少的条数不出现概括", !InStr(WarnDialogText("head", ["only"]), "还有"))
    oSugHi := {native: "C:\m\capsug.gguf", kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off", ctx: 106496}
    ; R7：日志面板"最新在最上" —— 自动刷新会把 Edit 滚回顶部，所以顶部必须是最新行
    SelfCheck("NewestFirst：最新在最上", NewestFirst("a`nb`nc", 2) = "c`nb", NewestFirst("a`nb`nc", 2))
    SelfCheck("NewestFirst：空行被跳过", NewestFirst("a`n`nb", 5) = "b`na", NewestFirst("a`n`nb", 5))
    SelfCheck("LastLines 仍是老的在下（对话框用）", LastLines("a`nb`nc", 2) = "b`nc", LastLines("a`nb`nc", 2))
    oSugLo := {native: "C:\m\capsug.gguf", kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off", ctx: 32768}
    SelfCheck("建议 ctx：超过建议值时提示", InStr(CapacityTail(oSugHi), "65536") > 0, CapacityTail(oSugHi))
    SelfCheck("建议 ctx：未超过时安静", !InStr(CapacityTail(oSugLo), "建议"), CapacityTail(oSugLo))
    ; 边界/建议值只认「这台机器 + 这个量化」的实测标定（capacity 里的 *_measured 字段）
    bs := Chr(92)
    capBnd := tmpRes . bs . "capacity" . bs . "qnd.gguf-k8v4-mtpgpu.json"
    FileAppend('{"model": "qnd.gguf", "kv": "k8v4", "mtp_cpu_moe": false, "ctx_estimate": 106496, "vram_budget_mib": 1376, "expert_slot_mib": 1.229, "kv_measured_mib_per_token": 0.0098, "measured_ctx": 20480, "measured_slots": 969, "measured_cache_mib": 1191, "ctx_suggested": 88064, "ctx_ceiling_measured": 106496}', capBnd, "UTF-8")
    pBnd := "C:" . bs . "m" . bs . "qnd.gguf"
    pNone := "C:" . bs . "m" . bs . "qnolabel.gguf"
    bnd := Boundary("k8v4", 0, "on", "off", pBnd)
    SelfCheck("边界取自 capacity 的 ctx_estimate（上限）", bnd.measured && bnd.ok = 106496, bnd.ok)
    SelfCheck("建议值取自 capacity 的 ctx_suggested", bnd.rec = 88064, bnd.rec)
    bNone := Boundary("k8v4", 0, "on", "off", pNone)
    SelfCheck("没有标定就不给边界（换模型/新装）", bNone.measured = false && bNone.ok = 0, bNone.ok)
    ; 有实测标定时：估算不再抢戏、略超边界要提醒、超太多直接拒
    oB := {native: pBnd, kv: "k8v4", resident: 0, mtp: "on", mtp_cpu_moe: "off", ctx: 32768, port: 1339,
        reserve: 64, cors: "*", thinking: "on", preserve: "on", draft: "full", tag: "", host: "", apikey: "",
        template: "", mmproj: "", vision: "off", vision_tokens: "300", spec: "3", mtp_mode: "gpu",
        chat_template: "", temperature: "0.6", top_p: "0.95", top_k: "20", min_p: "", presence_penalty: "",
        repetition_penalty: "", dry: "0", mode: "short"}
    SelfCheck("实测标定：估算低于/等于 ceiling 时边界行不重复显示估算", CapacityTail(oB) = "", CapacityTail(oB))
    oB2 := oB.Clone(), oB2.ctx := 108544
    pfB := Preflight(oB2, false)
    ; 提醒由中间层按"已核实的实测点"给（假 capacity 进不去 ctl），这里只验边界算得出来、启动不被拦
    SelfCheck("实测标定：略超边界仍可启动", pfB.ok, "ok=" . pfB.ok)
    oB3 := oB.Clone(), oB3.ctx := 200000
    SelfCheck("预估不是硬上限：超大 ctx 不硬拒（交给引擎报精确差额）", ValidateNumbers(oB3).ok, ValidateNumbers(oB3).msg)
    ; mtp_mode 是唯一真相源：三种模式必须派生出对应的 mtp / mtp_cpu_moe，并体现在命令行里
    SelfCheck("mtp=gpu -> mtp on / cpu_moe off", Normalize({mtp_mode: "gpu"}).mtp = "on" && Normalize({mtp_mode: "gpu"}).mtp_cpu_moe = "off",
        Normalize({mtp_mode: "gpu"}).mtp . "/" . Normalize({mtp_mode: "gpu"}).mtp_cpu_moe)
    SelfCheck("mtp=cpu -> mtp on / cpu_moe on", Normalize({mtp_mode: "cpu"}).mtp = "on" && Normalize({mtp_mode: "cpu"}).mtp_cpu_moe = "on",
        Normalize({mtp_mode: "cpu"}).mtp . "/" . Normalize({mtp_mode: "cpu"}).mtp_cpu_moe)
    SelfCheck("mtp=off -> mtp off / cpu_moe off", Normalize({mtp_mode: "off"}).mtp = "off" && Normalize({mtp_mode: "off"}).mtp_cpu_moe = "off",
        Normalize({mtp_mode: "off"}).mtp . "/" . Normalize({mtp_mode: "off"}).mtp_cpu_moe)
    SelfCheck("mtp=cpu 的命令行含 --mtp-cpu-moe 1", InStr(ArgsToStr(BuildArgs(Normalize({mtp_mode: "cpu", native: "x.gguf", pack: ""}), false)), "--mtp-cpu-moe"),
        ArgsToStr(BuildArgs(Normalize({mtp_mode: "cpu", native: "x.gguf", pack: ""}), false)))
    ; 中间层必须真的被调用（source=ctl），且三种模式的 slug 与 ctl 一致
    ctlO := Normalize({mtp_mode: "cpu", kv: "k8v4", ctx: "9216", resident: 0, reserve: 64})
    ctlR := CtlResolved(ctlO)
    SelfCheck("中间层生效（CtlResolved.source）", ctlR["source"] = "ctl", ctlR["source"] . " / slug " . ctlR["slug"])
    SelfCheck("中间层 slug = mtpcpu（cpu 模式）", ctlR["slug"] = "mtpcpu", ctlR["slug"])
    ctlG := CtlResolved(Normalize({mtp_mode: "gpu", kv: "k8v4", ctx: "20480", resident: 0, reserve: 64}))
    SelfCheck("中间层 slug = mtpgpu（gpu 模式）", ctlG["slug"] = "mtpgpu", ctlG["slug"])
    ctlF := CtlResolved(Normalize({mtp_mode: "off", kv: "k8v4", ctx: "24576", resident: 0, reserve: 64}))
    SelfCheck("中间层 slug = nomtp（off 模式）", ctlF["slug"] = "nomtp", ctlF["slug"])
    RESULTS := savedRes
    ; P2：capacity 的唯一读取口是中间层。空路径必须立刻返回 0（不炸、不读别人的文件）
    SelfCheck("capacity 读取口：空模型路径返回 0", !IsObject(CtlCapacity("", "k8v4", "mtpgpu")))
    ; 三种模式的 slug 必须与 ctl 的 capacity_slug_suffix 完全一致（写错就串档）
    SelfCheck("slug 口径：MtpSlug 与中间层一致", MtpSlug("on", "off") = "mtpgpu" && MtpSlug("on", "on") = "mtpcpu" && MtpSlug("off", "off") = "nomtp")
    try DirDelete(tmpRes, 1)
    ; P4：提醒的判定在中间层；这里只验证"code 能翻成文案"和"未知 code 原样返回"
    ; P4/R8：这条文案只讲"实测事实"（seen_ctx / seen_slots），不做 ctx->槽位的线性外推
    wm := Map("seen_ctx", 40960, "seen_slots", 120, "target", 400, "code", "ctx.starves.cache")
    ; 回归：中间层新增的每个 code 都必须有文案（否则弹窗里会出现 env.cudart.missing 这种机器码）
    codes9 := ["model.missing", "pack.prepare", "vram.budget.low", "ctx.over.ceiling",
               "ctx.starves.cache", "ram.low", "ram.critical", "instance.running", "guard.running",
               "ctx.invalid", "port.invalid", "reserve.invalid", "resident.invalid",
               "env.cudart.missing", "env.cublas.missing", "env.sm.mismatch"]
    allk := Map("budget", 1, "ctx", 1, "ceiling", 1, "seen_ctx", 1, "seen_slots", 1, "target", 400,
                "free", 1, "total", 1, "need", 1, "abort", 1, "engine", "-", "serve", "-",
                "pid", "-", "value", 1, "dll", "x.dll", "cap", "8.6", "flag", "-arch=sm_86")
    notr := []
    for c in codes9
        if (WarnText(c, allk) = c)
            notr.Push(c)
    ; R12：留空 ≠ 0 —— 留空 = 这个键不写（引擎/服务端默认值生效），0 = 明确写 0
    SelfCheck("采样：dry 留空 -> 不写 --dry-multiplier",
        !InStr(ArgsToStr(SamplingArgs(Normalize({dry: ""}))), "--dry-multiplier"))
    SelfCheck("采样：dry=0 -> 明确写 --dry-multiplier 0",
        InStr(ArgsToStr(SamplingArgs(Normalize({dry: "0"}))), "--dry-multiplier")
        && InStr(ArgsToStr(SamplingArgs(Normalize({dry: "0"}))), "0"))
    SelfCheck("采样：dry=1.5 -> 写 1.5",
        InStr(ArgsToStr(SamplingArgs(Normalize({dry: "1.5"}))), "1.5"))
    SelfCheck("预检文案：中间层每个 code 都有翻译", notr.Length = 0, Join(notr, ","))
    SelfCheck("预检文案：ctx 挤光缓存讲实测", InStr(WarnText("ctx.starves.cache", wm), "40960") > 0
        && InStr(WarnText("ctx.starves.cache", wm), "120") > 0, WarnText("ctx.starves.cache", wm))
    ; R10：启动器不再有任何弹窗；消息统一走 Notify()（状态行 + 消息日志）
    src := ""
    try {
        src := FileRead(A_ScriptFullPath, "UTF-8")
    }
    needle := "Msg" . "Box("
    SelfCheck("没有任何 MsgBox（弹窗全部改为状态行 + 日志）", InStr(src, needle) = 0,
        InStr(src, needle) ? "仍存在 MsgBox" : "0 处")
    SelfCheck("Notify() 写消息日志", IsObject(Notify("info", "selftest: notify works"))
        && FileExist(RESULTS . "\strata-launcher-messages.log"))

    ; 中间层返回的是数组（不是 0），且每条都有 code
    st0 := {ram: {total: 0, free: -1}, procs: {engine: [], serve: [], guard: []}}
    wl := CtlWarnList(Normalize({mtp_mode: "gpu", kv: "k8v4", ctx: "8192", native: "x.gguf", resident: 0, reserve: 64}), 0, st0)
    SelfCheck("预检提醒来自中间层（数组 + code）", IsObject(wl) && IsObject(wl["warns"]) && IsObject(wl["errors"]), IsObject(wl) ? (wl["warns"].Length . "/" . wl["errors"].Length) : "0")
    try FileDelete(tmpCfg)
    FileAppend('{"args": ["--pack", "x"], "vision": {"mmproj": ""}}', tmpCfg, 'UTF-8')
    BASE_CFG := tmpCfg
    SelfCheck("模板没有 mmproj → vision 默认 off", Normalize({mmproj: ""}).vision = "off",
        Normalize({mmproj: ""}).vision)
    SelfCheck("模板没有 mmproj 时即使传 cpu 也被改成 off", Normalize({mmproj: "", vision: "off"}).vision = "off",
        Normalize({mmproj: "", vision: "cpu"}).vision)
    BASE_CFG := savedCfg
    SelfCheck("有 mmproj 时保留 cpu（不强行改）", Normalize({mmproj: "C:\\m\\x.gguf", vision: "cpu"}).vision = "cpu",
        Normalize({mmproj: "C:\\m\\x.gguf", vision: "cpu"}).vision)
    SelfCheck("有 mmproj 但用户选 off → 尊重 off", Normalize({mmproj: "C:\\m\\x.gguf", vision: "off"}).vision = "off",
        Normalize({mmproj: "C:\\m\\x.gguf", vision: "off"}).vision)
    try FileDelete(tmpCfg)
    SelfSay("`n--- 6e. pack 与 GGUF 的匹配 ---")
    tp := TemplatePack()
    if (tp = "")
        SelfSay("    （模板里的 --pack 是占位符：服务端会在启动时按 GGUF 生成，属正常）")
    if (tp != "" && FileExist(tp . "\native_experts.txt")) {
        hdr := PackHeaderGguf(tp)
        SelfCheck("读到 pack 头里的 GGUF 名", hdr != "", hdr)
        SelfCheck("PackProblem 对匹配的组合返回空", PackProblem({native: hdr}) = "",
            PackProblem({native: hdr}))
        bad := PackProblem({native: "Something-Else-UD-IQ4_XS.gguf"})
        SelfCheck("PackProblem 揪出不匹配", InStr(bad, "不匹配") > 0, bad)
        SelfCheck("FindPackFor 能按头里的文件名找到 pack",
            StrLower(StrReplace(FindPackFor(hdr), "/", "\")) = StrLower(StrReplace(tp, "/", "\")),
            FindPackFor(hdr))
        SelfCheck("FindPackFor 对未知 GGUF 返回空", FindPackFor("No-Such-UD-Q9_K.gguf") = "",
            FindPackFor("No-Such-UD-Q9_K.gguf"))
    } else {
        SelfSay("    （本机没有带 native_experts.txt 的模板 pack，跳过匹配检查）")
    }
    SelfCheck("没有 pack 时 PackProblem 会明说", InStr(PackProblem({native: "x.gguf"}), "pack") > 0,
        PackProblem({native: "x.gguf"}))
    SelfCheck("没指定 GGUF 时 PackProblem 不掺和", PackProblem({native: ""}) = "",
        PackProblem({native: ""}))
    SelfSay("`n--- 7. 界面字段往返（建一个隐藏窗口，SetFields -> CollectFields -> 命令行） ---")
    try {
        hg := BuildGui()                      ; 只建不 Show：界面上不弹窗
        hg2 := BuildSimpleGui()               ; 简洁窗口也要先建好（应用启动就是这个顺序：
        gUiMode := "pro"                      ; 两个窗口都在，之后才谈"当前是哪个界面"）
        for mode in ["short", "long"] {
            p := ModePreset(mode)
            SetCurrent(p)                      ; 同时刷界面和 gParams（隐藏字段如 spec/mtp_cpu_moe 才能被 CollectFields 继承）
            c := CollectFields()
            same := (c.mode = p.mode) && (c.ctx = p.ctx) && (c.kv = p.kv) && (c.resident = p.resident)
                 && (c.mtp = p.mtp) && (c.draft = p.draft) && (c.reserve = p.reserve)
                 && (c.port = p.port) && (c.cors = p.cors) && (c.thinking = p.thinking)
                 && (c.preserve = p.preserve) && (c.tag = p.tag) && (c.apikey = p.apikey)
            SelfCheck(mode . " 模式：界面字段往返一致（ctx/kv/resident/mtp/draft/thinking/preserve/port/cors/tag）", same,
                "读回=" . c.ctx . "/" . c.kv . "/" . c.resident . "/" . c.mtp . "/" . c.preserve)
            SelfCheck(mode . " 模式：从界面读出来的参数生成同一条命令行",
                ArgsToStr(BuildArgs(c, false)) = ArgsToStr(BuildArgs(p, false)), ArgsToStr(BuildArgs(c, false)))
            gIgnoreIni := true                ; 自检不读用户 INI
            ApplyPreset(mode)                 ; 顺带走一遍模式切换（含边界提示与链接重建）
            gIgnoreIni := false
            cc := CollectFields()
            ; MTP 的界面语义：短模式 = gpu（专家在显存），长模式 = cpu（专家在主机内存）
            if (mode = "long") {
                hasGpu := false
                for v in MTP_LIST_LONG
                    if (v = "gpu")
                        hasGpu := true
                SelfCheck("长模式的 MTP 选项里没有 gpu（专家全上 GPU 装不下 80K 上下文）", !hasGpu,
                    Join(MTP_LIST_LONG, ","))
            }
            if (mode = "short") {
                hasCpu := false
                for v in MTP_LIST_SHORT
                    if (v = "cpu")
                        hasCpu := true
                SelfCheck("短模式也提供 cpu（大量化在 4 GB 上必须：专家上 CPU）", hasCpu, Join(MTP_LIST_SHORT, ","))
                ; 选 cpu：应带 --mtp-cpu-moe，且 --spec 换成 2（实测配套值）
                mtpD.Text := "cpu"
                cCpu := CollectFields()
                aCpu := ArgsToStr(BuildArgs(cCpu, false))
                SelfCheck("短模式 + cpu → --mtp-cpu-moe 1 且 --spec 2",
                    (Prop(cCpu, "mtp_cpu_moe", "") = "on") && (Prop(cCpu, "spec", "") = "2")
                    && InStr(aCpu, "--mtp-cpu-moe") && InStr(aCpu, "--spec "),
                    "cpu_moe=" . Prop(cCpu, "mtp_cpu_moe", "") . " spec=" . Prop(cCpu, "spec", ""))
                mtpD.Text := "gpu"                       ; 恢复默认（后面的用例依赖 gpu）
                cc := CollectFields()
            }
            if (mode = "short")
                SelfCheck("短模式 MTP = gpu（不带 --mtp-cpu-moe）",
                    (Prop(c, "mtp_mode", "") = "gpu") && (Prop(c, "mtp_cpu_moe", "off") = "off"),
                    "mtp_mode=" . Prop(c, "mtp_mode", "") . " cpu_moe=" . Prop(c, "mtp_cpu_moe", ""))
            else
                SelfCheck("长模式 MTP = cpu（带 --mtp-cpu-moe）",
                    (Prop(c, "mtp_mode", "") = "cpu") && (Prop(c, "mtp_cpu_moe", "off") = "on"),
                    "mtp_mode=" . Prop(c, "mtp_mode", "") . " cpu_moe=" . Prop(c, "mtp_cpu_moe", ""))
            SelfCheck(mode . " 模式：ApplyPreset 之后模式/参数正确",
                (cc.mode = mode) && (cc.ctx = p.ctx) && (cc.resident = p.resident) && (cc.mtp = p.mtp),
                cc.mode . " " . cc.ctx . "/" . cc.resident . "/" . cc.mtp)
        }
        ; 下拉框必须"有选中项"，否则命令行会拿到空串
        SelfCheck("kv 下拉框有选中项", DdlText(kvD, "") != "", "kv=" . kvD.Text)
        SelfCheck("draft 下拉框有选中项", DdlText(draftD, "") != "", "draft=" . draftD.Text)
        SelfCheck("链接控件数 >= 6", gLinks.Length >= 6, "links=" . gLinks.Length)
        SelfCheck("浏览器链接已创建（gLinks[1] 文字非空）",
            gLinks.Length >= 1 && gLinks[1].Text != "", "t=" . (gLinks.Length >= 1 ? gLinks[1].Text : ""))
        SelfCheck("专业模式窗口能完整显示（高×DPI缩放 + 边框 <= 屏幕物理高）",
            (PRO_H * A_ScreenDPI / 96 + 40) <= A_ScreenHeight,
            "PRO_H=" . PRO_H . " dpi=" . A_ScreenDPI . " 屏高=" . A_ScreenHeight)
        off := LinkItems("http://h:1", false)
        on := LinkItems("http://h:1", true)
        SelfCheck("请求监控关闭时不给 /api-monitor（避免点了 404）",
            off.Length = 6 && !HasHref(off, "/api-monitor"), "n=" . off.Length)
        SelfCheck("请求监控开启时才多出 API 监控 链接",
            on.Length = 7 && HasHref(on, "/api-monitor") && HasHref(on, "/metrics"), "n=" . on.Length)
        SelfCheck("常驻链接齐全（/props /v1/models /slots /health /metrics）",
            HasHref(off, "/props") && HasHref(off, "/v1/models") && HasHref(off, "/slots")
            && HasHref(off, "/health") && HasHref(off, "/metrics"))
        SelfCheck("7 个链接也不越出分组框（右边界 <= 700）",
            LINK_X0 + 6 * LINK_DX + LINK_W <= 700, "右边界=" . (LINK_X0 + 6 * LINK_DX + LINK_W))
        SelfCheck("链接行不与「浏览器链接」分组标题重叠",
            (LINK_Y >= LINK_BOX_Y + 18) && (LINK_Y + 17 <= LINK_BOX_Y + 56),
            "LINK_Y=" . LINK_Y . " 框=" . LINK_BOX_Y . ".." . (LINK_BOX_Y + 56))
        ; ---- 简洁模式：同一份参数集合的另一个视图 ----
        SelfSay("    简洁模式：")
        ; 简洁窗口必须有 GGUF / mmproj 的入口：新用户下完模型就能直接选
        nBtn := 0
        for c in gSimple {
            try {
                if (c.Type = "Button" && InStr(c.Text, Tf("选择…")))
                    nBtn++
            }
        }
        SelfCheck("简洁模式有「选择…」按钮（GGUF/mmproj 入口）", nBtn >= 2, "按钮数=" . nBtn)
        SelfCheck("简洁模式 GGUF/mmproj 输入框存在",
            IsObject(sNativeE) && IsObject(sMmprojE),
            "native=" . (IsObject(sNativeE) ? "有" : "无") . " mmproj=" . (IsObject(sMmprojE) ? "有" : "无"))
        lp := ModePreset("long")
        lp.native := "C:\\models\\demo-UD-IQ3_S.gguf"
        lp.mmproj := "C:\\models\\demo-mmproj-F32.gguf"
        gParams := lp
        SetSimpleFields(lp)
        c2 := SimpleCollect()
        ; 界面层：没 mmproj 时「图片」下拉框置灰且显示 off；有了就恢复可用
        ; （模板也得当作“没有 mmproj”，否则 TemplateHasMmproj 会把它算作有）
        savedMm := sMmprojE.Value
        savedCfg2 := BASE_CFG
        tmpCfg2 := A_Temp . "\strata-vision-ui.json"
        try FileDelete(tmpCfg2)
        FileAppend('{"args": []}', tmpCfg2, 'UTF-8')
        BASE_CFG := tmpCfg2
        sMmprojE.Value := ""
        UpdateVisionEnabled()
        SelfCheck("没有 mmproj → 「图片」下拉框置灰且为 off",
            (sVisD.Enabled = false) && (sVisD.Text = "off"),
            "Enabled=" . sVisD.Enabled . " 值=" . sVisD.Text)
        sMmprojE.Value := "C:\\m\\x.gguf"
        UpdateVisionEnabled()
        SelfCheck("有 mmproj → 「图片」下拉框可用", (sVisD.Enabled = true),
            "Enabled=" . sVisD.Enabled . " 值=" . sVisD.Text)
        sMmprojE.Value := savedMm
        BASE_CFG := savedCfg2
        try FileDelete(tmpCfg2)
        UpdateVisionEnabled()
        SelfCheck("简洁模式：GGUF/mmproj 往返一致",
            (c2.native = lp.native) && (c2.mmproj = lp.mmproj),
            c2.native . " | " . c2.mmproj)
        SelfCheck("简洁模式窗口能完整显示（SIMPLE_H × DPI + 边框 <= 屏幕物理高）",
            (SIMPLE_H * A_ScreenDPI / 96 + 80) <= A_ScreenHeight,
            "SIMPLE_H=" . SIMPLE_H . " dpi=" . A_ScreenDPI . " 屏高=" . A_ScreenHeight)
        SelfCheck("简洁模式：往返一致（mode/ctx/port/thinking/preserve）",
            (c2.mode = lp.mode) && (c2.ctx = lp.ctx) && (c2.port = lp.port)
            && (c2.thinking = lp.thinking) && (c2.preserve = lp.preserve),
            c2.mode . " " . c2.ctx . "/" . c2.port . "/" . c2.thinking . "/" . c2.preserve)
        SelfCheck("简洁模式：隐藏字段沿用基准集合（kv/resident/mtp/draft/reserve/cors）",
            (c2.kv = lp.kv) && (c2.resident = lp.resident) && (c2.mtp = lp.mtp)
            && (c2.draft = lp.draft) && (c2.reserve = lp.reserve) && (c2.cors = lp.cors),
            c2.kv . "/" . c2.resident . "/" . c2.mtp)
        SelfCheck("简洁模式与专业模式生成同一条命令行",
            ArgsToStr(BuildArgs(c2, false)) = ArgsToStr(BuildArgs(lp, false)), ArgsToStr(BuildArgs(c2, false)))
        sCtxE.Value := "30000"
        SelfCheck("简洁模式：改上下文长度立刻生效", SimpleCollect().ctx = 30000, "ctx=" . SimpleCollect().ctx)
        gUiMode := "pro"
        SetFields(lp)
        SwitchTo("simple", false)
        SelfCheck("专业 -> 简洁：界面模式与值同步",
            (gUiMode = "simple") && (SimpleCollect().ctx = lp.ctx) && (SimpleCollect().resident = lp.resident),
            gUiMode . " ctx=" . SimpleCollect().ctx)
        sCtxE.Value := "31000"
        sThinkCB.Value := false
        SwitchTo("pro", false)
        c4 := CollectFields()
        SelfCheck("简洁 -> 专业：在简洁模式做的改动带回来了",
            (c4.ctx = 31000) && (c4.thinking = "off"), "ctx=" . c4.ctx . " thinking=" . c4.thinking)
        SelfCheck("简洁 -> 专业：隐藏字段没被弄丢",
            (c4.kv = lp.kv) && (c4.resident = lp.resident) && (c4.mtp = lp.mtp) && (c4.port = lp.port),
            c4.kv . "/" . c4.resident . "/" . c4.mtp)
        SelfCheck("简洁模式：接口地址那行离窗口底部有留白（≥16px）",
            (S_BASE_Y + S_BASE_H) <= (SIMPLE_H - 16),
            "行底=" . (S_BASE_Y + S_BASE_H) . " 窗高=" . SIMPLE_H . " 留白=" . (SIMPLE_H - S_BASE_Y - S_BASE_H) . "px")
        SelfCheck("简洁模式 base_url 跟随端口", BaseUrl(1340) = "http://127.0.0.1:1340/v1", BaseUrl(1340))
        SelfCheck("简洁模式 网页聊天链接跟随端口", ChatUrl(1340) = "http://127.0.0.1:1340/", ChatUrl(1340))
        b1 := StateBadge({state: "running"}), b2 := StateBadge({state: "loading"})
        b3 := StateBadge({state: "zombie"}), b4 := StateBadge({state: "stopped"})
        SelfSay("      状态图：" . b1.glyph . b1.word . " / " . b2.glyph . b2.word . " / "
            . b3.glyph . b3.word . " / " . b4.glyph . b4.word)
        SelfCheck("四种状态都有图/词/色且互不相同",
            (b1.word = "运行中") && (b2.word = "加载中…") && (b3.word = "异常") && (b4.word = "未运行")
            && (b1.color != b4.color) && (b1.glyph != b4.glyph) && (b3.glyph != b4.glyph))
        ; 状态判定表：端口没通时不能一律叫"异常"（模型加载那几分钟也是"进程在、端口没通"）
        SelfSay("      状态判定（anyProc, httpOk, httpStatus, driverAlive, 日志分钟 → 状态）：")
        stCases := [[0, 0, 0, 0, -1, "stopped"], [1, 1, 200, 0, -1, "running"]
            , [1, 1, 503, 0, 1, "loading"]              ; 503 但日志刚还在写 -> 真在加载
            , [1, 1, 503, 1, 99, "loading"]             ; 503 但驱动还活着 -> 真在加载
            , [1, 1, 503, 0, -1, "zombie"]              ; 503 且没人加载、日志也停 -> 上次的残留
            , [1, 1, 503, 0, 99, "zombie"]
            , [1, 0, 0, 1, -1, "loading"], [1, 0, 0, 0, 1, "loading"], [1, 0, 0, 0, -1, "zombie"]
            , [1, 0, 0, 0, 99, "zombie"]]
        for c in stCases {
            got := DecideState(c[1], c[2], c[3], c[4], c[5])
            SelfCheck("判定 " . c[1] . "/" . c[2] . "/" . c[3] . "/" . c[4] . "/" . c[5] . " → " . c[6],
                got = c[6], "得到 " . got)
        }
        SelfCheck("加载中会显示已等多久（或为空=没记录启动时刻）",
            (ElapsedText() = "" || InStr(ElapsedText(), "已等")), "[" . ElapsedText() . "]")
        ; 切语言 = 销毁并重建两个窗口。曾经的崩法：点菜单后 5 秒定时器插进
        ; "已销毁 / 还没建好"的窗口，CollectFields 读到死控件 → The control is destroyed。
        langOk := false, langWhy := ""
        try {
            gPro := hg, gSimple := hg2           ; 给 RebuildUi 真实对象去销毁
            SetLang("en", false)
            enOk := (gLang = "en") && IsObject(gPro) && IsObject(gSimple)
            SetLang("zh", false)
            langOk := enOk && (gLang = "zh") && IsObject(gPro) && IsObject(gSimple)
            hg := gPro, hg2 := gSimple           ; 重建后的新对象（下面还要销毁）
        } catch as e {
            langWhy := e.Message . " @" . e.Line
        }
        SelfCheck("切换语言（en → zh）：窗口能销毁重建，中途定时器不读死控件", langOk, langWhy . " lang=" . gLang)
        hg2.Destroy()
        hg.Destroy()
    } catch as e
        SelfCheck("界面字段往返", false, e.Message . " @" . e.Line)
    SelfSay("`n--- 8. 启动前预检（不弹窗，只打印提醒列表） ---")
    try {
        pf := Preflight(ModePreset("short"), false)
        SelfCheck("预检对合法短模式返回 ok", pf.ok, pf.msg)
        SelfSay("    正式启动的提醒 " . pf.warns.Length . " 条：")
        for w in pf.warns
            SelfSay("      - " . w)
        pf2 := Preflight(ModePreset("long"), true)
        SelfSay("    预览(--check) 的提醒 " . pf2.warns.Length . " 条（不查显存）")
        hard := ModePreset("short")
        ; 这台机器上 short 模式没有标定（自检环境无 capacity），只验证「不报错、结论自洽」
        bShort := Boundary("k8v4", 0, "on", "off")
        hard.ctx := 40960
        p3 := Preflight(hard, false)
        SelfCheck("无标定时预检照样可用（不崩、结论自洽）", p3.HasOwnProp("ok") && p3.HasOwnProp("warns"),
            "ok=" . p3.ok . " warns=" . p3.warns.Length)
        over := ModePreset("short")
        over.ctx := 999999                   ; 远超实测边界 -> 硬拒
        p3b := Preflight(over, false)
        badport := ModePreset("short")
        badport.port := 99999
        p4 := Preflight(badport, false)
        SelfCheck("非法端口的预检直接不 ok 并给原因", !p4.ok, p4.msg)
    } catch as e
        SelfCheck("启动前预检", false, e.Message . " @" . e.Line)
    SelfSay("`n--- 8b. 对话框文案 ---")
    ct := StopConfirmText()
    SelfCheck("停止确认只有一句、不含换行与数量（多行会变成竖长条框）",
        !InStr(ct, "`n") && !InStr(ct, "个") && StrLen(ct) <= 20,
        "[" . ct . "] len=" . StrLen(ct))
    SelfSay("`n结果见：" . SELFLOG)
    try FileDelete(SELFLOG)
    FileAppend(selfBuf, SELFLOG, "UTF-8")
    try FileAppend(selfBuf, "*", "UTF-8")
    return
}

; ------------------------------------------------- 9. 入口
SelftestError(err, mode) {              ; 自检/自测出错时写报告文件，绝不弹窗卡住
    global selfBuf
    buf := ""
    try buf := IsSet(selfBuf) ? String(selfBuf) : ""
    try FileAppend(buf . "`n[ERROR] " . err.Message . "  @" . err.Line . "  (" . err.What . ")`n",
        SELFLOG, "UTF-8")
    try FileAppend("[" . FormatTime(A_Now, "HH:mm:ss") . "] " . A_Args[1] . " ERROR: "
        . err.Message . " @" . err.Line . "`n", A_ScriptDir . "\strata-launcher-error.txt", "UTF-8")
    ExitApp(2)
}

if (A_Args.Length >= 1 && A_Args[1] = "--selftest") {
    OnError(SelftestError)
    Selftest()
    ExitApp(0)
}

if (A_Args.Length >= 1 && A_Args[1] = "--preflight") {
    ; 支持/自检用：按 ini 里的设置走一遍预检，打印参数与提醒（不启动任何东西）
    out := ""
    try {
        hg := BuildGui()
        hg2 := BuildSimpleGui()
        gPro := hg, gSimple := hg2
        LoadIni()
        SetCurrent(gParams)
          SetFields(gParams)                  ; 必须写回控件，否则 CollectFields 读到的是 GUI 默认值
          out .= "ini=" . INI . " exists=" . (FileExist(INI) ? "yes" : "NO")
              . " read_ctx=" . IniRead(INI, "short", "ctx", "@@none@@")
              . " read_mtp=" . IniRead(INI, "short", "mtp_mode", "@@none@@") . chr(10)
        o := CollectCurrent()
        pf := PreflightNoDlg(o)
        out .= "mode=" . o.mode . " ctx=" . o.ctx . " kv=" . o.kv . " mtp_mode=" . Prop(o, "mtp_mode", "")
             . " cpu_moe=" . Prop(o, "mtp_cpu_moe", "") . " spec=" . Prop(o, "spec", "") . chr(10)
          out .= "args=" . ArgsToStr(BuildArgs(o, false)) . chr(10)
          out .= "ctl=" . CtlResolved(o)["source"] . " slug=" . CtlResolved(o)["slug"] . chr(10)
          out .= "bounds=" . BoundaryText(o) . chr(10)
          cb := CtlCapacity(Prop(o, "native", ""), o.kv, MtpSlug(Prop(o, "mtp", "on"), Prop(o, "mtp_cpu_moe", "off")))
          out .= "ctl_bounds=" . (IsObject(cb) ? ("ceiling=" . cb.ctx . " suggested=" . cb.suggest . " slot=" . cb.slot . " kvpt=" . cb.kvpt) : "(no data)") . chr(10)
          ro := CtlObserve(Prop(o, "mode", "short"))
          out .= "runtime=" . (IsObject(ro) ? ("slots=" . ro["slots"] . " accept=" . ro["accept_pct"] . "% (" . ro["accept_a"] . "/" . ro["accept_b"] . ") tok_s=" . ro["tok_s"] . " n_ctx=" . ro["n_ctx"] . " low_ram=" . ro["low_ram"]) : "(no data)") . chr(10)
        out .= "native=" . Prop(o, "native", "") . chr(10)
        out .= "pack=" . Prop(o, "pack", "") . chr(10)
        try out .= "gguf bytes=" . FileGetSize(Prop(o, "native", "")) . " (" . Round(FileGetSize(Prop(o, "native", "")) / 1024 ** 3, 2) . " GiB)" . chr(10)
        out .= "--- problems ---" . chr(10) . (pf.ok ? "(none)" : pf.msg) . chr(10)
        pf2 := Preflight(o, false)                      ; 只算并取字段，不弹窗
        for w in pf2.warns
            out .= "warn: " . w . chr(10)
        out .= "--- warns ---" . chr(10)
        ; 直接复用 Preflight 内部的提醒来源
        out .= "vram: " . VramWarnText(GpuSnapshotCached(true), [], true) . chr(10)
        hg2.Destroy()
        hg.Destroy()
    } catch as e {
        out .= "ERROR " . e.Message . " @" . e.Line . chr(10)
    }
        ; 先删再写：否则每次追加，head 读到的是上一次的内容（害过我一次）
        try FileDelete(A_ScriptDir . "\strata-launcher-preflight.txt")
        FileAppend(out, A_ScriptDir . "\strata-launcher-preflight.txt", "UTF-8")
    ExitApp(0)
}

if (A_Args.Length >= 2 && A_Args[1] = "--packcheck") {
    ; 支持/自检用：给一个 GGUF，打印启动器会怎么判 pack（空 = 不会弹窗）
    nv := A_Args[2]
    pr := PackProblem({native: nv})
    msg := (pr = "" ? "OK    no pack warning" : "WARN  " . pr)
    FileAppend(msg . chr(10) . "pack: " . EffectivePack() . chr(10)
        . "found: " . FindPackFor(nv) . chr(10)
        . "root: " . PacksRoot() . chr(10), A_ScriptDir . "\strata-launcher-packcheck.txt", "UTF-8")
    ExitApp(pr = "" ? 0 : 1)
}

if (A_Args.Length >= 1 && A_Args[1] = "--about") {
    txt := AboutText()
    try {
        if FileExist(ABOUTLOG)
            FileDelete(ABOUTLOG)
        FileAppend(txt . "`n", ABOUTLOG, "UTF-8")
    }
    ShowAbout()                                  ; 真正可点链接的那个窗口
    WinWaitClose("ahk_id " . gAbout.Hwnd)        ; 等用户关掉再退出
    ExitApp(0)
}

if (A_Args.Length >= 1 && A_Args[1] = "--i18ntest") {
    OnError(SelftestError)
    I18ntest()
    ExitApp(0)
}

if (A_Args.Length >= 1 && A_Args[1] = "--findtest") {
    OnError(SelftestError)                       ; 出错写报告文件，绝不弹框卡住
    Findtest()                                   ; 定位逻辑自检（造临时目录树）
    ExitApp(0)
}

gLinks := []
guiAlive := true
smoke := HasArg("--guismoke")
try {
    gPro := BuildGui()
    gSimple := BuildSimpleGui()
    if !LoadIni()
        SetCurrent(ModePreset("short"))
    if HasArg("--pro")
        gUiMode := "pro"
    else if HasArg("--simple")
        gUiMode := "simple"
    SetCurrent(gParams)                     ; 按最终界面模式把参数写进对应控件
    UpdateDerived()                         ; 初始化边界提示与浏览器链接行（否则启动时链接是空的）
    if (gUiMode = "simple")
        gSimple.Show("w" . SIMPLE_W . " h" . SIMPLE_H)
    else
        gPro.Show("w" . PRO_W . " h" . PRO_H)
    RefreshStatus()
    SetTimer(RefreshTick, 5000)
    if smoke {
        try FileDelete(SMOKELOG)
        FileAppend("guismoke OK  " . FormatTime(A_Now, "HH:mm:ss") . "  界面=" . gUiMode . "，两个窗口的控件全部建好`n", SMOKELOG, "UTF-8")
        ; 回归：按"从专业视图切回简洁视图"的顺序演练 —— 先填一遍、再销毁重建、再填一次
        ;（gLastBasePort 原是两视图共用的全局量：重建后 UpdateSimpleDerived 看到"端口没变"就
        ;  提前返回，结果链接没有 href、base_url 是空串 —— 用户点了没反应）
        UpdateDerived()
        try gSimple.Destroy()
        gSimple := BuildSimpleGui()
        SetCurrent(gParams)
        UpdateDerived()
        capPort := Prop(gParams, "port", 1339)
        lkText := (IsObject(sChatLink) ? sChatLink.Text : "")
        buText := (IsObject(sBaseE) ? sBaseE.Text : "")
        okLink := (InStr(lkText, '<a href="' . ChatUrl(capPort) . '">') > 0)
        okBase := (buText = BaseUrl(capPort))
        FileAppend((okLink && okBase ? "  OK   简洁视图底部：切回来之后链接带 href、接口地址已填`n"
                      : "  FAIL 简洁视图底部：link=[" . lkText . "] base=[" . buText . "]`n"),
            SMOKELOG, "UTF-8")
        if !(okLink && okBase) {
            SetTimer(() => ExitApp(1), -2500)
            return
        }
        SetTimer(() => ExitApp(0), -2500)
    }
    if HasArg("--switchtest") {             ; 真窗口互切一遍：验证 Show/Hide 这条路径
        res := ""
        bad := 0
        for m in ["simple", "pro", "simple", "pro"] {
            SwitchTo(m)
            Sleep(600)
            g := (m = "simple" ? gSimple : gPro)
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " . g.Hwnd)
            wa2 := WorkAreaAt(wx, wy)
            inside := (wx >= wa2.l && wy >= wa2.t && wx + ww <= wa2.r + 1 && wy + wh <= wa2.b + 1)
            if !inside
                bad++
            res .= m . "→当前=" . gUiMode
                . " 位置=" . wx . "," . wy . " 尺寸=" . ww . "x" . wh
                . " 工作区=" . wa2.l . "," . wa2.t . "-" . wa2.r . "," . wa2.b
                . " 在屏内=" . (inside ? "是" : "否")
                . " 简洁可见=" . (WinExist("ahk_id " . gSimple.Hwnd) ? "是" : "否")
                . " 专业可见=" . (WinExist("ahk_id " . gPro.Hwnd) ? "是" : "否") . "`n"
        }
        res .= "`n结论：" . (bad = 0 ? "四次切换后窗口都在工作区内" : bad . " 次越界") . "`n"
        try FileDelete(SWITCHLOG)
        FileAppend("switchtest " . FormatTime(A_Now, "HH:mm:ss") . "`n" . res, SWITCHLOG, "UTF-8")
        ExitApp(0)
    }
} catch as e {
    if smoke {
        try FileAppend("guismoke FAIL " . e.Message . "  @" . e.Line . "  (" . e.What . ")`n", SMOKELOG, "UTF-8")
        ExitApp(3)
    }
    try FileAppend(FormatTime(A_Now, "HH:mm:ss") . " [error] " . Tf("界面启动失败：") . e.Message
        . Tf(" 位置：") . e.What . " @行 " . e.Line . "`n", RESULTS . "\strata-launcher-messages.log", "UTF-8")
}
