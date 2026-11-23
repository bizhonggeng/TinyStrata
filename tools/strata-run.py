#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Strata 一键启动驱动（由 D:\\dev\\run-strata-qwen36.bat 调用）。

做四件事：
  1. 以 D:\\dev\\strata-qwen36-iq3s.json 为模板，按参数改写出一份运行配置
     D:\\dev\\strata-qwen36-run.json —— 上下文 / KV / reserve / 端口 / CORS / draft 子集都落在这里；
  2. 清掉上一次残留的 strata.exe 与 serve/server.py（否则显存和端口会冲突）；
  3. 起内存护栏（2 s 采样；系统内存余量 < 500 MB 就杀引擎。显存不设限：这些模型按设计会把卡吃满）；
  4. 前台跑 serve/server.py —— 关掉窗口（或 Ctrl+C）就等于停掉模型。

本机实测边界（4 GB 卡，en 草稿子集；见 results/strata-ctx-ceiling.md 与 STRATA-LOOP-DECODE-FINDINGS.md §11）：
  k8v4 + MTP on           : 21504 能启动 / 22528 被拒（reserve 256）
  q4_0 + MTP on           : 28672 能启动 / 29696 被拒（reserve 256）
  k8v4 + 全常驻 + MTP off  : 81920 能启动 / 90112 被拒（reserve 64）—— 长模式用这档
  k8v4 + 流式 32768 + MTP off : 147456 能启动 / 163840 被拒
其它 KV 档位未实测，超了引擎会自己拒绝并说明差多少 MiB。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import threading
from pathlib import Path

import psutil

def _resolve_home() -> Path:
    """Where the TinyStrata install lives.

    Order: $STRATA_HOME -> the directory above this script (tools/../) -> cwd.
    Nothing here is hard-coded to a developer machine.
    """
    env = os.environ.get("STRATA_HOME") or os.environ.get("TINYSTRATA_HOME")
    if env:
        return Path(os.path.expandvars(env)).expanduser().resolve()
    here = Path(__file__).resolve().parent
    return here.parent if here.name.lower() == "tools" else here


DEV = _resolve_home()                                   # config / logs / sessions
ROOT = Path(os.path.expandvars(os.environ.get("STRATA_ROOT", str(DEV / "strata")))).resolve()
PY = Path(os.path.expandvars(os.environ.get("STRATA_PYTHON", str(ROOT / ".venv" / "Scripts" / "python.exe"))))
BASE_CFG = Path(os.path.expandvars(os.environ.get("STRATA_CONFIG", str(DEV / "strata-qwen36-iq3s.json"))))
RUN_CFG = DEV / "strata-qwen36-run.json"
GUARD = Path(os.environ.get("STRATA_GUARD", str(DEV / "tools" / "strata-ram-guard.py")))
RESULTS = DEV / "results"
ENGINE_LOG = RESULTS / "strata-qwen36.log"
SERVER_LOG = RESULTS / "strata-qwen36-server.log"
GUARD_LOG = RESULTS / "strata-ram-guard.log"
SERVER_PY = ROOT / "serve" / "server.py"

# 本机实测（能启动的最大值, 首个拒绝值）
MEASURED = {"k8v4": (21504, 22528), "q4_0": (28672, 29696)}
# 开了 --kv-resident（KV 流式）或关了 MTP 之后，显存账完全不同：按 (kv, resident, mtp) 查这张表
MEASURED_STREAM = {
    ("k8v4", 20480, "on"): (20480, 24576),     # 保 MTP + k8v4 全流式：没有余量，24576 就拒
    ("k8v4", 0, "on"): (39936, 40960),          # 全常驻 + MTP（reserve 64）：短模式实测 38912 可启动
    ("k8v4", 0, "on_cpumoe"): (81920, 90112),   # 同上 + --mtp-cpu-moe（专家上 CPU）：长模式实测 81920 可启动
    ("q4_0", 20480, "on"): (32768, 40960),     # 保 MTP 的折中：Q4_0 K + 全流式
    ("k8v4", 32768, "off"): (147456, 163840),  # 方案 C：弃 MTP + 全流式（引擎下限 20480，此处用 32768）
    ("k8v4", 0, "off"): (81920, 90112),        # 全常驻 KV + MTP off（reserve 64）：长模式现在用的就是这个
}
KV_CHOICES = ["k8v4", "q4_0", "int8", "fp16"]
DRAFT = {"cjk": "draft_vocab.bin", "en": "draft_vocab_en.bin",
         "cyrillic": "draft_vocab_cyrillic.bin", "fr": "draft_vocab_fr.bin"}


