#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================================
;  Strata 启动器（AutoHotkey v2，本机 v2.0.19 实测）
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

global DEV      := "D:\dev"
global ROOT     := DEV . "\strata"
global PY       := ROOT . "\.venv\Scripts\python.exe"
global DRIVER   := DEV . "\tools\strata-run.py"
global BASE_CFG := DEV . "\strata-qwen36-iq3s.json"
global RESULTS  := DEV . "\results"
global GUARD_PY := DEV . "\tools\strata-ram-guard.py"
global INI      := DEV . "\strata-launcher.ini"
global SELFLOG  := DEV . "\strata-launcher-selftest.txt"
global SMOKELOG := DEV . "\strata-launcher-guismoke.txt"
global SWITCHLOG := DEV . "\strata-launcher-switchtest.txt"
global GUARD_LOG := RESULTS . "\strata-ram-guard.log"
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
global gInSetFields := false      ; SetFields 期间抑制 Change 事件（防 mdlD.Text 触发 LoadTemplate 递归）
global gTplCache := []            ; 模型模板列表缓存
global gMtpList := []           ; MTP 下拉框当前的选项（切模式时换）
global gUiMode := "simple"        ; 当前界面："simple"（简洁）| "pro"（专业）
global gParams := {}              ; 最近一次完整的参数集合（简洁模式隐藏字段的取值来源）
global gPro := 0                  ; 专业模式窗口
global gSimple := 0               ; 简洁模式窗口
global gLastBasePort := -1        ; 简洁模式里 base_url / 网页聊天链接上次用的端口
global SIMPLE_W := 460            ; 简洁模式窗口尺寸 + 浏览器那一行的位置（自检会检查它离底部有留白）
global SIMPLE_H := 486
global PRO_W := 1260              ; 专业模式窗口尺寸（左栏参数 704 + 右栏状态/日志 520 + 边距；自检会检查）
global PRO_H := 520              ; 两栏布局：左栏到 508，右栏日志到 512（约 14 行，自动换行）
global S_BASE_Y := 380            ; 「接口地址」那行的复制按钮 y
global S_BASE_H := 26
; 下拉框允许的取值（AHK v2.0.19 里 DropDownList 的 .Value 是"下标"不是文本，
; 所以：设置用 .Text，读取用 .Text；.Value 只在 Radio/CheckBox 上用 0/1）
global KV_LIST := ["k8v4", "q4_0", "int8", "fp16"]
; MTP 选项按模式：短模式 = gpu（专家在显存）/ off；长模式 = cpu（专家在主机内存，省 312 MiB）/ off
global TPL_DIR := "D:\dev\templates"   ; chat 模板默认目录（froggeric 等放这里）
global MTP_LIST_SHORT := ["gpu", "off"]
global MTP_LIST_LONG := ["cpu", "off"]   ; 长模式只有 cpu/off：专家全上 GPU 会装不下（80K 上下文放不下 312 MiB）
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

MtpModeToParams(mode) {
    global MTP_LIST_SHORT, MTP_LIST_LONG
    v := (mode = "long" ? MTP_LIST_LONG : MTP_LIST_SHORT)
    return {on: v[1], off: "off"}
}
global DRAFT_LIST := ["en", "cjk", "cyrillic", "fr"]
global YN_LIST := ["on", "off"]
global VISION_LIST := ["off", "cpu", "gpu"]   ; 图片编码器：off / cpu（不占显存）/ gpu（~1.2GB）

; ------------------------------------------------- 1. 模式预置 + 实测边界
; 短模式 = 原 run-strata-qwen36.bat；长模式 = 原 run-strata-qwen36-long.bat
ModePreset(mode) {
    ; 长模式 = 实测最优：KV 全常驻（不开流式）、reserve 64、MTP 关、preserve-thinking on
    ; ctx 81920 = 本机全常驻实测上限（reserve 64）；配合 pi 的 reserveTokens 16384，
    ; 干活上下文正好落在 65536（模型 64k 召回 ~70% 那一档），既不太差也不至于频繁 auto-compact
    if (mode = "long")
        return {mode: "long", ctx: 81920, kv: "k8v4", resident: 0, mtp: "on",
                draft: "en", reserve: 64, port: 1339, cors: "*", thinking: "on", preserve: "on",
                mtp_cpu_moe: "on", spec: "2", mtp_mode: "cpu", chat_template: "", dry: "1.5",
                tag: "long", host: "", apikey: "",
                temperature: "0.6", top_p: "0.95", top_k: "20",
        min_p: "", presence_penalty: "", repetition_penalty: "",
        vision: "cpu", vision_tokens: "300", template: "strata-qwen36-iq3s.json",
        native: "", mmproj: "",
                title: "Strata LONG - Qwen3.6-35B-A3B UD-IQ3_S (81920 KV / 64K working, all-resident, no MTP)"}
    return {mode: "short", ctx: 20480, kv: "k8v4", resident: 0, mtp: "on",
            draft: "en", reserve: 64, port: 1339, cors: "*", thinking: "on", preserve: "on",
            mtp_cpu_moe: "off", spec: "3", mtp_mode: "gpu", chat_template: "", dry: "1.5",
            tag: "", host: "", apikey: "",
            temperature: "0.6", top_p: "0.95", top_k: "20",
        min_p: "", presence_penalty: "", repetition_penalty: "",
        vision: "cpu", vision_tokens: "300", template: "strata-qwen36-iq3s.json",
        native: "", mmproj: "",
            title: "Strata - Qwen3.6-35B-A3B UD-IQ3_S"}
}

; 补齐字段：任何参数对象进函数前都过这一道，避免 "no property named Xxx" 直接把界面/自检打断
Prop(o, k, d := "") {
    if !IsObject(o)
        return d
    return o.HasOwnProp(k) ? o.%k% : d
}

