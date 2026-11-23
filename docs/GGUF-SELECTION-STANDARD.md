# Qwen3.6-35B-A3B 类 GGUF 的筛选标准（给本地 Strata 用）

本机：RTX 3050 Ti **4 GB** + i5-11400H + **32 GB** RAM，Strata `0.1.43`（含本地补丁）。
当前模型：`unsloth/Qwen3.6-35B-A3B-MTP-GGUF` 的 **UD-IQ3_S**（15.34 GB）。
目的：**在 HuggingFace 上判断一个 GGUF 能不能直接替换**，不用下载整包就能筛掉 90%。

---

## 一、参照坐标系（我们模型的真实元数据，逐项对齐）

用 `tools/gguf_reader.py` 从 `Qwen3.6-35B-A3B-UD-IQ3_S.gguf` 读出来的：

| 元数据键 | 值 | 含义 |
|---|---|---|
| `general.architecture` | **`qwen35moe`** | 引擎只认这个架构名 |
| `qwen35moe.block_count` | **41** | 40 层模型 + **1 层 MTP**（`blk.40`） |
| `qwen35moe.embedding_length` | **2048** | n_embd |
| `qwen35moe.expert_count` | **256** | 路由专家数 |
| `qwen35moe.expert_used_count` | **8** | 每 token 激活专家数（这就是 "A3B" 的来源） |
| `qwen35moe.expert_feed_forward_length` | **512** | 单专家 FFN 宽 |
| `qwen35moe.expert_shared_feed_forward_length` | **512** | 共享专家 FFN 宽 |
| `qwen35moe.attention.head_count` | **16** | Q 头 |
| `qwen35moe.attention.head_count_kv` | **2** | **GQA：2 个 KV 头**（决定 KV 体积） |
| `qwen35moe.attention.key_length` / `value_length` | **256 / 256** | 头维 |
| `qwen35moe.full_attention_interval` | **4** | **每 4 层一个全注意力，其余是 GDN（线性注意力）** → 10 attn + 30 GDN |
| `qwen35moe.ssm.conv_kernel` / `group_count` / `inner_size` / `state_size` / `time_step_rank` | **4 / 16 / 4096 / 128 / 32** | GatedDeltaNet 的形状 |
| `qwen35moe.rope.freq_base` | **1e7** | |
| `qwen35moe.rope.dimension_count` / `dimension_sections` | **64 / [11,11,10,0]** | 多模态 mrope 分段 |
| `qwen35moe.nextn_predict_layers` | **1** | **MTP 草稿层在同一个文件里** |
| `qwen35moe.context_length` | 262144 | 模型原生上限（我们用 81920） |
| `tokenizer.ggml.model` | **gpt2** | pack 需要 `vocab.json` / `merges.txt` / `token_type.json` / `chat_template.jinja` |

> 这套数是**整个 pack、专家 profile（10240 对）、draft 词表（40525 token）**的共同前提。
> 任何一项变了，就不是"换个量化"，而是"换一个模型"。

---

## 二、硬性判据（必须逐项相等，没有容差）

1. **`general.architecture == "qwen35moe"`**
   不是 `qwen3moe` / `qwen3next` / `qwen3` —— 那些走别的引擎路径，本机没有。
2. **文件里必须有 `qwen35moe.block_count` 这个键**。
   `setup.py` 就是用它判断"引擎支不支持这个模型"（`SMALL_ENGINE_MARK = b"qwen35moe.block_count"`）。
3. **`block_count = 41`** —— 即**必须带 MTP 层**。
   只有 40 层的版本**没有草稿层**：长模式直接失去 MTP，decode 会从 ~20 掉到 ~15 tok/s。
4. `embedding_length 2048` / `expert_count 256` / `expert_used_count 8` / `head_count 16` /
   `head_count_kv 2` / `key_length 256` / `full_attention_interval 4` / `ssm.*` 全部相等。
5. **分词器不变**（gpt2，词表 248320）：draft 词表 `draft_vocab_en.bin` 与专家 profile 都按它建。

---

## 三、量化白名单：**是"钉哈希的策展名单"，不是技术限制**

`setup.py` 只钉了两个文件的 sha256（`QWEN36_FILES`）：

```
Qwen3.6-35B-A3B-UD-IQ4_XS.gguf   18,209,036,576 B
Qwen3.6-35B-A3B-UD-IQ3_S.gguf    15,346,432,288 B
```

