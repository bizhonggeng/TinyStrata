"""双源循环监控：Strata 日志 + pi 会话 JSONL。

Strata 侧能看见的（采样/引擎层）：
  * `the thinking repeated the same passages (coverage=...)` —— reasoning_loop_recovery 触发
  * `the reply repeated one token (...)`                       —— #606 退化输出
  * `done: N tokens ... (length, cancel=False)`                —— 撞 max_tokens
  * `(cancel, cancel=True)`                                    —— 用户手动停止（值得看一眼）
  * `drafts accepted A of B` 且比例 < 40%                       —— MTP 失同步

pi 侧能看见的（**工具调用层的循环，采样参数碰不到**）：
  * 同一个 (工具名 + 参数) 连续重复 —— 本次五子棋会话就是 `read {limit:100,offset:1350}` × 77
  * thinking 文本逐字重复（跨轮）—— 15 轮同样的 151 字
  * 单个会话的工具调用总数暴涨

用法:
  python tools/watch-loop.py --seconds 7200 --tag long
  python tools/watch-loop.py --seconds 7200 --session <path.jsonl>
"""
import argparse
import collections
import json
import os
import re
import time
from pathlib import Path

DEV = Path("D:/dev")
RESULTS = DEV / "results"
PI_SESSIONS = Path("C:/Users/wuyw/.pi/agent/sessions")

STRATA_PATTERNS = [
    ("LOOP-RECOVERY", re.compile(r"the thinking repeated the same passages \(coverage=([\d.]+)\) at (\d+) tokens")),
    ("DEGEN-TOKEN", re.compile(r"the reply repeated one token \((.*?)\) (\d+) times")),
    ("MAX-TOKENS", re.compile(r"done: (\d+) tokens in [\d.]+ s \(([\d.]+) tok/s\) \(length, cancel=False\)")),
    ("CANCELLED", re.compile(r"done: (\d+) tokens in [\d.]+ s .*\(cancel, cancel=True\)")),
    ("THINK-ONLY", re.compile(r"the reply reached max tokens while still thinking")),
    ("ACCEPT", re.compile(r"drafts accepted (\d+) of (\d+)")),
]

TOOL_REPEAT_N = 3        # 同一个 (工具+参数) 连续 N 次就报
REPORT_EVERY_S = 600     # 同一个告警 key 最多每 10 分钟报一次（77 次重复不刷屏）
_last_report: dict[str, float] = {}


def should_report(key: str) -> bool:
    now = time.time()
    if now - _last_report.get(key, 0.0) < REPORT_EVERY_S:
        return False
    _last_report[key] = now
    return True
THINK_REPEAT_N = 3       # 同一段 thinking 连续 N 轮就报
HEARTBEAT_S = 300