class _Stamped:
    """逐行给输出加 HH:MM:SS（驱动日志用；只缓冲没遇到换行的尾巴）。"""

    def __init__(self, stream):
        self._s, self._buf, self._lock = stream, "", threading.Lock()

    def write(self, data):
        if not data:
            return 0
        with self._lock:
            self._buf += data
            while "\n" in self._buf:
                line, self._buf = self._buf.split("\n", 1)
                self._s.write(time.strftime("%H:%M:%S ") + line + "\n")
            self._s.flush()
        return len(data)

    def flush(self):
        with self._lock:
            if self._buf:
                self._s.write(time.strftime("%H:%M:%S ") + self._buf)
                self._buf = ""
            self._s.flush()

    def __getattr__(self, name):
        return getattr(self._s, name)


def install_timestamps():
    for name in ("stdout", "stderr"):
        cur = getattr(sys, name)
        if not isinstance(cur, _Stamped):
            setattr(sys, name, _Stamped(cur))


def parse() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Strata one-click driver")
    ap.add_argument("--ctx", type=int, default=12288, help="上下文长度（引擎 --max-context）")
    ap.add_argument("--kv", default="k8v4", choices=KV_CHOICES, help="KV 量化：k8v4 最省/最快之一，q4_0 能给更长上下文")
    ap.add_argument("--vram-reserve-mib", type=int, default=256, help="引擎给别的程序留的显存（默认 700，小卡上会拒绝启动）")
    ap.add_argument("--port", type=int, default=1339)
    ap.add_argument("--cors", default="*", help="'*' = 任意网页；逗号分隔的具体源；空串 = 关闭 CORS")
    ap.add_argument("--draft-vocab", default="en", choices=list(DRAFT), help="MTP 草稿头的 token 子集")
    ap.add_argument("--host", default=None, help="bench 在别的机器上时给 0.0.0.0")
    ap.add_argument("--api-key", default=None, help="设了 key 后 Host/Origin 2道门都关掉，客户端要带 Authorization")
    ap.add_argument("--vision-tokens", type=int, default=None,
                    help="每张图占用的上下文 token（默认 300；GPU 编码器可到 1024）")
    ap.add_argument("--native", default=None,
                    help="覆盖模板里的 --native（GGUF 路径）；换模型文件时用，pack 需与之匹配")
    ap.add_argument("--mmproj", default=None,
                    help="覆盖模板里的 vision.mmproj（视觉编码器权重）")
    ap.add_argument("--vision", default=None, choices=["off", "cpu", "gpu"],
                    help="图片编码器：off=不加载 / cpu=不占显存（推荐 4GB 卡）/ gpu=占 ~1.2GB 显存（默认: 保持模板的设置）")
    ap.add_argument("--no-guard", action="store_true", help="不起内存护栏")
    ap.add_argument("--check", action="store_true", help="只写配置并打印计划，不启动任何东西")
    ap.add_argument("--thinking", choices=["on", "off"], default="on", help="思考开关：off 等同于 reasoning_effort=none（在共享设置里）")
    ap.add_argument("--preserve-thinking", choices=["on", "off"], default="off", help="保留历史轮次思考：on 在共享设置里设置 preserve_thinking=true")
    ap.add_argument("--mtp", choices=["on", "off"], default="on", help="off = 不加载 MTP 草稿层（省 ~433 MiB 显存，代价是失去推测解码）")
    ap.add_argument("--spec", default=None, help="MTP/推测解码的验证窗口（模板默认 3）")
    ap.add_argument("--mtp-cpu-moe", default="off", choices=["off", "on", "1", "0"],
                    help="on = MTP 的路由专家放主机内存、CPU 算（省 312 MiB 显存，让 80K 上下文也能开 MTP；"
                         "代价是 draft 不走 CUDA Graph）")
    ap.add_argument("--kv-resident", type=int, default=0, help="KV 流式：显存常驻 N 格（引擎下限 20480），其余 K/V 放 pinned 内存；0 = 全部常驻显存")
    ap.add_argument("--tag", default="", help="日志/运行配置的文件名后缀，多个启动脚本并存时用来区分（如 long）")
    ap.add_argument("--chat-template", default=None,
                    help="chat 模板文件（覆盖 pack 里的 chat_template.jinja；不给=用 pack 自带的）")
    ap.add_argument("--base", default=None, help="模板配置路径（默认 strata-qwen36-iq3s.json）；换模型（如 UD-Q3_K_M）时指向另一份模板")
    ap.add_argument("--temperature", type=float, default=None, help="采样：默认温度（0=贪婪）。不给则不写配置的 sampling 块")
    ap.add_argument("--top-p", type=float, default=None, help="采样：默认 top_p")
    ap.add_argument("--top-k", type=int, default=None, help="采样：默认 top_k")
    ap.add_argument("--min-p", type=float, default=None, help="采样：默认 min_p")
    ap.add_argument("--presence-penalty", type=float, default=None, help="采样：presence_penalty")
    ap.add_argument("--repetition-penalty", type=float, default=None, help="采样：repetition_penalty")
    ap.add_argument("--dry-multiplier", type=float, default=None,
                    help="DRY 采样：重复序列的惩罚倍率（0=关；默认取模板里的值）")
    ap.add_argument("--dry-base", type=float, default=None, help="DRY：指数底（默认 1.75）")
    ap.add_argument("--dry-allowed-length", type=int, default=None, help="DRY：不惩罚的最短匹配长度（默认 2）")
    ap.add_argument("--dry-penalty-last-n", type=int, default=None, help="DRY：回看的 token 数（默认 64）")
    return ap.parse_args()


