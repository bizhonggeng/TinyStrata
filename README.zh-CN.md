# TinyStrata

<img src="assets/icon.png" width="96" align="right" alt="TinyStrata">

[简体中文](README.zh-CN.md) | [English](README.md)

---

## 1. 目标

> **在 4G VRAM 显卡中快速、高质量、稳定的运行 MoE 模型（比如 Qwen3.6-35B-A3B）。**

上游 [Strata](https://github.com/Niko1221/Strata) 在 8–12 GB 显卡上跑 Qwen3.6-35B-A3B 没问题。
压到 4 GB 会同时撞上三堵墙：

1. **装不下** —— 光 MTP draft 层就要 439 MiB，和 80 K 上下文的 KV 挤不下；
2. **说重复的话** —— 长上下文下会进入逐字重复的推理循环，烧掉几万 token 却不给答案；
3. **会话丢失** —— 内存吃紧时 parked 会话被丢弃，切回来等于重读几小时 prompt。

TinyStrata 就是这三堵墙的三个修复，外加用来量化它们的启动器、驱动和测速脚本。
它很小：**3 个补丁（约 430 行）+ 一套工具**，不是整树 fork。

---

## 2. 特性

| # | 特性 | 说明 |
|---|---|---|
| 1 | **MTP 专家上 CPU**（`--mtp-cpu-moe`） | draft 层的 256 个路由专家搬到主机内存、跑在 CPU 上，CPU 路径跳过 CUDA graph 捕获。draft 层显存 **439 → 127 MiB**，这才让 `--max-context 81920` 保得住投机解码 |
| 2 | **DRY 采样器**（`--dry-multiplier`） | llama.cpp 的 DRY 做成 logits 前置 kernel：惩罚随**重复序列长度**增长，而不是随 token 频次。默认关闭（逐位不变），专治逐字重复的推理循环 |
| 3 | **会话自动存盘** | 请求完成后按指纹自动 SAVE 到磁盘，切回自动 RESTORE。52 K token 对话 **0.47 s** 恢复，替代 314 s 的重读；parked 会话的磁盘兜底 |
| 4 | **日志时间戳** | 引擎与驱动每一行都带 `HH:MM:SS`（1150 处 `fprintf` 不动 C++，用管道加戳），排查时序问题不用再猜 |
| 5 | **图形启动器** | AutoHotkey v2，专业/简洁双视图、参数网格、模型/GGUF/mmproj 选择器、视觉、chat 模板、运行状态、日志尾部、按模式存 INI。自带 `--selftest` |
| 6 | **驱动与工具** | `strata-run.py`（一条命令起一个模式）、`watch-loop.py`（双源循环监控）、`ab-*.py`（预热+交错+中位的 A/B 测速） |

### 2.1 实测性能

本机 RTX 3050 Ti Laptop **4 GB** + i5-11400H + 32 GB，两套参数：

| | 短模式 | 长模式 |
|---|---|---|
| `--max-context` | 20480 | **81920** |
| KV | `k8v4`，全驻留 | `k8v4`，全驻留 |
| MTP | 开，专家**在 GPU**（`--spec 3`）*或* **在 CPU**（`--mtp-cpu-moe 1`，`--spec 2`）/ 关 | 开，专家**在 CPU**（`--mtp-cpu-moe 1`，`--spec 2`） |
| `--vram-reserve-mib` | 64 | 64 |
| `--expert-cache` | 800 | 800 |
| 能启动的最大上下文 | 39936 | **81920** |
| **decode** | ~32–36 tok/s | **18.00 tok/s @79 K**（3 轮中位） |
| **prefill** | ~250 tok/s | **153.8 tok/s @79 K** |

同一条 79 K prompt、同一台机器，对比 llama.cpp（b11382）跑同族模型的 `Q4_K_M`：

| | TinyStrata（UD-IQ3_S，3.46 bit/w） | llama.cpp（Q4_K_M，5.19 bit/w） |
|---|---:|---:|
| prefill @79 K | **153.8 tok/s** | 103.3 tok/s |
| decode @79 K | **18.00 tok/s** | 12.35 tok/s |
| draft 接受率 | 71–78 % | 65–78 % |

两个速度的比值（decode 1.46、prefill 1.49）几乎正好等于权重大小之比（5.19 / 3.46 = 1.50）：
这个尺寸下解码是**搬运字节数**问题，所以更小的量化赢，i-quant 没有额外代价。

---

## 3. 硬件与运行环境

### 3.1 Release 里的二进制只在下列环境可用

| 项 | 要求 | 不满足会怎样 |
|---|---|---|
| **GPU 架构** | **sm_86**（Ampere 消费/专业卡：RTX 3050/3060/3070/3080/3090、A10/A40 …） | Release 的 `strata.exe` 只编了 86 一个架构，别的卡会报 "no kernel image" 类错误 → 按 §5 自行编译 |
| **CUDA 运行时** | **CUDA 12.x** 的 `cudart64_12.dll` 与 `cublas64_12.dll` 要在 `PATH` 上 | 缺 DLL 引擎直接起不来。装 CUDA Toolkit 12.x，或把配置里的 `lib_dirs` 指到它的 `bin` |
| **驱动** | 支持 CUDA 12.x（R525 以上；实测 621.24） | 同上 |
| 显存 | **≥ 4 GB** | 不够时引擎拒绝启动，或 `--max-context` 被拒 |
| 内存 | **32 GB**（专家常驻，约 12 GiB） | 内存护栏会杀进程 |
| 系统 | **Windows x64** | 本仓库只在 Windows 上验证过 |

> 8 GB 以上的卡当然更宽松，但本仓库所有数字都来自 **RTX 3050 Ti Laptop 4 GB + i5-11400H + 32 GB**。

### 3.2 自己编译时

| 项 | 说明 |
|---|---|
| CUDA | 12.8（`build-strata-cuda12.bat`）；其它 12.x 版本一般也能编 |
| GPU 架构 | `-DCMAKE_CUDA_ARCHITECTURES=86`（默认值就是 86，换卡改成自己的，如 89/120） |
| 工具链 | Python 3.11 venv + `cmake` + `ninja` + MSVC（`vcvars64`），上游 `START-HERE.bat` 会建 |
| 磁盘 | 模型 15.3 GB + pack 65 MB + 会话文件（52K token ≈ 588 MB） |

模型：`unsloth/Qwen3.6-35B-A3B-MTP-GGUF` 的 **UD-IQ3_S**（15.3 GB）或 UD-IQ4_XS（18.2 GB）；
**MTP 层必须在文件里**（`blk.40`），换别的量化先按
[`docs/GGUF-SELECTION-STANDARD.md`](docs/GGUF-SELECTION-STANDARD.md) 的三步判据验一遍。

---

## 4. 快速入门（下载即用，不用编译）

### 4.1 下载

| 文件 | 从哪来 |
|---|---|
| **`TinyStrata-0.1.0-portable.zip`**（53.7 MB） | **最省事的一条路**：解压 → 双击 `TinyStrata-Launcher.exe` → 选 GGUF → 启动。内含引擎、启动器、`serve\`、内嵌 Python 3.11 + numpy，**不用装 Python，也不用装 AutoHotkey** |
| `TinyStrata-Launcher.exe`（v0.1.0） | [Releases / v0.1.0](https://github.com/bizhonggeng/TinyStrata/releases/tag/v0.1.0)（538 KiB，**不装 AutoHotkey 也能跑**） |
| `strata.exe` + `strata.exe.sha256` | 同上（61.7 MiB，CUDA 12.8 / sm_86） |
| `strata-launcher.ahk`（可选） | 本仓库 [launcher/](launcher/)（想自己改界面才需要 AutoHotkey v2） |
| `strata-run.py`（可选） | 本仓库 [tools/](tools/)，命令行驱动 |
| 模型 GGUF | 见 §7 |

> **启动器会自己找引擎**：从它所在的目录、往上 4 级父目录、以及各自的子目录里搜
> `strata.exe`（也认 `engine-cuda12\strata.exe` 这种检出布局），然后自动推出
> python / 驱动 / 配置 / 日志目录。也可以显式指定：环境变量 `STRATA_HOME`，
> 或在菜单里「浏览…」选一次（记进 ini）。
> 界面中英双语，**默认跟随系统语言**，菜单栏「语言 / Language」可随时切换。

```powershell
# 校验（应输出 9c6f5a0f...）
Get-FileHash strata.exe -Algorithm SHA256
Get-Content strata.exe.sha256
```

### 4.2 便携包（推荐给"只想跑起来"的人）

`TinyStrata-0.1.0-portable.zip` 解压后是这样：

```
TinyStrata\
├── TinyStrata-Launcher.exe     启动器（已编译，不需要 AutoHotkey）
├── python\                     内嵌 CPython 3.11 + numpy / jinja2 / psutil / gguf
├── strata\
│   ├── engine-cuda12\strata.exe
│   ├── serve\                   OpenAI 兼容层 + 网页聊天
│   ├── tools\                   iq_pack.py / make_pack.py / gguf_reader.py ...
│   └── data\                    专家 profile + draft vocab
├── tools\strata-run.py          命令行驱动（启动器会调它）
├── strata-qwen36-iq3s.json      模板（保留 %占位符%，服务端会自动补）
├── configs\ docs\ README 等
└── results\  sessions\          运行时生成；pack 会自动建在 ..\packs\
```

**第一次运行**：双击 `TinyStrata-Launcher.exe` → 「模型」里 `GGUF` 选你的文件 → `启动`。
服务端会在引擎启动前自动做这几件事（日志里能看到 `[prepare]` 行）：

1. 给这个 GGUF 建 pack（约 3 秒 / 65 MB，专家仍留在 GGUF 里）
2. 把 `--pack` 和 `tokenizer` 指到新 pack
3. 模板里还是占位符的 `exe` / `cwd` / `--expert-profile` / `--mtp-draft-vocab` / `--mtp` 用包内自带的文件补齐
4. 视觉编码器不存在 → 自动关掉 vision（不报错）

实测（便携树、内嵌 python、没有装任何东西）：给一个 GGUF 路径后
`ready: http://127.0.0.1:13501/v1 (context 20480 tokens)`。

`FIRST-RUN.txt` 里也写了这几步；日志在 `results\`。

### 4.2.1 就位

```powershell
# <install> = 你放 TinyStrata 的目录，例如 C:\TinyStrata（下面都用它当例子）
copy strata.exe              <install>\strata\engine-cuda12\strata.exe
copy TinyStrata-Launcher.exe <install>\
copy strata-run.py           <install>\tools\
```

目录名字随便取：启动器会自己找引擎（§4.5），命令行驱动也知道自己的位置
（`tools/strata-run.py` 的上一级就是 `<install>`）。要换布局就用环境变量
`STRATA_HOME` / `STRATA_ROOT` 显式指定，见 §5.3。

### 4.3 pack：这是什么、为什么换模型要换它

引擎不直接吃 GGUF：它要一个"pack"。pack **不是模型的副本** —— 里面只有

```
<packs>/qwen36-UD-IQ3_S/
  dense.bin            53 MB   非专家权重（attention/norm/embedding）转成引擎的布局
  index.txt            52 KB   613 个张量的索引
  native_experts.txt    4 KB   ★ 每层专家在 GGUF 里的字节偏移（12 GiB 专家留在 GGUF，不复制）
  tokenizer\          9.7 MB
  conversions.json / compat-bf16.json   量化转换元数据
```

所以做一次 pack 只要 **3 秒 / 65 MB**（实测，15.3 GB 的 GGUF）。三条路任选：

**A. 直接用 Release 里的现成 pack（推荐，零依赖）**

对应 `UD-IQ3_S` 的 pack 已经打好：
`Releases → pack-qwen36-UD-IQ3_S.zip`（43.7 MB），解压到模板里 `--pack` 的**上一级**目录
（默认 `<install>\packs\`），得到 `<install>\packs\qwen36-UD-IQ3_S\dense.bin …`。

**B. 什么都不用做（推荐给"只下了 GGUF"的人）**

启动器只负责把模型路径传下去；**服务端在引擎启动前自己准备 pack**
（`serve/prepare.py`，约 3 秒）：它发现 `--pack` 不匹配或缺失，就按 GGUF 文件名
建好、改掉 `--pack` 和 `tokenizer`，然后才加载模型。日志里会看到：

```
[prepare] 这个 GGUF 还没有匹配的 pack: Qwen3.6-35B-A3B-UD-IQ3_S.gguf
[prepare]   -> <install>\packs\qwen36-ud-iq3_s（约 3 秒，专家仍留在 GGUF 里）
[prepare] pack 就绪: <install>\packs\qwen36-ud-iq3_s
```

启动器那边只显示一句"启动时会自动生成 pack（约 3 秒）"，它自己**不跑 python、不写文件**。

**C. 命令行**

```powershell
# 引擎自己写（不需要 Python / numpy / GPU）
<install>\strata\engine-cuda12\strata.exe pack --gguf <你的.gguf> --out <install>\packs\qwen36-UD-IQ3_S

# 需要反量化的文件（小投影是量化类型）才回退到 python 的打包器
python tools\make_pack.py --gguf <你的.gguf> --packs <install>\packs
```
> 服务端也是这样：先调引擎的 `pack` 子命令，失败才回退到 python 打包器；tokenizer 由服务端补。


> **换量化必须换 pack。** pack 的 `native_experts.txt` 里写明了它指向哪个 GGUF 文件；
> 拿 IQ3_S 的 pack 配 IQ4_XS 的模型会静默读出垃圾。启动器现在会在启动前比对文件名，
> 不一致直接拦下并说明原因。

（`setup.py --family qwen36 --model UD-IQ3_S` 是"全套流程"那条路：它会下模型、建 pack、
选 MTP 层、写配置，适合从零开始；只要 pack 的话用上面 A/B/C 更快。）

### 4.4 配模板

把 `configs/strata-qwen36-iq3s.example.json` 复制成 `<install>\strata-qwen36-iq3s.json`。
模板里用的是**环境变量占位符**（`%STRATA_ROOT%` / `%STRATA_PACKS%` / `%STRATA_MODELS%` …），
要么把变量设上（见 `configs/README.md`），要么把里面的路径改成你自己的。

### 4.5 启动

**方式 A：图形界面** —— 双击 `TinyStrata-Launcher.exe`（或 `.ahk`），选模式（长/短）→ 启动。
它自己定位引擎，不用改任何路径；**简洁模式里就有「模型」分组**（GGUF / mmproj 两个「选择…」按钮），
下完模型直接选就行，不用切到专业模式。
**视觉也跟它走**：没选 mmproj 时「图片」自动是 `off`（下拉框置灰、不会报错）；
选了 mmproj 才默认切到 `cpu`（不占显存），之后还能自己改成 `gpu` / `off`。中英文跟随系统语言，菜单栏「语言 / Language」可切；「关于 / About」里有可点的项目主页 / 上游 / 模型链接，
还会列出启动器实际定位到的路径（排查「找不到引擎」时看这一屏）。
启动器自检：`TinyStrata-Launcher.exe --selftest` / `--i18ntest` / `--findtest`（报告落在引擎旁边）。
**引擎可以换**：换成你自己编的那份，用环境变量 `STRATA_EXE` 或菜单「关于 → 选择引擎…」（见 §5.4）。

**方式 B：命令行**

```bash
# 长模式（80 K，MTP 专家在 CPU）—— 本仓库讲的就是这个模式
python tools/strata-run.py --tag long --ctx 81920 --kv k8v4 --vram-reserve-mib 64 \
    --mtp on --mtp-cpu-moe on --spec 2 --thinking on --preserve-thinking on

# 短模式（20 K，MTP 专家在 GPU）
python tools/strata-run.py --ctx 20480 --kv k8v4 --vram-reserve-mib 64 --mtp on --spec 3
```

### 4.6 自检两个关键 flag

```powershell
<install>\strata\engine-cuda12\strata.exe --help | findstr /C:"mtp-cpu-moe"
<install>\strata\engine-cuda12\strata.exe --help | findstr /C:"dry-multiplier"
```

两行都得有输出。上游原版编出来的二进制**没有**这两行。

---

## 5. 安装（自行编译 / 修改）

### 5.1 编译

```bash
# 1. 上游，切到这些补丁针对的 commit
git clone https://github.com/Niko1221/Strata
cd Strata && git checkout cd1daa4e          # "Merge upstream/main (0.1.43) into qwen36-35b-support"

# 2. 打补丁
git am /path/to/TinyStrata/patches/*.patch

# 3. 编译引擎（用上游自己的脚本；CUDA 12.8，sm_86）
cmd /c build-strata-cuda12.bat
cp build-cuda12/strata.exe engine-cuda12/strata.exe

# 4. 一次性：从 GGUF 建 pack
python setup.py --family qwen36 --model UD-IQ3_S
```

> **必读的部署坑**：`cmake --build` 只写 `build-cuda12/strata.exe`，
> 运行时读的是 `engine-cuda12/strata.exe` —— **不 `cp` 就等于没改**。

### 5.2 改代码

补丁里的改动都是小块的、有注释的：`src/core/mtp.cpp`（专家卸载）、
`sampler.hpp` / `sampler.cu`（DRY kernel）、`src/program/generate.cpp`（参数解析）、
`serve/`（autosave、日志时间戳）。重新生成补丁：

```bash
cd <install>/strata
git format-patch -q cd1daa4e..HEAD -o /path/to/TinyStrata/patches --no-signature
```

### 5.3 目录布局

默认布局（名字随意，下面用 `<install>` 表示启动器/驱动所在目录）：

```
<install>\
├── strata\                     上游检出，引擎在 strata\engine-cuda12\strata.exe
├── tools\strata-run.py         驱动（它的上一级就是 <install>）
├── configs\strata-qwen36-iq3s.example.json   复制成 strata-qwen36-iq3s.json
├── results\                    日志落这里
└── sessions\                   自动存盘的 .sess 文件（配 "slot_save_path"）

<models>\Qwen3.6-35B-A3B-MTP-GGUF\           GGUF（图片还要 mmproj-F32.gguf）
<packs>\qwen36-UD-IQ3_S\                    setup.py 建出的 pack
```

这套布局是**默认值，不是硬编码**。想换位置有三种办法：

| 办法 | 作用 |
|---|---|
| 环境变量 `STRATA_HOME` | 整个 `<install>` 根（配置/日志/会话都跟着走） |
| 环境变量 `STRATA_ROOT` | 单独指定上游检出目录（默认 `<install>\strata`） |
| 启动器菜单「关于 → 打开引擎目录」/ 首次「浏览…」 | 选一次就记进 `strata-launcher.ini` |

`<models>` / `<packs>` 写在配置模板里，用 `%STRATA_MODELS%` / `%STRATA_PACKS%` 占位
（见 `configs/README.md`）。

### 5.4 别的 NVIDIA 卡（例如 20 系）：自己编译，启动器照样能用

Release 的引擎只编了 **sm_86**。要在别的卡上跑（20 系 sm_75、40 系 sm_89、50 系 sm_120 …），
自己编一份就行 —— **启动器和引擎是模块化的**，启动器只管界面和参数，引擎换成谁都能接。

```bash
# 1) 用你的算力编（下面是常见几张卡的值）
#    RTX 20xx = 75   RTX 30xx = 86   RTX 40xx = 89   RTX 50xx = 120
cmake -S . -B build-mine -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75
cmake --build build-mine --target strata -j 6
mkdir -p engine-mine && cp build-mine/strata.exe engine-mine/strata.exe

# 2) 告诉启动器用这一份（两种方式，任选）
#    a) 环境变量
set STRATA_EXE=<你的目录>\engine-mine\strata.exe
#    b) 菜单「关于 → 选择引擎…」选一次，会记进 strata-launcher.ini（[ui] exe）
```

细节：

| 项 | 说明 |
|---|---|
| 算力值 | 启动器「关于」里会显示检测到的 `compute_cap`，并按它给出该用的 `-DCMAKE_CUDA_ARCHITECTURES=` 值（8.6 → 86，7.5 → 75） |
| 引擎名字 | 随便叫（`strata-sm75.exe` 也行），启动器只要求是个 `.exe` |
| CUDA 版本 | 12.x 都行（Release 用 12.8）；改 `build-strata-cuda12.bat` 里的路径即可 |
| 引擎换掉之后 | 参数、pack、会话缓存都不用动 —— pack 与服务端的交互与引擎版本无关 |
| 启动器检测到架构不符时 | 只在启动前给一条**提醒**（不是拦下）：告诉你当前卡是 X、该编什么参数 |

> 为什么不在启动器里内置多架构？一个 sm 架构的 kernel 表就要几十 MB，三四个架构会把
> 下载体积翻倍。编一份的成本是一次 `cmake --build`，比每次下载都多几十 MB 划算。
---

## 6. 来源（上游）与补丁改动

**TinyStrata 是 [Strata](https://github.com/Niko1221/Strata) 的衍生作品**（MIT，Copyright (c) 2026
Niko1221 及贡献者）。`LICENSE` 是上游原样，派生关系与免责声明见 [`NOTICE.md`](NOTICE.md)。

| | |
|---|---|
| 上游 | <https://github.com/Niko1221/Strata> |
| 补丁基线 | `cd1daa4e` — "Merge upstream/main (0.1.43) into qwen36-35b-support" |
| 基线来源分支 | `aflin/Strata` 的 `qwen36-35b-support`（PR #1402：Qwen3.6-35B-A3B 支持） |

### 6.1 三个补丁

| 补丁 | 改了哪里 | 效果（4 GB 实测） |
|---|---|---|
| [`0001-mtp-mtp-cpu-moe`](patches/0001-mtp-mtp-cpu-moe-the-draft-layer-s-256-experts-on-the.patch) | `src/core/mtp.cpp`、`src/program/generate.cpp`：新增 `--mtp-cpu-moe`，draft 专家走 CPU、跳过 graph capture | draft 层显存 **439 → 127 MiB**；decode 24.7 tok/s @65 K（接受 87 %）、18.6–21.5 tok/s @80 K |
| [`0002-sampler-DRY`](patches/0002-sampler-DRY-a-penalty-that-grows-with-the-length-of-.patch) | `sampler.hpp` / `sampler.cu` / `generate.cpp`：DRY 前置 kernel + 四个 `--dry-*` 参数，覆盖 greedy/sampled/split-merge 全路径 | 编码题：关闭时 2529 字 thinking / **答案 0 字**；`--dry-multiplier 1.5` 时 1737 字 + 正确函数 |
| [`0003-serve-setup-tools`](patches/0003-serve-setup-tools-session-autosave-log-timestamps-ch.patch) | `serve/autosave.py`（新）、`serve/server.py`、`setup.py`、`tools/strata_inspect.py`：会话自动存盘、日志时间戳、`--chat-template-file`、放开量化白名单 | 52 K token 恢复 **0.47 s**（替代 314 s）；save 380 ms / restore 143 ms；`--expert-cache 800` 让 prefill 快 27–45 % |

补丁作者是 `strata-4gb <strata-4gb@localhost>`；想署自己的名字，apply 后
`git commit --amend --reset-author` 即可。

---

## 7. 适配模型

| 模型 | 量化 | 大小 | 说明 |
|---|---|---|---|
| [**unsloth/Qwen3.6-35B-A3B-MTP-GGUF**](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF) | **UD-IQ3_S** | 15.3 GB | **本仓库所有数字都是在它上面测的**。推荐首选 |
| 同上 | UD-IQ4_XS | 18.2 GB | 4 GB 上也跑得起来，prefill 稍慢、质量略高 |
| 同上 | `mmproj-F32.gguf` | — | 需要图片输入（视觉）时才下 |

- 国内下载：把域名换成 `hf-mirror.com` 即可（`HF_ENDPOINT=https://hf-mirror.com`）。
- **MTP 层必须在 GGUF 里**（`blk.40`）。下载别的量化/别的来源之前，先按
  [`docs/GGUF-SELECTION-STANDARD.md`](docs/GGUF-SELECTION-STANDARD.md) 的三步判据验一遍：
  `qwen35moe` + `block_count 41` + 文件名带 MTP / `strata_inspect.py` 结尾打印
  `with an MTP layer`。
- **4 GB 卡上的参数**：`UD-IQ3_S` 用短模式即可（MTP 专家在显存）；**`UD-IQ4_XS` 这类更大的量化要把 MTP 专家放到 CPU**
  （界面上「mtp」选 `cpu`，或 `--mtp-cpu-moe 1`）：稠密权重更大，draft 层那 439 MiB 显存会让 prefill 抢不到缓冲
  （症状：`prefill ... out of memory`）。实测 IQ4_XS + `--mtp-cpu-moe` + ctx 20480 → 21 秒就绪，视觉也能起。
- **`--spec` 不省显存**：验证窗口的缓冲按 `kVerifyMaxT = 8` 一次预分配（`generate.cpp` 里算专家缓存时用的是
  `kVerifyMaxT`，不是 `--spec`）；它只决定「每轮提几个草稿」→ 接受率与速度。另外 suffix drafter 默认开，
  启动时会把 `--spec` 再加 2（上限 8），所以 `--spec 2` 实际跑的是 4。
- **配套 pack**：`UD-IQ3_S` 用 Release 里的 `pack-qwen36-UD-IQ3_S.zip`（43.7 MB）；
  其他量化用 `tools/make_pack.py` 现做（3 秒 / 65 MB）—— 详见 §4.3。
- 模型许可：Unsloth 的这份 GGUF 是 Apache-2.0；模型权重不在本仓库内。

---

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| [`docs/4GB-TUNING.md`](docs/4GB-TUNING.md) | 4 GB 调参全记录：每个参数为什么是这个值、测速协议（预热 → 交错 → 3 轮中位）、噪声量级（换实例 ±6 %） |
| [`docs/GGUF-SELECTION-STANDARD.md`](docs/GGUF-SELECTION-STANDARD.md) | 挑 GGUF 的硬性判据、危险信号、三步筛选流程 |
| [`launcher/strata-launcher.ahk`](launcher/strata-launcher.ahk) | 图形启动器（AHK v2，自带 `--selftest` / `--guismoke` / `--switchtest`） |
| [`tools/strata-run.py`](tools/strata-run.py) | 模式驱动：一条命令起短/长模式，带边界检查与日志 |
| [`tools/watch-loop.py`](tools/watch-loop.py) | 双源循环监控：引擎日志（LOOP-RECOVERY / DEGEN-TOKEN / THINK-ONLY）+ 客户端会话文件（重复工具调用、逐字重复推理） |
| [`tools/ab-modes.py`](tools/ab-modes.py) · [`tools/ab-prefill-fast.py`](tools/ab-prefill-fast.py) | A/B 测速：预热 + 交错 + 3 轮中位；prefill 用进度行 45 s 出结果 |

---

## 9. 其他

### 9.1 局限（提 issue 前先读）

- **decode 随上下文下降**：本卡 30 K 时 25 tok/s，79 K 时 18 tok/s。
- **客户端 compaction 是前缀复用的硬断点**：被 compact 的对话要整体重读一次 prompt
  （本机 37 K token 约 2 分钟）。所有做 token 前缀匹配的引擎都有这个问题。
- **工具调用循环是客户端问题，不是采样器问题。** 一个把同一个 `read` 调用重复 77 次的模型，
  温度、DRY、换量化都治不了 —— 需要客户端侧的守卫（`tools/watch-loop.py` 负责检测两类）。
- **K-quant 在这里不是免费的**：`Q4_K*`/`Q5_K*`/`Q6_K` 的 prompt 路径需要
  `-DSTRATA_MMQ_KQUANTS=ON` 重编，而每个新增 kernel 实例都是急切加载的，在 4 GB 卡上会为
  *每一个* 模型都吃掉显存。`Q2_K`/`Q3_K` 完全不在那个选项覆盖内。
- **单 GPU、单请求。** `--batch`、分层拆分、多卡都不与这些补丁组合（会话文件也会拒绝）。

### 9.2 许可证

**MIT**，与上游一致。`LICENSE` 是上游的原文；`patches/` 是我们对 MIT 代码的改动，
同样以 MIT 授权。模型权重不在本仓库，遵循其自身许可（Apache-2.0）。

本项目与 Strata 上游作者无隶属关系，也未被其背书。

### 9.3 反馈

开 issue 时请附上：`strata-run.py` 的完整启动参数、`--max-context` / KV / MTP 设置、
以及 `results/` 里对应的日志尾部（时间戳能直接对齐）。