`gguf_unsupported()` 只要文件名里的量化名不在这个名单里就**拒绝**，但：
- **sha256 校验只对已钉的文件做**（`if s.name in fam.get("sha256", {})`）→ 未钉的文件直接跳过校验
- **引擎与 pack 与量化无关**：专家 blob 原样复制；原生 CPU 内核没覆盖的类型会**回退到 ggml-cpu 的 dot**
- 所以"不能跑"其实是"没人替你测过"

### 上游/PolyStrata 都放开了

| 来源 | Qwen3.6-35B-A3B 支持的量化 |
|---|---|
| **我们 0.1.43（原）** | UD-IQ3_S、UD-IQ4_XS（只这两个） |
| **上游 0.2.7**（`docs/AI_REFERENCE.md`） | **UD-Q4_K_XL、UD-Q6_K_XL、Q8_0** |
| **PolyStrata 0.2.x**（`docs/BACKENDS.md`） | **UD-Q3_K_M、UD-Q2_K_XL、UD-Q4_K_M**（12.6–22.7 GB） |

### 本地已放开（2026-11-20 补丁，`setup.py`）

已加入三个同 family 的 i-quant，**无需重编引擎**：

| `--model` | 文件 | 大小 | 说明 |
|---|---|---:|---|
| **`Qwen3.6-UD-IQ3_XXS`** | UD-IQ3_XXS | **14.1 GB** | 比现在用的 IQ3_S 小 1.2 GB，RAM 余量更多 |
| `Qwen3.6-UD-IQ2_M` | UD-IQ2_M | 11.9 GB | 更小，质量换内存 |
| `Qwen3.6-UD-IQ2_XXS` | UD-IQ2_XXS | 11.8 GB | 最小档，质量下降明显 |

用法：`python setup.py --family qwen36 --model UD-IQ3_XXS`
（未钉哈希 → 下载后不校验 sha256；要钉就把它加进 `QWEN36_FILES`）

### 各量化类别的**真实**技术门槛

| 类别 | 例子 | 能否本地跑 | 代价 |
|---|---|---|---|
| **i-quant（IQ1/IQ2/IQ3/IQ4）** | UD-IQ3_S / IQ3_XXS / IQ2_M / IQ4_XS / IQ4_NL | ✅ **直接能跑**（原生 AVX-512 内核，或回退 ggml-cpu） | 无需重编 |
| **K-quant Q4_K / Q5_K / Q6_K** | UD-Q4_K_S/M、UD-Q6_K_XL | ⚠️ 需用 **`-DSTRATA_MMQ_KQUANTS=ON`** 重编（prompt 的 MMQ 内核） | 且这些文件 **21–38 GB**，32 GB 机器吃紧；CMake 注释警告多加载的 kernel 会**永久占显存**（少专家槽） |
| **K-quant Q2_K / Q3_K** | UD-Q2_K_XL、UD-Q3_K_M/X_L | ❌ **该选项不覆盖**（只到 Q4_K/Q5_K/Q5_1/Q6_K） | prompt 路径会走慢速回退 |
| **MXFP4_MOE** | MXFP4_MOE 22.2 GB | ❌ 无对应内核 | 跳过 |
| **Q8_0** | 37.8 GB | ❌ 太大 | 跳过 |

### 全量清单（unsloth MTP 仓库，实测文件大小）

```
11.4 GB  UD-IQ1_M      11.8 GB  UD-IQ2_XXS   11.9 GB  UD-IQ2_M
12.6 GB  UD-Q2_K_XL    14.1 GB  UD-IQ3_XXS   15.3 GB  UD-IQ3_S   ← 现在用的
17.1 GB  UD-Q3_K_M     17.2 GB  UD-Q3_K_XL   18.2 GB  UD-IQ4_XS
18.5 GB  UD-IQ4_NL     21.4 GB  UD-Q4_K_S    22.2 GB  MXFP4_MOE
22.7 GB  UD-Q4_K_M     37.8 GB  Q8_0
```

### 本机的取舍（32 GB RAM / 4 GB VRAM）

- **想更省内存** → `UD-IQ3_XXS`（14.1 GB，i-quant，可直接跑）
- **想要更高质量** → `UD-IQ4_XS`（18.2 GB，已钉，官方推荐档）
- **K 量化不划算**：能跑的那几档都 ≥21 GB，而 4 GB 卡的 decode 由"专家从 RAM 读"主导，块更大只会更慢

---

## 四、危险信号（看到就别下）

