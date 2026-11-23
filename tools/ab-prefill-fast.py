"""用进度行实时测 prefill 速度（不用读完整个 prompt）。

起引擎 → 发 55K prompt → 每 1 s 读一行 "reading the prompt: X of Y tokens, Z s so far"
→ 取稳态段（跳过前几秒）的 tok/s → 断开请求。
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
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
LOG = f"{DEV}/results/strata-qwen36-pf-server.log"

N = int(sys.argv[1]) if len(sys.argv) > 1 else 55000
ARMS = sys.argv[2].split(",") if len(sys.argv) > 2 else ["mtpoff", "cpumoe"]
SECONDS = int(sys.argv[3]) if len(sys.argv) > 3 else 45

CFG = {
    "mtpoff": dict(tag="pf", spec=None, mtp=False, cpu_moe=None),
    "mtpgpu": dict(tag="pf", spec="3", mtp=True, cpu_moe=None),
    "cpumoe": dict(tag="pf", spec="2", mtp=True, cpu_moe="on"),
}


def kill():
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-CimInstance Win32_Process -Filter \"Name='strata.exe'\" | "
                    "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"], capture_output=True)
    time.sleep(4)


def start(arm):
    c = CFG[arm]
    cmd = [PY, "-X", "utf8", f"{DEV}/tools/strata-run.py", "--tag", "pf",
           "--ctx", "81920", "--kv", "k8v4", "--vram-reserve-mib", "64",
           "--thinking", "on", "--preserve-thinking", "on"]
    cmd += ["--mtp", "on", "--spec", c["spec"]] if c["mtp"] else ["--mtp", "off"]
    if c["cpu_moe"]:
        cmd += ["--mtp-cpu-moe", c["cpu_moe"]]
    out = open(f"{DEV}/scratch/kvtest/pf.out", "w")
    subprocess.Popen(cmd, cwd=DEV, stdout=out, stderr=subprocess.STDOUT)
    for _ in range(200):
        time.sleep(2)
        try:
            with urllib.request.urlopen(HEALTH, timeout=3) as r:
                if json.loads(r.read()).get("status") == "ok":
                    return
        except (urllib.error.URLError, OSError):
            pass
    raise RuntimeError("engine not healthy")


def fire():
    unit = "这是一段用于基准测试的固定填充文本，内容每次都完全一致，以便让引擎读到的 token 完全相同。"
    text = unit * max(1, N // len(unit) * 2)
    body = {"model": "qwen3.6-35b-a3b-ud-iq3_s",
            "messages": [{"role": "user", "content": text + "\n\n请用三句话总结。"}],
            "max_tokens": 4, "temperature": 0.6, "top_p": 0.95, "top_k": 20}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})

    def go():
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                r.read()
        except Exception:                        # noqa: BLE001 - 我们会主动断开
            pass

    t = threading.Thread(target=go, daemon=True)
    t.start()
    return t


def watch(seconds):
    """采样进度行，返回稳态 tok/s 与样本。"""
    samples = []
    t0 = time.time()
    seen = 0
    while time.time() - t0 < seconds:
        time.sleep(1)
        try:
            with open(LOG, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()[-40:]
        except OSError:
            continue
        for line in lines[seen:]:
            m = re.search(r"reading the prompt: ([\d,]+) of ([\d,]+) tokens, (\d+) s so far", line)
            if m:
                samples.append((int(m.group(1).replace(",", "")), int(m.group(3))))
                seen += 1
        # 去重（同一行可能被重复读）
        uniq = []
        for s in samples:
            if not uniq or s != uniq[-1]:
                uniq.append(s)
        samples = uniq
    # 稳态：跳过前 6 秒，用线性拟合
    steady = [s for s in samples if s[1] >= 6]
    if len(steady) < 2:
        return None, samples
    (a, ta), (b, tb) = steady[0], steady[-1]
    if tb <= ta:
        return None, samples
    return (b - a) / (tb - ta), samples


for arm in ARMS:
    kill()
    start(arm)
    fire()
    tps, samples = watch(SECONDS)
    if tps:
        print(f"  [{arm:8s}] prefill ≈ {tps:.1f} tok/s   "
              f"（{samples[0][0]}@{samples[0][1]}s → {samples[-1][0]}@{samples[-1][1]}s，{len(samples)} 个样本）", flush=True)
    else:
        print(f"  [{arm:8s}] 样本不足: {samples[:5]}", flush=True)
    kill()