HasArg(flag) {                          ; 命令行开关（--ontop / --selftest / --guismoke）
    for a in A_Args
        if (a = flag)
            return true
    return false
}

BaseName(p) {                           ; D:\a\b.exe -> b.exe（nvidia-smi 给的是全路径）
    if (p = "")
        return ""
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

; 扫描 DEV 下的模型模板（strata-qwen36-*.json，排除运行配置）
ModelTemplates() {
    global DEV, gTplCache
    if gTplCache.Length > 0
        return gTplCache
    out := []
    Loop Files, DEV . "\strata-qwen36-*.json"
    {
        n := A_LoopFileName
        if (InStr(n, "-run") || InStr(n, "shared-settings"))
            continue
        out.Push(n)
    }
    if (out.Length = 0)
        out.Push("strata-qwen36-iq3s.json")
    gTplCache := out
    return out
}

; 切模板：读该模板的参数套到界面（保留 port/cors/thinking/采样等全局偏好）
LoadTemplate(name) {
    return
}

; 把一个模板 json 解析成参数对象（读 args 里的关键项）
TemplateToParams(path) {
    return ""
}

; 选 GGUF（覆盖 --native；换模型文件时 pack 也要匹配，通常同时换模板）
PickNative() {
    global nativeE
    cur := Trim(nativeE.Value)
    start := (cur != "" && FileExist(cur)) ? cur : ""
    f := FileSelect(1, start, "选 GGUF 模型文件（--native）", "GGUF (*.gguf)")
    if (f = "")
        return
    nativeE.Value := f
    Tip("GGUF: " . BaseName(f))
}

; 选 mmproj（覆盖 vision.mmproj）
PickMmproj() {
    global mmprojE
    cur := Trim(mmprojE.Value)
    start := (cur != "" && FileExist(cur)) ? cur : ""
    f := FileSelect(1, start, "选视觉编码器 mmproj", "GGUF (*.gguf)")
    if (f = "")
        return
    mmprojE.Value := f
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
    n.mtp := Prop(o, "mtp", "on")
    n.draft := Prop(o, "draft", "en")
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
    n.dry := Prop(o, "dry", "")
    n.chat_template := Prop(o, "chat_template", "")
    n.mtp_mode := Prop(o, "mtp_mode", "gpu")
    n.mtp_cpu_moe := Prop(o, "mtp_cpu_moe", "off")
    n.spec := Prop(o, "spec", "")
    n.vision := Prop(o, "vision", "cpu")
    n.vision_tokens := Prop(o, "vision_tokens", "300")
    n.min_p := Prop(o, "min_p", "")
    n.presence_penalty := Prop(o, "presence_penalty", "")
    n.repetition_penalty := Prop(o, "repetition_penalty", "")
    n.title := Prop(o, "title", "Strata")
    return n
}

; 与驱动里的 MEASURED / MEASURED_STREAM 保持同一张表（能启动, 首个被拒）
Boundary(kv, resident, mtp, cpuMoe := "") {
    ; 长模式 = 全常驻 KV + MTP + 专家上 CPU（--mtp-cpu-moe）：81920 实测可启动（2026-10-27）
    ; 短模式 = 全常驻 KV + MTP（专家在显存）：39936 实测可启动
    stream := Map("k8v4/0/on/cpumoe", [81920, 90112],
                  "k8v4/0/on", [39936, 40960],
                  "k8v4/20480/on", [39936, 40960],
                  "q4_0/20480/on", [32768, 40960],
                  "k8v4/32768/off", [147456, 163840],
                  "k8v4/0/off", [81920, 90112])   ; 全常驻 KV + MTP off（已实测：reserve 256 → 65536；reserve 64 → 81920）
    plain  := Map("k8v4", [21504, 22528], "q4_0", [28672, 29696])
    k := kv . "/" . resident . "/" . mtp
    if (cpuMoe = "on")
        k .= "/cpumoe"
    if stream.Has(k)
        return {ok: stream[k][1], no: stream[k][2], key: k, measured: true}
    if (resident = 0 && plain.Has(kv))
        return {ok: plain[kv][1], no: plain[kv][2], key: kv, measured: true}
    return {ok: 0, no: 0, key: k, measured: false}
}

BoundaryExceeded(o) {
    o := Normalize(o)
    b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"))
    return b.measured && o.ctx > b.ok
}

BoundaryText(o) {
    o := Normalize(o)
    b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"))
    mode := (o.mode = "long" ? "长模式" : "短模式")
    if !b.measured
        return mode . " · " . o.kv . " / resident " . o.resident . " / mtp " . o.mtp
            . " 这个组合本机未实测（短模式 k8v4+MTP 到 39936、长模式 k8v4 全常驻到 81920）"
    head := mode . " · 实测边界（" . b.key . "）" . b.ok . " 能启动 / " . b.no . " 被拒  ->  当前 ctx " . o.ctx . "  "
    return o.ctx <= b.ok ? head . "可启动" : head . "超过边界，引擎很可能拒绝"
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
    ; 硬上限：达到「首个被拒值」就拒（引擎必拒，不必等它加载 12 GB 才报错）
    b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"))
    if (b.measured && o.ctx >= b.no)
        return {ok: false, msg: "ctx " . o.ctx . " 超过本机实测硬上限 " . b.no . "（" . b.key
            . "，实测 " . b.ok . " 能启动 / " . b.no . " 被拒）。降到 " . b.ok . " 或以下。"}
    return {ok: true, msg: ""}
}

; 参数数组：顺序与两个 .bat 完全一致，且只在原 .bat 会出现的位置出现
;   --ctx --kv [--kv-resident] [--mtp off] --vram-reserve-mib --port --cors
;   [--draft-vocab] --thinking --preserve-thinking [--tag long] [--check] [--host] [--api-key]
BuildArgs(o, addCheck) {
    o := Normalize(o)
    a := ["--ctx", String(o.ctx), "--kv", o.kv]
    if (o.resident > 0)
        a.Push("--kv-resident", String(o.resident))
    if (o.mtp = "off")
        a.Push("--mtp", "off")
    a.Push("--vram-reserve-mib", String(o.reserve), "--port", String(o.port), "--cors", o.cors)
    if (o.mtp = "on")
        a.Push("--draft-vocab", o.draft)
    if (Prop(o, "mtp_cpu_moe", "off") = "on")
        a.Push("--mtp-cpu-moe", "1")
    if (Prop(o, "spec", "") != "")
        a.Push("--spec", Prop(o, "spec", ""))   ; 驱动用它覆盖模板里的 --spec
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
    out := {engine: [], serve: [], guard: [], launcher: [], driver: [], err: ""}
    try {
        wmi := ComObjGet("winmgmts:\\.\root\cimv2")
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
    global gpuCache
    if (force || (A_TickCount - gpuCache.ts > 30000)) {
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

Join(arr, sep) {
    s := ""
    for i, v in arr
        s .= (i = 1 ? "" : sep) . v
    return s
}

; 运行中实例的信息（服务端进程命令行 + /props）
QueryStatus(portHint) {
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
        return "loading"                       ; 端口通了但引擎没就绪（/props 503）
    if (driverAlive || (logAgeMin >= 0 && logAgeMin <= LOG_FRESH_MIN))
        return "loading"                       ; 端口没通，但看得出来正在加载
    return "zombie"                            ; 进程在、也不在加载 → 残留或崩了
}

; 我们这次启动的驱动（cmd 包装进程 / python 驱动）还活着吗
DriverAlive() {
    global gDriverPid
    if (gDriverPid && ProcessExist(gDriverPid))
        return true
    st := FindProcs()
    return (st.driver.Length || st.launcher.Length) ? true : false
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
        return {text: "运行状态: ● 运行中（引擎已加载）", color: "008000"}
    if (st.state = "loading")
        return {text: "运行状态: ◐ 加载中…（引擎在起，端口 " . st.port . " 还没就绪"
            . (ElapsedText() != "" ? " · " . ElapsedText() : "") . "）", color: "B8860B"}
    if (st.state = "zombie")
        return {text: "运行状态: ✕ 异常：进程还在但端口 " . st.port . " 无响应，日志也停了（看服务端日志尾部）", color: "C00000"}
    return {text: "运行状态: ○ 未运行（端口 " . st.port . " 无响应）", color: "606060"}
}

; ------------------------------------------------- 4. 预检
Preflight(o, addCheck) {
    o := Normalize(o)
    problems := [], warns := []
    if !FileExist(PY)
        problems.Push("venv python 缺失: " . PY . "  （先在 " . ROOT . " 跑一次 START-HERE.bat）")
    if !FileExist(DRIVER)
        problems.Push("驱动缺失: " . DRIVER)
    if !FileExist(BASE_CFG)
        problems.Push("模板配置缺失: " . BASE_CFG)
    v := ValidateNumbers(o)
    if !v.ok
        problems.Push("参数错误: " . v.msg)
    if problems.Length
        return {ok: false, msg: "预检未通过：`n  - " . Join(problems, "`n  - ")}

    st := QueryStatus(o.port)
    if BoundaryExceeded(o) {
        b := Boundary(o.kv, o.resident, o.mtp, Prop(o, "mtp_cpu_moe", "off"))
        warns.Push("ctx " . o.ctx . " 超过本机实测边界 " . b.ok . "（" . b.key . "）；引擎很可能拒绝启动并告诉你差多少 MiB。")
    }
    if (o.ctx > 81920 && o.resident = 0 && !addCheck)
        warns.Push("ctx 超过本机全常驻实测上限 81920（含 reserve 64）：显存要放下全部 K/V，很可能被拒。")
    if (st.ram.free >= 0) {
        if (st.ram.free < RAM_ABORT_MB)
            return {ok: false, msg: "内存余量只有 " . st.ram.free . " MB，低于护栏阈值 " . RAM_ABORT_MB
                . " MB —— 驱动一起来就会把引擎杀掉。先关掉占内存的程序再启动。"}
        if (st.ram.free < MODEL_NEED_MB)
            warns.Push("空闲内存 " . st.ram.free . " MB（共 " . st.ram.total . " MB），引擎要吞约 12 GiB 专家进内存；"
                . "护栏在余量 <" . RAM_ABORT_MB . " MB 时会杀引擎。")
    }
    if (st.procs.engine.Length || st.procs.serve.Length)
        warns.Push("已经有实例在跑（引擎 pid " . (st.procs.engine.Length ? st.procs.engine[1] : "-")
            . " / 服务端 pid " . (st.procs.serve.Length ? st.procs.serve[1].pid : "-")
            . "）：驱动启动时会先把它杀掉 —— 单卡上这是设计行为。")
    if (st.procs.guard.Length)
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
    if !FileExist(PY)
        problems.Push("venv python")
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
    o := CollectCurrent()
    pf := Preflight(o, addCheck)
    if !pf.ok {
        MsgBox(pf.msg, "Strata 启动器 - 预检失败", "Icon!")
        RefreshStatus()
        return
    }
    if (pf.warns.Length) {
        head := addCheck ? "预览前提醒（不影响 --check）：" : "启动前提醒："
        if (MsgBox(head . "`n`n  - " . Join(pf.warns, "`n  - ") . "`n`n继续？",
                   "Strata 启动器", "Icon! 0x4") != "Yes") {
            SetStatusText("用户取消了启动（提醒未通过）", "C00000")
            return
        }
    }
    SaveIni(o)
    logPath := DriverLogFor(o.mode)
    try DirCreate(RESULTS)                 ; 重定向目标目录必须存在，否则驱动根本起不来
    cmd := BuildLaunchCmd(o, addCheck, logPath)
    SetStatusText((addCheck ? "已发起预览 --check" : "已发起启动")
        . "（后台运行，不弹窗口；输出写 " . logPath . "）", "000080")
    try {
        Run(cmd, DEV, "Hide", &p)
        gDriverPid := p
        gDriverLog := logPath
        if !addCheck
            gLaunchTick := A_TickCount           ; 记下时刻：加载中要显示"已等多久"
        SetStatusText((addCheck ? "已发起预览 --check" : "已发起启动")
            . "（无窗口）：引擎加载约 12 秒，状态变绿即就绪；驱动输出见「驱动输出」按钮", "000080")
        RefreshStatus()                          ; 立刻刷一次：状态图马上变"加载中…"，不用等 5 秒定时器
    } catch as e {
        gDriverPid := 0
        MsgBox("无法启动：`n" . e.Message . "`n`n命令行：`n" . cmd, "Strata 启动器", "Icon!")
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
        MsgBox("没有发现运行中的 Strata 进程（引擎 / 服务端 / 护栏 / 驱动 / 启动 cmd 都没有）。", "Strata 启动器", "Iconi")
        RefreshStatus()
        return
    }
    if (MsgBox(StopConfirmText(), "Strata 启动器 - 停止", "Icon! 0x4") != "Yes")
        return
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
    SetStatusText("停止：请求 " . pids.Length . " 个进程，成功 " . killed . " 个", "C00000")
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
    if (pids.Length && MsgBox(StopConfirmText(), "Strata 启动器 - 重启", "Icon! 0x4") != "Yes")
        return
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
    SetStatusText("重启：已停 " . killed . " 个进程，等待释放后重新启动…", "000080")
    Sleep(1500)                        ; 给端口与显存一点释放时间
    DoLaunch(false)
}

OpenPath(path) {
    if !FileExist(path) && !DirExist(path) {
        MsgBox("找不到：`n" . path, "Strata 启动器", "Icon!")
        return
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
        SetStatusText("驱动已退出，但没找到输出日志： " . gDriverLog, "C00000")
        return
    }
    tl := TailOf(gDriverLog, 20000)
    j := JudgeDriverLog(tl.text)
    if (j.kind = "preview") {
        SetStatusText("预览完成（--check）：运行配置已重写，引擎没启动", "006400")
        return
    }
    if (j.kind = "ok") {
        SetStatusText("驱动已正常退出（服务端 code=0）", "006400")
        return
    }
    why := (j.kind = "fail" ? "（code=" . j.code . "）" : "（日志里没有 code= 行：驱动可能压根没起来）")
    SetStatusText("驱动异常退出" . why . " —— 见「驱动输出」", "C00000")
    MsgBox("驱动异常退出" . why . "，日志：" . gDriverLog . "`n`n最后几行：`n" . LastLines(tl.text, 18),
        "Strata 启动器", "Icon!")
}

; ------------------------------------------------- 6. 界面
CollectFields() {
    global rLong, ctxE, kvD, resE, mtpD, draftD, resvE, portE, corsE, thinkD, presD, hostE, keyE
    global visD, vistokE, mdlD, nativeE, mmprojE, gInSetFields
    global tempE, toppE, topkE, minpE, prespenE, reppenE, dryE, chatTplE, gParams
    o := Normalize(gParams)                  ; 隐藏字段（spec / mtp_cpu_moe / template / native …）从基准集合继承
    o.mode := (rLong.Value ? "long" : "short")
    o.ctx := IntOr(ctxE.Value, -1)
    o.kv := DdlText(kvD, "k8v4")
    o.resident := IntOr(resE.Value, -1)
    ; 界面的 MTP 下拉框是 gpu/cpu/off，映射成引擎的两个开关
    o.mtp_mode := DdlText(mtpD, (o.mode = "long" ? "cpu" : "gpu"))
    if (o.mode = "long" && o.mtp_mode = "gpu")
        o.mtp_mode := "cpu"          ; 长模式没有 gpu（装不下）
    o.mtp := (o.mtp_mode = "off") ? "off" : "on"
    o.mtp_cpu_moe := (o.mtp_mode = "cpu") ? "on" : "off"
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
    o.template := DdlText(mdlD, "strata-qwen36-iq3s.json")
    o.native := Trim(nativeE.Value)
    o.mmproj := Trim(mmprojE.Value)
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
    global visD, vistokE, mdlD, nativeE, mmprojE, gInSetFields
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
    draftD.Text := InList(o.draft, DRAFT_LIST, "en")
    resvE.Value := String(o.reserve)
    portE.Value := String(o.port)
    corsE.Value := o.cors
    thinkD.Text := InList(o.thinking, YN_LIST, "on")
    gInSetFields := true
    mdlD.Text := InList(Prop(o, "template", "strata-qwen36-iq3s.json"), ModelTemplates(), "strata-qwen36-iq3s.json")
    nativeE.Value := Prop(o, "native", "")
    mmprojE.Value := Prop(o, "mmproj", "")
    visD.Text := InList(Prop(o, "vision", "cpu"), VISION_LIST, "cpu")
    vistokE.Value := String(Prop(o, "vision_tokens", "300"))
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

ApplyPreset(mode) {
    global gIgnoreIni
    cur := CollectCurrent()
    ; 模式相关（ctx/kv/resident/mtp/mtp_mode/spec/draft/reserve）取预置；界面偏好（port/cors/采样…）取当前
    p := ModePreset(mode)
    q := gIgnoreIni ? p : LoadSection(mode = "long" ? "long" : "short", mode)
    for k in ["port", "cors", "thinking", "preserve", "host", "apikey", "temperature", "top_p", "top_k",
              "min_p", "presence_penalty", "repetition_penalty", "dry", "chat_template", "vision", "vision_tokens", "template",
              "native", "mmproj"]
        p.%k% := q.%k%
    ; 只覆盖与模式强相关的项；端口/来源/思考开关是用户自己的设置，保留
    ; reserve 现在随模式走（长模式 64、短模式 256），采样也保留（两模式相同）
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
    SetCurrent(p)
    UpdateDerived()
    SetStatusText("切到" . (mode = "long" ? "长模式" : "短模式") . "：ctx=" . p.ctx . " / resident="
        . p.resident . " / mtp=" . p.mtp . " / MTP " . p.mtp . "（port/cors/thinking 保留原值）", "000080")
    Tip((mode = "long" ? "长模式" : "短模式") . "：ctx=" . p.ctx . " / " . p.kv
        . (p.resident > 0 ? " / 流式" . p.resident : " / 全常驻") . " / MTP " . p.mtp)
}

; 简洁模式改了 ctx 时，把专业模式的「边界检查」那行也刷新
UpdateProBoundary() {
    global bndT
    if !IsSet(bndT) || !IsObject(bndT)
        return
    o := SimpleCollect()
    if (o.ctx > 0 && o.resident >= 0) {
        bndT.SetFont("s9 " . (BoundaryExceeded(o) ? "cC00000" : "c006400"))
        bndT.Text := "边界检查: " . BoundaryText(o)
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
        bndT.Text := "边界检查: " . BoundaryText(o)
    }
    MakeLinks(o.port > 0 ? o.port : 1339, gMonitorOn)
    UpdateSimpleDerived(o.port > 0 ? o.port : 1339)
}

; 链接行：只放"确实可用"的端点。/api-monitor 是请求监控页，服务端默认关闭
; （config 里 api_monitor: true 或 --api-monitor 才开），关着时它返回 404 的 JSON
; —— 所以只在探到 200 时才出现这一项；平时用始终可用的 /metrics（网页聊天里"监控"页签的数据源）。
LinkItems(base, monitorOn) {
    items := [["网页聊天", base . "/"],
              ["/props", base . "/props"],
              ["/v1/models", base . "/v1/models"],
              ["/slots", base . "/slots"],
              ["/health", base . "/health"],
              ["/metrics", base . "/metrics"]]
    if monitorOn
        items.Push(["API 监控", base . "/api-monitor"])
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
    ToolTip(msg)
    SetTimer(() => ToolTip(), -2000)
}

ClipText(s, n) {                        ; 超长反馈文案截断（两个字宽相差一倍，按字符数保守取）
    s := String(s)
    if (StrLen(s) <= n)
        return s
    return SubStr(s, 1, n - 1) . "…"
}

SetStatusText(t, color) {               ; 反馈行只存在于专业模式（简洁模式不放这一行）
    global logs
    col := (color = "" || color = "000000" ? "c000080" : "c" . color)
    if IsSet(logs) && IsObject(logs) {
        logs.SetFont("s8 " . col)
        logs.Text := "最近动作: " . FormatTime(A_Now, "HH:mm:ss") . "  " . ClipText(t, 70)
    }
}

RefreshStatus() {
    global st1, st2, st3, st4, st5, st6, tailE, gMonitorOn
    o := CollectFields()
    st := QueryStatus(o.port > 0 ? o.port : 1339)
    sl := StateLine(st)
    st1.SetFont("s9 Bold c" . sl.color)
    st1.Text := sl.text
      st2.Text := "进程: 引擎 " . (st.procs.engine.Length ? st.procs.engine[1] : "无")
          . " · 服务端 " . (st.procs.serve.Length ? st.procs.serve[1].pid : "无")
          . " · 驱动 " . (st.procs.driver.Length ? st.procs.driver[1].pid : "无")
          . " · 护栏 " . (st.procs.guard.Length ? st.procs.guard[1] : "无")
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
    st3.Text := "端口 " . st.port . " · /props " . (st.http.ok ? "HTTP " . st.http.status : "无响应")
        . (st.mode != "" ? " · " . (st.mode = "long" ? "长" : "短") . "模式" : "") . extra
          . " · 监控 " . (mon ? "开" : "关")
    c := (st.ram.free >= 0 && st.ram.free < RAM_ABORT_MB) ? "cC00000"
       : (st.ram.free >= 0 && st.ram.free < MODEL_NEED_MB ? "cB8860B" : "c006400")
    st4.SetFont("s8 " . c)
    st4.Text := "内存: 空闲 " . Round(st.ram.free / 1024, 1) . " GiB / 共 " . Round(st.ram.total / 1024, 1)
        . " GiB（护栏阈值 <" . RAM_ABORT_MB . " MB 杀引擎；模型要 ~12 GiB）"
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
    st5.Text := "显存: " . (snap.used < 0
        ? "读不到（nvidia-smi 不可用）"
        : "已用 " . snap.used . " / " . snap.total . " MiB") . occ
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
      st6.Text := "文件自检: " . (miss.Length ? "缺 " . Join(miss, "、") : "齐全")
          . " · " . (logMode = "long" ? "长" : "短") . "模式日志 " . (tail.mtime != "" ? tail.mtime : "无")
    tailE.Value := LastLines(tail.text, 14)
    SimpleStatusUpdate(st)                  ; 简洁模式那边只更新状态图
}

RefreshTick() {
    global guiAlive, gDriverPid
    if !guiAlive
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
    g := Gui(opt, "Strata 启动器 - Qwen3.6-35B-A3B UD-IQ3_S")
    gHasGui := true
    g.SetFont("s9", "Segoe UI")

    g.AddGroupBox("x8 y8 w704 h102", "模式（切换按预设覆盖 ctx/kv/resident/mtp/reserve/preserve 等模式相关参数）")
    g.AddButton("x612 y26 w96 h28", "简洁模式 →").OnEvent("Click", (*) => SwitchTo("simple"))
    rShort := g.AddRadio("x22 y32 w110", "短模式（快）")
    rLong := g.AddRadio("x150 y32 w160", "长模式（长上下文）")
    rShort.Value := 1
    g.AddText("x22 y56 w676 c404040", "短 = 20K ctx / k8v4 / MTP 开（--spec 3，专家在 GPU）/ KV 全常驻 / reserve 64（上限 39936）")
    g.AddText("x22 y74 w676 c404040", "长 = 80K ctx / KV 全常驻 / reserve 64 / MTP 开（--spec 2，专家在主机内存）/ 上限 81920（实测 65K prompt decode ~19-21 tok/s）")
    bndT := g.AddText("x22 y94 w676 c006400", "边界检查: —")
    rShort.OnEvent("Click", (*) => ApplyPreset("short"))
    rLong.OnEvent("Click", (*) => ApplyPreset("long"))

    g.AddGroupBox("x8 y118 w704 h206", "参数（改完直接点启动；字段名与驱动一致）")
    ; 模型行：模板下拉 + GGUF / mmproj 文件选择
    g.AddText("x22 y142 w40", "模型")
    mdlD := g.AddDropDownList("x64 y138 w200", ModelTemplates())
    mdlD.OnEvent("Change", (*) => LoadTemplate(mdlD.Text))
    g.AddButton("x270 y138 w58 h26", "GGUF…").OnEvent("Click", (*) => PickNative())
    g.AddButton("x332 y138 w62 h26", "mmproj…").OnEvent("Click", (*) => PickMmproj())
    g.AddButton("x398 y138 w44 h26", "清空").OnEvent("Click", (*) => (nativeE.Value := "", mmprojE.Value := "", Tip("已清空 GGUF/mmproj 覆盖")))
    nativeE := g.AddEdit("x446 y138 w256 h24 ReadOnly", "")
    nativeE.SetFont("s8")
    mmprojE := g.AddEdit("x22 y164 w680 h20 ReadOnly", "")
    mmprojE.SetFont("s8")
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

    g.AddGroupBox("x724 y302 w520 h210", "服务端日志尾部（自动刷新；自动换行；可滚动）")
    tailE := g.AddEdit("x734 y318 w500 h184 ReadOnly Multi VScroll", "")
    tailE.SetFont("s8", "Consolas")

    gLinks := []
    guiAlive := true
    g.OnEvent("Close", OnClose)
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
        return {glyph: "●", word: "运行中", color: "008000"}
    if (st.state = "loading")
        return {glyph: "◐", word: "加载中…", color: "B8860B"}
    if (st.state = "zombie")
        return {glyph: "✕", word: "异常", color: "C00000"}
    return {glyph: "○", word: "未运行", color: "808080"}
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
    o := Normalize(gParams)                  ; 隐藏字段用基准集合里的原值
    o.mode := (sLongR.Value ? "long" : "short")
    o.ctx := IntOr(sCtxE.Value, o.ctx)
    o.port := IntOr(sPortE.Value, o.port)
    o.thinking := (sThinkCB.Value ? "on" : "off")
    o.preserve := (sPresCB.Value ? "on" : "off")
    o.apikey := Trim(sKeyE.Value)
    o.vision := DdlText(sVisD, "cpu")
    o.vision_tokens := Trim(sVisTokE.Value, " `t`r`n")
    o.tag := (o.mode = "long" ? "long" : "")
    o.title := ModePreset(o.mode).title
    return o
}

SetSimpleFields(o) {
    global sCtxE, sPortE, sKeyE, sThinkCB, sPresCB, sShortR, sLongR, sVisD, sVisTokE
    o := Normalize(o)
    sCtxE.Value := String(o.ctx)
    sPortE.Value := String(o.port)
    sKeyE.Value := o.apikey
    sThinkCB.Value := (o.thinking = "on")
    sPresCB.Value := (o.preserve = "on")
    sVisD.Text := InList(Prop(o, "vision", "cpu"), VISION_LIST, "cpu")
    sVisTokE.Value := String(Prop(o, "vision_tokens", "300"))
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
    sChatLink.Text := '<a href="' . ChatUrl(port) . '">打开网页聊天</a>'
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
    if (px || py)
        WinMove(px, py, , , "ahk_id " . toGui.Hwnd)
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
    SetStatusText("已切到" . (mode = "simple" ? "简洁模式" : "专业模式"), "000080")
    UpdateDerived()
    RefreshStatus()
}

BuildSimpleGui() {
    global
    sg := Gui("-MaximizeBox", "Strata 启动器 - 简洁模式")
    gHasGui := true
    if ONTOP
        sg.Opt("+AlwaysOnTop")
    sg.SetFont("s10", "Segoe UI")

    sg.AddText("x22 y14 w300", "Strata 启动器 · 简洁模式")
    sg.AddButton("x344 y8 w108 h28", "专业模式 →").OnEvent("Click", (*) => SwitchTo("pro"))

    sg.AddGroupBox("x8 y44 w444 h48", "模式")
    sShortR := sg.AddRadio("x22 y66 w110", "短模式（快）")
    sLongR := sg.AddRadio("x150 y66 w170", "长模式（长上下文）")
    sShortR.Value := 1
    ; 说明文字按用户要求不显示（用户不关心 kv/mtp 等细节）
    ; sg.AddText("x22 y92 w420 c404040", "短：20K 上下文 / MTP 开　长：64K 上下文、KV 全常驻 / MTP 关（实测更快）")
    sShortR.OnEvent("Click", (*) => ApplyPreset("short"))
    sLongR.OnEvent("Click", (*) => ApplyPreset("long"))

    sg.AddGroupBox("x8 y100 w444 h152", "参数")
    sg.AddText("x22 y130 w70", "上下文长度")
    sCtxE := sg.AddEdit("x96 y126 w86", "20480")
    sg.AddText("x198 y130 w34", "端口")
    sPortE := sg.AddEdit("x236 y126 w76", "1339")
    sThinkCB := sg.AddCheckBox("x22 y162 w110", "启用思考")
    sPresCB := sg.AddCheckBox("x150 y162 w170", "preserve-thinking")
    sg.AddText("x22 y194 w56", "api-key")
    sKeyE := sg.AddEdit("x82 y190 w214")
    sCopyKey := sg.AddButton("x302 y190 w84 h26", "复制")
    sg.AddText("x22 y222 w56", "图片")
    sVisD := sg.AddDropDownList("x82 y218 w76", VISION_LIST)
    sg.AddText("x166 y222 w50", "图tok")
    sVisTokE := sg.AddEdit("x220 y218 w50", "300")
    sg.AddText("x278 y222 w170 c404040", "cpu=不占显存（推荐）")
    sCopyKey.OnEvent("Click", (*) => CopyWithFeedback(sCopyKey, sKeyE.Value, "复制", "api-key 为空"))
    sCtxE.OnEvent("Change", (*) => (UpdateSimpleDerived(IntOr(sPortE.Value, 1339)), UpdateProBoundary()))
    sPortE.OnEvent("Change", (*) => UpdateSimpleDerived(IntOr(sPortE.Value, 1339)))

    sg.AddGroupBox("x8 y260 w444 h48", "运行状态")
    sBadge := sg.AddText("x22 y280 w410 h20 c808080", "○  未运行")   ; 与其它文字同号，只靠颜色区分

    sg.AddButton("x22 y320 w84 h36", "启动").OnEvent("Click", (*) => DoLaunch(false))
    sg.AddButton("x112 y320 w84 h36", "重启").OnEvent("Click", (*) => DoRestart())
    sg.AddButton("x202 y320 w72 h36", "停止").OnEvent("Click", (*) => DoStop())
    sg.AddButton("x280 y320 w72 h36", "刷新").OnEvent("Click", (*) => RefreshStatus())
    sg.AddButton("x358 y320 w84 h36", "保存为默认").OnEvent("Click", (*) => SaveIni(CollectCurrent()))

    sg.AddGroupBox("x8 y366 w444 h74", "浏览器")
    sChatLink := sg.AddLink("x22 y386 w300 h24 cBlue", "打开网页聊天")   ; 建 Link 时必须给文字/宽度，
    sChatLink.SetFont("s10")                                         ; 空文字建的 Link 宽 0，之后设 Text 也显不出来
    sg.AddText("x22 y416 w60", "接口地址")
    sBaseE := sg.AddText("x86 y414 w250", "")          ; 用 Text 而不是只读 Edit：只读 Edit 会被系统当作
    sCopyBase := sg.AddButton("x344 y408 w70 h26", "复制")   ; 首个可聚焦控件，一打开就是"整段被选中"的样子
    sCopyBase.OnEvent("Click", (*) => CopyWithFeedback(sCopyBase, sBaseE.Text, "复制"))

    gSimple := sg
    sg.OnEvent("Close", OnClose)
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
        IniWrite(o.mmproj, INI, sec, "mmproj")
        IniWrite(gUiMode, INI, "ui", "ui")
        SetStatusText("已保存为默认（" . sec . " 模式，ctx=" . o.ctx . "）", "000080")
        Tip("已保存为默认：" . (o.mode = "long" ? "长" : "短") . "模式 ctx=" . o.ctx)
    } catch as e {
        SetStatusText("保存失败: " . e.Message, "C00000")
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
        SetStatusText("已载入上次设置（" . (p.mode = "long" ? "长" : "短") . "模式 ctx=" . p.ctx
            . " port=" . p.port . "），改完点「启动」", "000080")
        return true
    } catch
        return false
}

; 从 [short]/[long] 读一个模式的完整参数；该段不存在则用 ModePreset 默认值
LoadSection(sec, mode) {
    p := ModePreset(mode)
    if IniRead(INI, sec, "ctx", "@@none@@") = "@@none@@"
        return p
    for k in ["kv", "mtp", "draft", "cors", "thinking", "preserve", "host", "apikey", "chat_template", "dry",
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
    global selfBuf, DEV, gUiMode, gParams, gIgnoreIni
    selfBuf := ""
    SelfSay("Strata 启动器自检  " . FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . "   AHK " . A_AhkVersion . "   ptr" . A_PtrSize)

    SelfSay("`n--- 1. 文件 ---")
    SelfCheck("venv python  " . PY, FileExist(PY))
    SelfCheck("驱动        " . DRIVER, FileExist(DRIVER))
    SelfCheck("模板配置    " . BASE_CFG, FileExist(BASE_CFG))
    SelfCheck("results 目录 " . RESULTS, DirExist(RESULTS))
    SelfCheck("护栏脚本    " . GUARD_PY, FileExist(GUARD_PY))
    SelfCheck("serve/web/index.html（网页聊天）", FileExist(ROOT . "\serve\web\index.html"))

    bats := BatObjects()
    SelfSay("`n--- 2. 参数数组 = 原 .bat 逐字复刻 ---")
    expShort := '--ctx "20480" --kv "k8v4" --vram-reserve-mib "64" --port "1339" --cors "*" --draft-vocab "en" --spec "3" --thinking "on" --preserve-thinking "on" --temperature "0.6" --top-p "0.95" --top-k "20" --dry-multiplier "1.5" --base "strata-qwen36-iq3s.json" --vision "cpu" --vision-tokens "300"'

    expLong  := '--ctx "81920" --kv "k8v4" --vram-reserve-mib "64" --port "1339" --cors "*" --draft-vocab "en" --mtp-cpu-moe "1" --spec "2" --thinking "on" --preserve-thinking "on" --temperature "0.6" --top-p "0.95" --top-k "20" --dry-multiplier "1.5" --tag "long" --base "strata-qwen36-iq3s.json" --vision "cpu" --vision-tokens "300"'

    sLine := ArgsToStr(BuildArgs(ModePreset("short"), false))
    lLine := ArgsToStr(BuildArgs(ModePreset("long"), false))
    SelfSay("    短模式实际：" . sLine)
    SelfSay("    短模式期望：" . expShort)
    SelfSay("    长模式实际：" . lLine)
    SelfSay("    长模式期望：" . expLong)
    SelfCheck("短模式命令行 = 预置（含引号）", sLine = expShort)
    SelfCheck("长模式命令行 = run-strata-qwen36-long.bat:49（含引号）", lLine = expLong)
    SelfCheck("短模式不带 --kv-resident / --mtp", !InStr(sLine, "--kv-resident") && !InStr(sLine, "--mtp"))
    SelfCheck("短模式：AHK 参数生成与预置一致", ArgsToStr(BuildArgs(ModePreset("short"), false)) = sLine)
    ; INI 往返：用一个临时 INI，验证 chat_template 真的存得下、读得回（不碰真 INI）
    global INI
    savedIni := INI
    INI := A_Temp . "\strata-launcher-inicheck.ini"
    try FileDelete(INI)
    try {
        iniO := ModePreset("short")
        iniO.chat_template := "D:/dev/templates/froggeric-qwen36.jinja"
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
    withTpl.chat_template := "D:\dev\templates\froggeric-qwen36.jinja"
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
    bad.ctx := 99999
    SelfCheck("越界 ctx 99999 能被识别", BoundaryExceeded(bad))
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
        lp := ModePreset("long")
        gParams := lp
        SetSimpleFields(lp)
        c2 := SimpleCollect()
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
        stCases := [[0, 0, 0, 0, -1, "stopped"], [1, 1, 200, 0, -1, "running"], [1, 1, 503, 0, -1, "loading"]
            , [1, 0, 0, 1, -1, "loading"], [1, 0, 0, 0, 1, "loading"], [1, 0, 0, 0, -1, "zombie"]
            , [1, 0, 0, 0, 99, "zombie"]]
        for c in stCases {
            got := DecideState(c[1], c[2], c[3], c[4], c[5])
            SelfCheck("判定 " . c[1] . "/" . c[2] . "/" . c[3] . "/" . c[4] . "/" . c[5] . " → " . c[6],
                got = c[6], "得到 " . got)
        }
        SelfCheck("加载中会显示已等多久（或为空=没记录启动时刻）",
            (ElapsedText() = "" || InStr(ElapsedText(), "已等")), "[" . ElapsedText() . "]")
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
        hard.ctx := 40000                    ; 边界内但超过当前设定 -> 应带提醒
        p3 := Preflight(hard, false)
        SelfCheck("接近边界的 ctx 仍 ok 并带提醒", p3.ok && p3.warns.Length > 0,
            "ok=" . p3.ok . " warns=" . (p3.HasOwnProp("warns") ? p3.warns.Length : "无"))
        over := ModePreset("short")
        over.ctx := 999999                   ; 远超实测边界 -> 硬拒
        p3b := Preflight(over, false)
        SelfCheck("超过实测硬上限的 ctx 被直接拒绝", !p3b.ok, p3b.msg)
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
SelftestError(err, mode) {              ; 自检出错时写报告文件，绝不弹窗卡住
    global selfBuf
    try FileAppend(selfBuf . "`n[ERROR] " . err.Message . "  @" . err.Line . "  (" . err.What . ")`n", SELFLOG, "UTF-8")
    ExitApp(2)
}

if (A_Args.Length >= 1 && A_Args[1] = "--selftest") {
    OnError(SelftestError)
    Selftest()
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
        SetTimer(() => ExitApp(0), -2500)
    }
    if HasArg("--switchtest") {             ; 真窗口互切一遍：验证 Show/Hide 这条路径
        res := ""
        for m in ["simple", "pro", "simple", "pro"] {
            SwitchTo(m)
            Sleep(600)
            res .= m . "→当前=" . gUiMode
                . " 简洁可见=" . (WinExist("ahk_id " . gSimple.Hwnd) ? "是" : "否")
                . " 专业可见=" . (WinExist("ahk_id " . gPro.Hwnd) ? "是" : "否") . "`n"
        }
        try FileDelete(SWITCHLOG)
        FileAppend("switchtest " . FormatTime(A_Now, "HH:mm:ss") . "`n" . res, SWITCHLOG, "UTF-8")
        ExitApp(0)
    }
} catch as e {
    if smoke {
        try FileAppend("guismoke FAIL " . e.Message . "  @" . e.Line . "  (" . e.What . ")`n", SMOKELOG, "UTF-8")
        ExitApp(3)
    }
    MsgBox("界面启动失败：`n" . e.Message . "`n位置：" . e.What . " @行 " . e.Line, "Strata 启动器", "Icon!")
    ExitApp(4)
}