def base_cfg_path(a: argparse.Namespace) -> Path:
    return Path(a.base) if a.base else BASE_CFG


def _expand(obj):
    """Expand %VAR% / $VAR in every string of the loaded config.

    The shipped example config is written with placeholders such as
    %STRATA_ROOT%/engine-cuda12/strata.exe so that nothing in the repo points at a
    specific machine. Anyone can either edit the file or just set the variables.
    """
    if isinstance(obj, str):
        return os.path.expandvars(obj)
    if isinstance(obj, list):
        return [_expand(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _expand(v) for k, v in obj.items()}
    return obj


def build_cfg(a: argparse.Namespace, engine_log: Path) -> dict:
    cfg = _expand(json.loads(base_cfg_path(a).read_text(encoding="utf-8")))
    over = {"--max-context": str(a.ctx), "--kv": a.kv,
            "--vram-reserve-mib": str(a.vram_reserve_mib),
            "--mtp-draft-vocab": str(ROOT / "data" / DRAFT[a.draft_vocab])}
    # --mtp <file> 与 --mtp-draft-vocab <file> 成对出现：关 MTP 就把这两对一起摘掉（--spec 是原生 pack 必需，留着）
    drop = ("--mtp", "--mtp-draft-vocab") if a.mtp == "off" else ()
    if a.mtp == "off":
        over.pop("--mtp-draft-vocab", None)     # 否则下面"模板里没有的补上"会把它加回来
    if a.mtp_cpu_moe in ("on", "1"):
        over["--mtp-cpu-moe"] = "1"
    if a.spec is not None:
        over["--spec"] = str(a.spec)
    base, args, i, done = cfg.get("args", []), [], 0, set()
    while i < len(base):
        flag = base[i]
        if flag in drop:
            i += 2
            continue
        if flag in over and i + 1 < len(base):
            args += [flag, over[flag]]
            done.add(flag)
            i += 2
            continue
        args.append(flag)
        i += 1
    for flag, value in over.items():          # 模板里没有的补上
        if flag not in done:
            args += [flag, value]
    if a.kv_resident:
        args += ["--kv-resident", str(a.kv_resident)]
    if a.native:                                  # 换 GGUF：覆盖 --native，并同步 model_name
        if "--native" in args:
            args[args.index("--native") + 1] = a.native
        else:
            args += ["--native", a.native]
        cfg["model_name"] = Path(a.native).stem.lower().replace(".", "-")
    cfg["args"] = args
    if a.chat_template:                       # 模板覆盖：服务端读 cfg["chat_template_file"]
        cfg["chat_template_file"] = str(Path(a.chat_template).resolve())
    else:
        cfg.pop("chat_template_file", None)
    samp = dict(cfg.get("sampling") or {})     # 采样默认值（发给没带采样的客户端，如 code agent）
    for key, val in (("temperature", a.temperature), ("top_p", a.top_p), ("top_k", a.top_k),
                     ("min_p", a.min_p), ("presence_penalty", a.presence_penalty),
                     ("repetition_penalty", a.repetition_penalty),
                     ("dry_multiplier", a.dry_multiplier), ("dry_base", a.dry_base),
                     ("dry_allowed_length", a.dry_allowed_length),
                     ("dry_penalty_last_n", a.dry_penalty_last_n)):
        if val is not None:
            samp[key] = val
    if a.dry_multiplier is not None and a.dry_multiplier <= 0:      # 0 = 明确关掉
        samp.pop("dry_base", None)
        samp.pop("dry_allowed_length", None)
        samp.pop("dry_penalty_last_n", None)
    if samp:
        cfg["sampling"] = samp
    cfg["port"] = a.port
    cfg["log"] = str(engine_log)
    cfg["cors_origins"] = [o.strip() for o in a.cors.split(",") if o.strip()] if a.cors else []
    if a.host:
        cfg["host"] = a.host
    if a.api_key:
        cfg["api_key"] = a.api_key
    if a.vision is not None:
        if a.vision == "off":
            cfg.pop("vision", None)                 # 不加载编码器（省 CPU/RAM）
            cfg["args"] = [x for x in cfg["args"] if x != "--vision"]
        else:
            v = dict(cfg.get("vision") or {})
            if a.vision == "gpu":
                v["gpu"] = True                     # 编码器上卡（占 ~1.2 GiB 显存）
            else:
                v.pop("gpu", None)                   # CPU 编码器（不占显存）
            if a.mmproj:
                v["mmproj"] = a.mmproj
            v.setdefault("exe", str(ROOT / "engine-cuda12" / "strata-vision.exe"))
            v.setdefault("threads", 8)
            v.setdefault("max_tokens", 300)
            if a.vision_tokens is not None:
                v["max_tokens"] = max(1, a.vision_tokens)
            cfg["vision"] = v
    return cfg


def find_procs() -> dict:
    found = {"engine": [], "guard": []}
    for p in psutil.process_iter(["name", "cmdline"]):
        try:
            name = (p.info["name"] or "").lower()
            cmd = " ".join(p.info["cmdline"] or [])
            if name == "strata.exe" or "serve/server.py" in cmd or "serve\\server.py" in cmd:
                found["engine"].append(p)
            elif "strata-ram-guard.py" in cmd:
                found["guard"].append(p)
        except Exception:
            pass
    return found


def stop_engine() -> None:
    procs = find_procs()["engine"]
    if procs:
        for p in procs:
            try:
                p.kill()
            except Exception:
                pass
        print(f"[run] 已停掉残留进程 {len(procs)} 个（引擎/服务端）")
        time.sleep(3)


def main() -> int:
    a = parse()
    install_timestamps()
    global RUN_CFG, SERVER_LOG, ENGINE_LOG
    if a.tag:                                  # 多个启动脚本并存：日志/配置各用各的，互不覆盖
        RUN_CFG = DEV / f"strata-qwen36-{a.tag}-run.json"
        ENGINE_LOG = RESULTS / f"strata-qwen36-{a.tag}.log"
        SERVER_LOG = RESULTS / f"strata-qwen36-{a.tag}-server.log"
    if not PY.exists():
        print(f"[run] 找不到 venv python：{PY}\n      先在 {ROOT} 跑一次 START-HERE.bat 生成 .venv")
        return 1
    if not base_cfg_path(a).exists():
        print(f"[run] 找不到模板配置：{base_cfg_path(a)}")
        return 1

    cfg = build_cfg(a, ENGINE_LOG)
    RUN_CFG.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")

    cors = ", ".join(cfg["cors_origins"]) or "关闭"
    print(f"[run] 运行配置：{RUN_CFG}")
    print(f"[run]   ctx={a.ctx}  kv={a.kv}  resident={a.kv_resident or 'off'}  mtp={a.mtp}  reserve={a.vram_reserve_mib} MiB  "
          f"think={a.thinking}  preserve_think={a.preserve_thinking}  draft={a.draft_vocab}  port={a.port}  cors={cors}")
    stream = None
    if a.mtp_cpu_moe in ("on", "1") and a.kv_resident == 0 and a.mtp == "on":
        stream = MEASURED_STREAM.get(("k8v4", 0, "on_cpumoe"))   # 长模式：专家上 CPU，81920 实测可启动
    if stream is None:
        stream = MEASURED_STREAM.get((a.kv, a.kv_resident, a.mtp))
    if stream:
        ok, no = stream
        mark = "OK" if a.ctx <= ok else f"超过该模式实测边界 {ok}（引擎很可能拒绝）"
        print(f"[run]   本机实测边界（{a.kv} + resident {a.kv_resident} + mtp {a.mtp}）："
              f"{ok} 能启动 / {no} 被拒  -> 当前 {a.ctx} {mark}")
    elif a.kv in MEASURED:
        ok, no = MEASURED[a.kv]
        mark = "OK" if a.ctx <= ok else f"超过实测边界 {ok}（引擎很可能拒绝）"
        print(f"[run]   本机实测边界（{a.kv}）：{ok} 能启动 / {no} 被拒  -> 当前 {a.ctx} {mark}")
    else:
        print(f"[run]   {a.kv} 这一档未在本机实测过（k8v4=21504、q4_0=28672 是实测值）")
    if a.mtp == "off":
        print("[run]   注意：MTP 已关闭 —— 省下 ~433 MiB 显存换上下文，但失去推测解码（decode 会降）")
    if a.kv_resident:
        print(f"[run]   注意：KV 流式 —— 显存只常驻 {a.kv_resident} 格，其余 K/V 走 pinned 内存；"
              f"~8 KiB/token，150K ctx 约占 1.2 GiB 内存")
    print(f"[run]   OpenAI 端点  http://127.0.0.1:{a.port}/v1/chat/completions")
    print(f"[run]   Anthropic    http://127.0.0.1:{a.port}/v1/messages")
    print(f"[run]   网页聊天      http://127.0.0.1:{a.port}/")
    print("[run]   提醒：这是思考型模型，bench 的 max_tokens 给到 8192+，"
          "或在配置里加 reasoning_budget_tokens 给思考封顶")
    if a.check:
        print("[run] --check：只写配置，不启动。")
        return 0

    # 思考/保留思考开关：写共享设置文件（仅在非 check 模式下)
    shared_path = RUN_CFG.with_suffix('').with_suffix('.shared-settings.json')
    shared = {}
    if a.thinking == "off":
        shared["reasoning_effort"] = "none"
    if a.preserve_thinking == "on":
        shared["preserve_thinking"] = True
    if shared:
        shared_path.write_text(json.dumps(shared, indent=2), encoding="utf-8")
        print(f"[run] 已写共享设置文件：{shared_path} -> {shared}")
    else:
        if shared_path.exists():
            shared_path.unlink()
            print(f"[run] 已删除共享设置文件（使用默认行为）：{shared_path}")

    stop_engine()
    started_guard = False
    guard = None
    if not a.no_guard:
        if find_procs()["guard"]:
            print("[run] 内存护栏已在运行，复用")
        else:
            guard = subprocess.Popen([str(PY), "-X", "utf8", str(GUARD)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     cwd=str(DEV))
            started_guard = True
            print(f"[run] 内存护栏已启动（余量 <500 MB 即杀引擎，显存不设限）；日志 {GUARD_LOG}")

    env = dict(os.environ)
    env["PATH"] = cfg["lib_dirs"][0] + ";" + env.get("PATH", "")
    logf = open(SERVER_LOG, "w", encoding="utf-8")
    print("[run] 引擎启动中：约 12 GiB 专家进内存，约 12 秒；此窗口保持打开")
    proc = subprocess.Popen([str(PY), "-X", "utf8", str(SERVER_PY), "--engine", "strata",
                             "--config", str(RUN_CFG), "--port", str(a.port)],
                            cwd=str(ROOT), env=env, stdout=logf, stderr=subprocess.STDOUT)
    try:
        rc = proc.wait()
    except KeyboardInterrupt:
        proc.kill()
        rc = 130
    finally:
        logf.close()
        if started_guard and guard is not None:
            try:
                guard.kill()
                print("[run] 内存护栏已停止（随模型一起退出）")
            except Exception:
                pass
    print(f"[run] 服务端退出，code={rc}；引擎日志 {SERVER_LOG}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
