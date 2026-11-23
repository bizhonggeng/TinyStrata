"""两模式 × STRATA_ROUTE_RESIDENT 的交错 A/B。

用法: python ab-modes.py <mode> <tokens> <arms>
  mode   : short | long       （参数与 strata-launcher.ahk 的 ModePreset 一致）
  tokens : prompt 目标 token 数
  arms   : 逗号分隔的 arm 名，如 base,r2,base,r2
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

def _home() -> Path:
    env = os.environ.get("STRATA_HOME") or os.environ.get("TINYSTRATA_HOME")
    if env:
        return Path(os.path.expandvars(env)).expanduser()
    here = Path(__file__).resolve().parent
    return here.parent if here.name.lower() == "tools" else here


DEV = _home()
PY = str(DEV / "strata" / ".venv" / "Scripts" / "python.exe")
URL = "http://127.0.0.1:1339/v1/chat/completions"
HEALTH = "http://127.0.0.1:1339/health"

# 与 strata-launcher.ahk 的 ModePreset 一致
MODES = {
    "short": dict(tag="short", ctx="20480", spec="3", cpu_moe=None),
    "long": dict(tag="long", ctx="81920", spec="2", cpu_moe="on"),
}

ARMS = {
    "base": {},
    "r05": {"STRATA_ROUTE_RESIDENT": "0.5"},
    "r1": {"STRATA_ROUTE_RESIDENT": "1.0"},
    "r2": {"STRATA_ROUTE_RESIDENT": "2.0"},
    "r5": {"STRATA_ROUTE_RESIDENT": "5.0"},
    "adapt": {"STRATA_ADAPT_LAG": "2", "STRATA_ADAPT_NOWAIT": "1"},
    # P2 验证：引擎默认走标量（iq_avx512.cpp: gather 是 opt-in）
    "g1": {"STRATA_IQ_GATHER": "1"},                      # 强制 AVX-512 grid gather
    "g0": {"STRATA_IQ256_GATHER": "0"},                   # 强制 AVX2 标量（本机默认已是）
    "gpref": {"STRATA_IQ_PREFETCH": "0"},                 # 关软件预取作对照
}

TOKENS = 12000


def log_path(mode):
    tag = MODES[mode]["tag"]
    return f"{DEV}/results/strata-qwen36-{tag}-server.log"


def kill_engine():
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-CimInstance Win32_Process -Filter \"Name='strata.exe'\" | "
                    "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], capture_output=True)
    time.sleep(4)


def start_engine(mode, env_extra):
    m = MODES[mode]
    env = os.environ.copy()
    env.update(env_extra)
    cmd = [PY, "-X", "utf8", f"{DEV}/tools/strata-run.py",
           "--tag", m["tag"], "--ctx", m["ctx"], "--kv", "k8v4",
           "--vram-reserve-mib", "64", "--mtp", "on", "--spec", m["spec"],
           "--thinking", "on", "--preserve-thinking", "on"]
    if m["cpu_moe"]:
        cmd += ["--mtp-cpu-moe", m["cpu_moe"]]
    out = open(f"{DEV}/scratch/kvtest/bench-{mode}.out", "w")
    subprocess.Popen(cmd, cwd=DEV, env=env, stdout=out, stderr=subprocess.STDOUT)
    for _ in range(180):
        time.sleep(2)
        try:
            with urllib.request.urlopen(HEALTH, timeout=3) as r:
                if json.loads(r.read()).get("status") == "ok":
                    return
        except (urllib.error.URLError, OSError):
            pass
    raise RuntimeError("engine did not become healthy")


def prompt_text():
    unit = "这是一段用于基准测试的固定填充文本，内容每次都完全一致，以便让引擎读到的 token 完全相同。"
    return unit * max(1, TOKENS // len(unit) * 2)


def ask(mode, max_tokens):
    body = {"model": "qwen3.6-35b-a3b-ud-iq3_s",
            "messages": [{"role": "user", "content": prompt_text() + "\n\n请用三句话总结上面这段文字。"}],
            "max_tokens": max_tokens, "temperature": 0.6, "top_p": 0.95, "top_k": 20}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3600) as r:
        return json.loads(r.read())


def last_done(mode):
    try:
        with open(log_path(mode), "r", encoding="utf-8", errors="replace") as f:
            for line in reversed(f.readlines()[-80:]):
                m = re.search(r"done: (\d+) tokens in .*?\(([\d.]+) tok/s\).*?expert cache ([\d.]+)% hit", line)
                if m:
                    return float(m.group(2)), float(m.group(3))
    except OSError:
        pass
    return None, None


def measure(mode, arm):
    kill_engine()
    start_engine(mode, ARMS[arm])
    ask(mode, 4)                     # 预热：prompt 进缓存 + 自适应专家层稳定
    time.sleep(2)
    # 同一引擎内测 3 次（prompt 全命中，纯 decode），取中位数降噪声
    decs, hits, looped = [], [], False
    for _ in range(3):
        t0 = time.time()
        d = ask(mode, 192)
        dt = time.time() - t0
        dec, hit = last_done(mode)
        u = d.get("usage", {})
        content = d["choices"][0]["message"].get("content") or ""
        if len(content) > 100 and content[-40:] in content[:-40]:
            looped = True
        if dec:
            decs.append(dec)
        if hit:
            hits.append(hit)
        time.sleep(1)
    decs.sort()
    med = decs[len(decs) // 2] if decs else None
    hitmed = sorted(hits)[len(hits) // 2] if hits else None
    print(f"  [{mode}/{arm:5s}] prompt={u.get('prompt_tokens')} reused={u.get('prompt_tokens_details',{}).get('cached_tokens')} "
          f"decode={decs} 中位={med} tok/s experthit={hitmed}%{'  ⚠️循环' if looped else ''}", flush=True)
    return med


if __name__ == "__main__":
    mode = sys.argv[1]
    TOKENS = int(sys.argv[2])
    arms = sys.argv[3].split(",")
    print(f"=== {mode} 模式，目标 prompt ≈{TOKENS} token ===", flush=True)
    res = {}
    for a in arms:
        d = measure(mode, a)
        res.setdefault(a, []).append(d)
    print("\n=== 汇总 ===")
    for k, v in res.items():
        vals = [x for x in v if x]
        if vals:
            print(f"  {k:6s} {vals}  均值 {sum(vals)/len(vals):.1f} tok/s")
