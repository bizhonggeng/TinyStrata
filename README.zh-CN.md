# TinyStrata

[简体中文](README.zh-CN.md) | [English](README.md)

目标：在 4G VRAM 显卡中快速、高质量、稳定的运行 MoE 模型（比如 Qwen3.6-35B-A3B）。

**Goal:** run MoE models (for example **Qwen3.6-35B-A3B, 256 experts, 8 per token**) fast, with high
quality and stable output, on a **4 GB VRAM** card — with a long context that is actually usable.

**TinyStrata** 是 [Strata](https://github.com/Niko1221/Strata)（MIT）的补丁版，只瞄准上面这一个目标。

上游在 8–12 GB 显卡上跑这个模型没问题。到 4 GB 就不行了：光 draft 层就和 80 K 上下文挤不下，
而且解码器有两个我们实际踩到的失效模式（逐字重复的推理循环、内存吃紧时被丢弃的 parked 会话）。
TinyStrata 就是这三个修复，外加用来量化它们的启动器和测速脚本。

这里的一切都是针对上游的补丁 —— **不含模型、不含 pack。** 预编译的 `strata.exe`
（CUDA 12.8、sm_86）挂在 [Releases](https://github.com/bizhonggeng/TinyStrata/releases/latest)，同一页给出 sha256。

## 改了什么

| 补丁 | 作用 | 实测效果（RTX 3050 Ti 4 GB + i5-11400H + 32 GB） |
|---|---|---|
| `0001-mtp-cpu-moe` | MTP draft 层的 256 个路由专家搬到主机内存、跑在 CPU 上（`--mtp-cpu-moe`）；CPU 路径跳过 CUDA graph 捕获 | draft 层显存 **439 → 127 MiB**，这才让 `--max-context 81920` 保得住 MTP。decode 24.7 tok/s @65 K（draft 接受 87 %），18.6–21.5 tok/s @80 K（88–89 %） |
| `0002-dry-sampler` | 把 llama.cpp 的 **DRY** 采样器做成 logits 前置 kernel：惩罚随 *重复序列* 长度增长，而不是随 token 频次 | 默认关闭（逐位不变）。`--dry-multiplier 1.5` 时，一道"烧了 700 token 静默 thinking、答案 0 字"的编码题产出了正确函数 |
| `0003-serve-setup-tools` | 会话自动存盘（parked 会话的磁盘兜底）、每行日志带 `HH:MM:SS`、`--chat-template-file`、多三个可选 i-quant | 52 K token 对话 **0.47 s** 恢复，替代 314 s 的重读；那个量化白名单是"钉了 sha256 的策展名单"，不是格式限制 |

## 数字

两个模式，都在本机实测（交错运行、三轮取中位、每轮前预热 —— 协议见 `docs/4GB-TUNING.md`）：

| | 短模式 | 长模式 |
|---|---|---|
| `--max-context` | 20480 | **81920** |
| KV | `k8v4`，全驻留 | `k8v4`，全驻留 |
| MTP | 开，专家**在 GPU**（`--spec 3`） | 开，专家**在 CPU**（`--mtp-cpu-moe 1`，`--spec 2`） |
| `--vram-reserve-mib` | 64 | 64 |
| 能启动的最大上下文 | 39936 | 81920 |
| decode | ~32–36 tok/s | ~18 tok/s @79 K，~25 tok/s @30 K |
| prefill | ~250 tok/s | **153.8 tok/s @79 K** |

同一条 79 K prompt、同一台机器，对比 llama.cpp（b11382）跑同族模型的 `Q4_K_M`（`--spec-type
draft-mtp`、`-cth/-ctv q8_0`、`-ncmoe 999`）：

| | TinyStrata（UD-IQ3_S，3.46 bit/w） | llama.cpp（Q4_K_M，5.19 bit/w） |
|---|---:|---:|
| prefill @79 K | **153.8 tok/s** | 103.3 tok/s |
| decode @79 K（3 轮中位） | **18.00 tok/s** | 12.35 tok/s |
| draft 接受率 | 71–78 % | 65–78 % |

两个速度的比值（decode 1.46、prefill 1.49）几乎正好等于权重大小之比（5.19 / 3.46 = 1.50）：这个
尺寸下解码是**搬运字节数**问题，所以更小的量化赢，i-quant 的解码路径没有额外代价。

## 要求

- **4 GB 显存**（在 RTX 3050 Ti Laptop、sm_86 上编译和实测），CUDA 12.8，Windows。
- **32 GB 内存** —— 专家就住在那里（UD-IQ3_S 约 12 GiB）。
- Python 3.11 虚拟环境 + `cmake`/`ninja` 用来编译引擎（上游的 `START-HERE.bat` 会建）。
- 模型：`unsloth/Qwen3.6-35B-A3B-MTP-GGUF` —— **UD-IQ3_S**（15.3 GB，本文数字用的就是它）
  或 UD-IQ4_XS（18.2 GB）。MTP 层必须在文件里（`blk.40`）；换别的量化之前先读
  `docs/GGUF-SELECTION-STANDARD.md`。

## 安装

也可以跳过第 3 步，直接用 [Releases](https://github.com/bizhonggeng/TinyStrata/releases/latest) 里的 `strata.exe`（CUDA 12.8、sm_86）。
注意补丁 1–2 是引擎 C++ 改动，所以**打补丁之前**编出来的上游二进制没有
`--mtp-cpu-moe` 和 `--dry-multiplier`。

```bash
# 1. 上游，切到这些补丁针对的 commit
git clone https://github.com/aflin/Strata
cd Strata && git checkout cd1daa4e          # "Merge upstream/main (0.1.43) into qwen36-35b-support"

# 2. 打补丁
git am /path/to/TinyStrata/patches/*.patch

# 3. 编译引擎（用上游自己的脚本；CUDA 12.8，sm_86）
cmd /c build-strata-cuda12.bat
cp build-cuda12/strata.exe engine-cuda12/strata.exe

# 4. 一次性：从 GGUF 建 pack（写出专家 pack + profile）
python setup.py --family qwen36 --model UD-IQ3_S
```

然后把 `configs/strata-qwen36-iq3s.example.json` 复制成 `D:\dev\strata-qwen36-iq3s.json`，
改掉里面的 `--pack` / `--native` / `--mtp` / `--expert-profile` 路径，再启动某个模式：

```bash
# 长模式（80 K，MTP 专家在 CPU）—— 本仓库讲的就是这个模式
python tools/strata-run.py --tag long --ctx 81920 --kv k8v4 --vram-reserve-mib 64 \
    --mtp on --mtp-cpu-moe on --spec 2 --thinking on --preserve-thinking on

# 短模式（20 K，MTP 专家在 GPU）
python tools/strata-run.py --ctx 20480 --kv k8v4 --vram-reserve-mib 64 --mtp on --spec 3
```

`launcher/strata-launcher.ahk` 是套在同样两个模式上的 AutoHotkey v2 图形界面（参数网格、
模型/GGUF/mmproj 选择器、视觉、chat 模板文件、运行状态、日志尾部）。`--selftest` 跑它自带的检查。

## 目录假设

脚本假设下面这个布局；换布局只要改两个常量：`tools/strata-run.py` 顶部和启动器里的 `DEV`，以及 `ROOT`。

```
D:\dev\
├── strata\                     上游检出，引擎在 strata\engine-cuda12\strata.exe
├── tools\strata-run.py         驱动
├── configs\strata-qwen36-iq3s.example.json   复制成 strata-qwen36-iq3s.json 并改路径
├── results\                    日志落这里
└── sessions\                   自动存盘的 .sess 文件（配 "slot_save_path"）

E:\models\unsloth\Qwen3.6-35B-A3B-MTP-GGUF\   GGUF（图片还要 mmproj-F32.gguf）
E:\Strata-data\packs\qwen36-UD-IQ3_S\         setup.py 建出的 pack
```

## 局限（提 issue 前先读）

- **pi 的 compaction 是前缀复用的硬断点**：被 compact 的对话要整体重读一次 prompt（本机 37 K
  token 约 2 分钟）。所有做 token 前缀匹配的引擎都有这个问题。
- **decode 随上下文下降**：本卡 30 K 时 25 tok/s，79 K 时 18 tok/s。
- **工具调用循环是客户端问题，不是采样器问题。** 一个把同一个 `read` 调用重复 77 次的模型，
  温度、DRY、换量化都治不了 —— 需要客户端侧的守卫。`tools/watch-loop.py` 两类都能检测
  （客户端会话文件里的重复工具调用、引擎日志里的逐字重复推理）。
- **K-quant 在这里不是免费的**：`Q4_K*`/`Q5_K*`/`Q6_K` 的 prompt 路径需要
  `-DSTRATA_MMQ_KQUANTS=ON` 重编，而每个新增 kernel 实例都是急切加载的，在 4 GB 卡上会为
  *每一个* 模型都吃掉显存。`Q2_K`/`Q3_K` 完全不在那个选项覆盖范围内。
- **单 GPU、单请求。** `--batch`、分层拆分、多卡都不与这些补丁组合（会话文件也会拒绝）。

## 许可

MIT，与上游一致。`patches/` 是我们对 MIT 代码的改动；`LICENSE` 是上游的。
精确基线以及改了什么见 `NOTICE.md`。