| 信号 | 为什么 |
|---|---|
| `general.architecture` 不是 `qwen35moe` | 引擎不认 |
| `block_count = 40`（无 `nextn_predict_layers`） | **没有 MTP 草稿层**，长模式 speed 掉一档 |
| `head_count_kv` / `key_length` / `full_attention_interval` 变了 | KV 体积与 attention 布局变了，pack 重建都不一定行 |
| `ssm.*` 变了 | GDN（30 层线性注意力）形状变了，`native_gdn` 内核不匹配 |
| 词表 ≠ 248320，或 merge/重训分词器 | draft 词表、专家 profile、chat 模板全失效 |
| 第三方**重新量化**（requant of requant） | i-quant 的块布局可能被破坏；setup 的白名单就是防这个 |
| "uncensored" / "abliterated" / 自建 merge | 权重大改，几何没变但质量不可预期（能跑，不是"标准件"） |
| 分片数 > 1（`-00001-of-0000N`） | 本机 pack 流程按单文件走，多分片要额外处理 |
| 只有 `Q4_K_M`/`Q5_K_M` 等 K 量化 | 白名单外 |

**可以接受的衍生版**：**Ornith-1.5-35B-A3B**（同架构、同 tokenizer、同 profile）—— `setup.py` 里就
单独有一条 `ornith` 模型条目，是官方支持的"另一个模型"。

---

## 五、下载前 3 步（不下载权重）

### 第 1 步：看 HF 页面的 `config.json`（原版仓库）

```
architectures: ["Qwen3_5MoeForConditionalGeneration"]   # 或类似
num_hidden_layers: 40        hidden_size: 2048
num_experts: 256             num_experts_per_tok: 8
num_attention_heads: 16      num_key_value_heads: 2
head_dim: 256                full_attention_interval: 4
nextn_predict_layers: 1      ← 关键：=1 才有 MTP
```

任何一项对不上 → 跳过。

### 第 2 步：看 GGUF 仓库的文件名与 README

- 仓库名里带 **`MTP`**（如 `Qwen3.6-35B-A3B-MTP-GGUF`）
- 文件名是 `Qwen3.6-35B-A3B-UD-IQ3_S.gguf` 这种**单文件**
- README 里若写 "MTP layer included" / "with the MTP draft layer" → 加分

### 第 3 步：下载后（或用 `hf` 只取元数据）跑我们自己的检查

```bash
# 一行判定：架构、几何、量化构成、MTP 是否在位
D:/dev/strata/.venv/Scripts/python.exe D:/dev/strata/tools/strata_inspect.py <candidate.gguf>
```

合格的输出长这样（我们现有模型的真实输出）：

```
=== Qwen3.6-35B-A3B-UD-IQ3_S ===
total 15.34 GB, 35.51 B weights, 3.46 bits/weight overall
  routed experts   33.02B  13.20 GB  3.20  IQ2_S 51%, IQ4_XS 40%, Q6_K 5%, ...
  attention        1.05B   0.87 GB  6.61  Q6_K 97% ...
  MTP / nextn      0.01B   0.01 GB  8.50  Q8_0 100%        ← 必须在
Strata: architecture qwen35moe: its geometry passes the engine's checks
        (40 layers, 2048 wide, 256 experts, 8 a token, with an MTP layer)
```

最后那行 **"with an MTP layer"** 是最关键的一句。

---

## 六、换模型的完整流程（确认合格之后）

1. **备份**（模板 / INI / 当前 pack 路径）：`D:\dev\backup-<date>-<tag>\`
2. 下载 GGUF 到 `E:\models\...`（**不要**覆盖现有文件）
3. 用 `setup.py` 建新的 pack（**新目录名**，如 `qwen36-UD-IQ4_XS`）
4. 复制模板改 `--pack` / `--native` 两条路径，`--base` 指过去（启动器「模型」下拉会列出来）
5. `--check` 先看配置，再起引擎看三条日志：
   - `model architecture qwen35moe: 40 layers ...`（几何）
   - `mtp: draft layer loaded from the model file`（MTP 在位）
   - `expert cache ... slots`（显存够）
6. `strata-launcher.ahk --selftest`：88 OK / 0 FAIL
7. A/B 测速时**必须预热 + 交错 + 每臂 ≥4 实例**（噪声 ±6%，见 HANDOFF §33.3）

---

## 七、一句话总结

> **只认 `qwen35moe` + `block_count 41`（带 MTP）+ 量化 ∈ {UD-IQ3_S, UD-IQ4_XS}。**
> 其余项（2048 宽 / 256 专家 / 8 选 / 16 Q 头 / 2 KV 头 / 每 4 层全注意力 / ssm 128·4096·16·4·32）
> 必须逐项相等。**先在 HF 上看 `config.json` 和 `nextn_predict_layers`，再决定要不要下载。**