class Journal:
    """把事件写到 results/loop-watch.log 并打到 stdout。"""

    def __init__(self, path: Path):
        self.f = path.open("a", encoding="utf-8")
        self.n = 0
        self.f.write(f"\n=== watch start {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
        self.f.flush()

    def write(self, msg: str, critical: bool = False):
        self.n += 1
        rec = f"{time.strftime('%H:%M:%S')} {'**' if critical else ''}{msg}"
        print(rec, flush=True)
        self.f.write(rec + "\n")
        self.f.flush()


def tail_lines(path: Path, pos: int):
    """从 pos 读到文件尾，返回 (新 pos, 行列表)；文件被截断则从头读。"""
    try:
        size = path.stat().st_size
    except OSError:
        return pos, []
    if size < pos:
        pos = 0
    if size == pos:
        return pos, []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        f.seek(pos)
        chunk = f.read()
        return f.tell(), chunk.splitlines()


def watch_strata(journal: Journal, tag: str):
    files = {
        RESULTS / f"strata-qwen36-{tag}-server.log": "serve",
        RESULTS / f"strata-qwen36-{tag}.log": "engine",
    }
    pos = {}
    for f in files:
        try:
            pos[f] = f.stat().st_size
        except OSError:
            pos[f] = 0
    while True:
        time.sleep(1.5)
        for f, who in files.items():
            pos[f], lines = tail_lines(f, pos[f])
            for line in lines:
                for name, rx in STRATA_PATTERNS:
                    m = rx.search(line)
                    if not m:
                        continue
                    if name == "ACCEPT":
                        acc, tot = int(m.group(1)), int(m.group(2))
                        if tot < 20 or acc / tot >= 0.4:
                            continue
                        journal.write(f"[{who}] ACCEPT {acc}/{tot} = {acc/tot:.0%} (低)", True)
                    elif name == "MAX-TOKENS":
                        journal.write(f"[{who}] MAX-TOKENS {m.group(1)} tokens @ {m.group(2)} tok/s")
                    elif name == "CANCELLED":
                        journal.write(f"[{who}] CANCELLED at {m.group(1)} tokens（用户停止）")
                    elif name == "LOOP-RECOVERY":
                        journal.write(f"[{who}] LOOP-RECOVERY coverage={m.group(1)} at {m.group(2)} tokens", True)
                    elif name == "DEGEN-TOKEN":
                        journal.write(f"[{who}] DEGEN-TOKEN {m.group(1)!r} × {m.group(2)}", True)
                    else:
                        journal.write(f"[{who}] THINK-ONLY（思考烧光预算、没给答案）", True)
                    break
        yield


def watch_pi(journal: Journal, session: Path):
    """盯一个 pi 会话文件：连续相同工具调用 / 逐字重复的 thinking。"""
    pos = 0
    try:
        pos = session.stat().st_size            # 只关心"从现在开始"的新轮次
    except OSError:
        pass
    last_keys = collections.deque(maxlen=TOOL_REPEAT_N)
    last_think = collections.deque(maxlen=THINK_REPEAT_N)
    calls = 0
    journal.write(f"[pi] 监视会话 {session.name}（从当前末尾开始）")
    last_grow = time.time()
    next_switch = time.time() + 60
    while True:
        time.sleep(2)
        before = pos
        pos, lines = tail_lines(session, pos)
        if pos != before:
            last_grow = time.time()
        # 60 秒没动静就看有没有更新的会话（常切会话时自动跟随）
        if time.time() >= next_switch:
            next_switch = time.time() + 60
            if time.time() - last_grow > 60:
                cands = sorted(PI_SESSIONS.rglob("*.jsonl"), key=lambda q: q.stat().st_mtime, reverse=True)
                if cands and cands[0] != session:
                    session, pos = cands[0], cands[0].stat().st_size
                    last_keys.clear()
                    last_think.clear()
                    last_grow = time.time()
                    journal.write(f"[pi] 换到更新的会话 {session.name}（从末尾开始）")
        for line in lines:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("type") != "message":
                continue
            m = r.get("message") or {}
            if m.get("role") != "assistant":
                continue
            for p in (m.get("content") or []):
                if not isinstance(p, dict):
                    continue
                if p.get("type") == "toolCall":
                    calls += 1
                    key = p.get("name") + " " + json.dumps(p.get("arguments") or {}, sort_keys=True, ensure_ascii=False)
                    last_keys.append(key)
                    if len(last_keys) == TOOL_REPEAT_N and len(set(last_keys)) == 1 and should_report("tool:" + key):
                        journal.write(f"[pi] **TOOL-REPEAT** 同一个调用连续 {TOOL_REPEAT_N} 次: {key[:110]}"
                                      f"（累计 {calls} 次工具调用）", True)
                elif p.get("type") == "thinking":
                    th = (p.get("thinking") or "").rstrip()
                    last_think.append(th)
                    if (len(last_think) == THINK_REPEAT_N and len(set(last_think)) == 1 and th
                            and should_report("think:" + th[:200])):
                        journal.write(f"[pi] **THINK-REPEAT** 同一段思考连续 {THINK_REPEAT_N} 轮逐字相同: {th[:90]!r}", True)
        yield


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=7200)
    ap.add_argument("--tag", default="long")
    ap.add_argument("--session", default=None, help="pi 会话 jsonl；不给则自动选最近修改的那个")
    a = ap.parse_args()

    session = Path(a.session) if a.session else None
    if session is None:
        cands = sorted(PI_SESSIONS.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        session = cands[0] if cands else None

    journal = Journal(RESULTS / "loop-watch.log")
    if session is not None:
        journal.write(f"[pi] 选中 {session}")
    else:
        journal.write("[pi] 没找到会话文件，只盯 Strata 日志")

    g1 = watch_strata(journal, a.tag)
    g2 = watch_pi(journal, session) if session is not None else None
    t_end = time.time() + a.seconds
    next_beat = time.time() + HEARTBEAT_S
    while time.time() < t_end:
        next(g1)
        if g2 is not None:
            next(g2)
        if time.time() >= next_beat:
            next_beat = time.time() + HEARTBEAT_S
            journal.write(f"[watch] 心跳：运行中，累计信号 {journal.n} 条")
    journal.write(f"[watch] 结束，共 {journal.n} 条信号")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
