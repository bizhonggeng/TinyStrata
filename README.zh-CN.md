# TinyStrata

在 **4 GB 显存的笔记本显卡**上跑 **Qwen3.6-35B-A3B（MoE，3B 激活）**，Windows，
解码 33–43 tok/s：整模在一张卡 + 主机内存。它是 [Strata](https://github.com/Niko1221/Strata)（MIT）
的**补丁版**加一个启动器。

下面每个数字都在 §2 那台机器上实测，没有外推。

## 1. 包里的东西

| 组件 | 说明 |
|---|---|
| `strata.exe` | Strata 0.1.43 + 10 个补丁（§5）。64,747,008 B，`sha256 8b01900e…` |
| `TinyStrata-Launcher.exe` | 图形启动器：选 GGUF、点启动。1,504,768 B，**不加 UPX 壳** |
| `strata/ctl/` | 中间层：参数派生、显存上限/建议 ctx、预检机器码、日志解析 |
| `patches/` | 上述 10 个补丁，`git am` 可直接打 |

## 2. 实测性能

机器：**RTX 3050 Ti Laptop（4 GB 显存）**、i5-11400H、32 GB 内存、Windows 11、
CUDA 12.8、屏幕 1920×1080 @125%。
模型：**Qwen3.6-35B-A3B UD-IQ3_S**（14.29 GiB）+ 它自带的 MTP 头。
参数：`--kv k8v4`、`--spec 3`、`--expert-cache 800`、`--vram-reserve-mib 64`、
`--max-context 20480`、MTP 专家在显存。

### 解码速度 vs 上下文

每点：引擎只加载一次、开跑前显存为 0 MiB、先跑一次丢弃，再**生成 3 次×250 token 取中位**。

| prompt | 1 K | 4 K | 8 K | 12 K | 16 K | 20 K |
|---|---:|---:|---:|---:|---:|---:|
| 解码 tok/s | **43.1** | 40.9 | 40.0 | 38.8 | 37.0 | 33.7 |

- 1 K → 20 K 掉 **22%**（43.1 → 33.7），4 K 之后约每 1 K 掉 0.5 tok/s。
- 同批测到的 prefill：全新 ~4 K prompt **350 tok/s**；~19.6 K（78% 命中 prompt cache）224 tok/s。

### 专家槽位（"突然变慢"基本都是这个）

读引擎日志 `expert cache N slots`，`--max-context 20480` 下：

| MTP 专家在 | 槽位 | 显存 |
|---|---:|---:|
| 显存（`--mtp-cpu-moe 0`，短模式默认） | **657** | 0.77 GiB |
| 主机内存（`--mtp-cpu-moe 1`） | **915** | 1.07 GiB |

1 K–20 K 两种位置**差在 ±5% 内**（43.1 vs 43.5、40.0 vs 39.4、33.7 vs 34.9 tok/s），
所以多出来的 258 槽**不换来解码速度**，换来的是能开更大 `--max-context` 的余量。

解码掉到个位数 = 槽位被吃光了：常见原因是残留引擎或别的程序占着这张卡。
先看 `nvidia-smi --query-gpu=memory.used`。

### 其它实测数字

| 项目 | 值 | 怎么来的 |
|---|---|---|
| 启动器预检（全套检查） | **1.2 s** | 干净机器上给 `Preflight()` 计时 |
| 引擎启动 → HTTP 就绪 | ~15 s | 点启动到 `/props` 应答 |
| 本机这模型+这卡的 ctx 上限 | 109,568 | 启动器边界行，来自 `serve/prepare.py` |
| 建议 ctx（保 ~400 槽） | 16,384 | 同一行的 `ctx_suggested` |
| 每槽专家缓存 | 1.229 MiB | 12.0 GiB 专家 ÷ 10,240 槽 |
| 启动器自检 | 180 项全过 | `TinyStrata-Launcher.exe --selftest` |

## 3. 环境要求

- **显卡**：随包二进制按 compute 8.6 编译（RTX 30 系）。别的卡请自己编（§5），
  用你的 `-arch=sm_XX`，启动器会用它。
- **CUDA 12.x 运行库**（`cudart64_12.dll`、`cublas64_12.dll`），配置里的 `lib_dirs`
  指向 `…\CUDA\v12.8\bin`。
- **内存**：16 GB 起。专家占 12.0 GiB；可用内存低于 ~19 GB 时服务端会自己切 low-RAM 模式，
  解码降到约 1/3（实测 11.8 tok/s）。
- **Windows 10/11 x64**。便携包自带 CPython 3.11。

## 4. 怎么跑

1. 解压便携包，双击 `TinyStrata-Launcher.exe`。
2. **GGUF** → 选择… → 你的 `Qwen3.6-35B-A3B-UD-IQ3_S.gguf`。
3. 点 **启动**。首次启动会从 GGUF 生成引擎需要的 pack（43.7 MiB；12 GiB 专家仍留在 GGUF 里），
   几分钟；之后复用。
4. 窗口里有端口；浏览器开 `http://127.0.0.1:1339/`，或把任何 OpenAI 兼容客户端指向
   `http://127.0.0.1:1339/v1`。

启动器不往自己目录外写东西。`--pro` 打开双栏专业视图，`--selftest` 自检安装，
`--preflight` 打印它准备交给引擎的参数。

## 5. 补丁都改了什么

针对 Strata 0.1.43 的 10 个补丁，每条后面是当初触发它的实测：

1. `--mtp-cpu-moe` —— 草稿层的 256 个路由专家挪到主机 CPU 池：MTP 头从 439 MiB 显存降到
   127 MiB，这是 4 GB 卡能开 80 K 上下文的前提。
2. DRY 采样 —— 按重复片段长度增长的惩罚。本机实测代价在 run-to-run 波动内（±3%），
   换来的是不再陷入贪心采样时的整段重复。
3. `serve/setup` 工具、会话自动保存、日志时间戳。
4. `serve` 自动准备引擎需要的 pack（否则首次启动直接失败）。
5. `serve` 尊重配置里的 `sampling.dry_*`（以前被静默忽略）。
6. `serve` 补全模板里留作占位符的路径。
7. `strata pack <gguf> -X <out>` —— 引擎自己写 pack（不用 Python、不用 numpy），
   产物与 Python 打包器逐字节一致（IQ3_S 上验证）。
8. `serve` 校验 `--mtp` 就是当前跑的模型（草稿头不匹配是经典的"莫名变慢"）。
9. `serve` 按模型与本机情况预算主机内存分配（专家、停泊会话、护栏），不再用固定数字。
10. `strata/ctl` —— 启动器的中间层：`mtp_mode → --mtp/--mtp-cpu-moe/--spec`、从 capacity
    文件算显存上限与建议 ctx、预检提醒以机器码返回、从日志解析运行时数字。
    另外修：`--kv-resident 0` 表示"KV 全驻显存"（引擎默认），旧代码把 0 当成"流式"。

## 6. 限制（都是实测，不是估计）

- **4 GB 显存是硬约束。** `--max-context 20480` 时专家缓存 657 槽；再大就变少
  （109,568 是引擎拒绝启动的位置）。启动器会打印真实上限和"保 400 槽"的建议值。
- **计算能力是编进二进制的。** 非 sm_86 的卡会报 "no kernel image"，需要自己编。
- **长上下文要付代价**：20 K 比 1 K 慢 22%（见上表）。
- **Windows 二进制未签名。** 启动器已不再加 UPX 壳（之前因此被判成
  `Trojan:Win32/Wacatac.B!ml`），但未签名程序仍可能被拦；在意的话请自己从源码编。

## 7. 自己编译

```bat
git clone https://github.com/Niko1221/Strata && cd Strata
git checkout <这些补丁对应的上游提交>
git am ..\TinyStrata\patches\*.patch
:: 用上游脚本编译（CUDA 12.8、-arch=sm_86）
```

然后把启动器指向你的 `strata.exe`（菜单 *关于 → 选择引擎…*，会记在 `strata-launcher.ini`）。

## 8. 许可

Strata 是 MIT；本构建保留其 `LICENSE`/`NOTICE.md`。启动器与 `strata/ctl` 同为 MIT。
**模型权重不包含在内** —— 请从
[unsloth/Qwen3.6-35B-A3B-MTP-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF) 下载。

English: [README.md](README.md)。
