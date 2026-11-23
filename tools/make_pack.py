#!/usr/bin/env python3
"""Build the small Strata "pack" for one GGUF file.

A pack is *not* a copy of the model: it is the dense tensors in the engine's
layout (dense.bin, tens of MB), a tensor index (index.txt), the tokenizer, and
native_experts.txt -- the byte offsets of every layer's experts inside the GGUF.
The 12 GB of routed experts stay in the GGUF and are read in place, which is why
this takes seconds instead of hours.

    python tools/make-pack.py --gguf  D:\\models\\Qwen3.6-35B-A3B-UD-IQ3_S.gguf
    python tools/make-pack.py --gguf  ... --packs D:\\packs --force

The pack lands in <packs>/<family>-<quant> (default <packs> = ./packs), the same
name upstream's setup.py uses.  Needs Python 3.10+ and numpy; the llama.cpp
`gguf` python package is only needed for files whose small projections are
quantized (UD-Q4_K_XL and friends) instead of F32.

Exit codes: 0 ok, 2 bad arguments, 3 pack tool missing, 4 build failed,
5 the pack does not point at the GGUF we asked for.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent


def find_iq_pack() -> pathlib.Path | None:
    """iq_pack.py lives in the Strata checkout's tools/, not necessarily next to us."""
    cands = [HERE / "iq_pack.py"]
    env = os.environ.get("STRATA_ROOT")
    if env:
        cands.append(pathlib.Path(env) / "tools" / "iq_pack.py")
    cands += [HERE.parent / "strata" / "tools" / "iq_pack.py",      # <install>/tools -> <install>/strata
              HERE.parent.parent / "strata" / "tools" / "iq_pack.py",
              HERE.parent / "iq_pack.py"]
    for c in cands:
        if c.is_file():
            return c
    return None


IQ_PACK = find_iq_pack() or (HERE / "iq_pack.py")

# family -> extra iq_pack flags (mirrors setup.py's "pack_args")
FAMILY_ARGS = {
    "qwen36": ["--compat-bf16"],
    "qwen3":  ["--compat-bf16"],
    "ornith": ["--compat-bf16"],
}

QUANT_RE = re.compile(r"((?:UD-)?(?:IQ\d[A-Za-z0-9_]*|Q\d(?:_[A-Za-z0-9]+)*))$")


def quant_of(stem: str) -> str:
    """Qwen3.6-35B-A3B-UD-IQ3_S -> UD-IQ3_S"""
    m = QUANT_RE.search(stem)
    return m.group(1) if m else stem


def pack_tag(gguf: pathlib.Path, family: str) -> str:
    return f"{family}-{quant_of(gguf.stem)}".lower()


def native_header_gguf(pack: pathlib.Path) -> str:
    """The GGUF file name that native_experts.txt points into ('' if unknown)."""
    f = pack / "native_experts.txt"
    if not f.exists():
        return ""
    try:
        head = f.read_text(encoding="utf-8", errors="ignore").splitlines()[0]
    except OSError:
        return ""
    m = re.search(r"absolute offsets in ([^,;)]+)", head)
    return m.group(1).strip() if m else ""


def existing_pack_for(gguf: pathlib.Path, packs_root: pathlib.Path) -> pathlib.Path | None:
    """Any pack under <packs_root> whose native_experts.txt names this GGUF."""
    if not packs_root.is_dir():
        return None
    want = gguf.name.lower()
    for d in sorted(packs_root.iterdir()):
        if d.is_dir() and native_header_gguf(d).lower() == want:
            return d
    return None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Build the Strata pack for one GGUF (seconds, ~60 MB).")
    ap.add_argument("--gguf", required=True, help="the model file (one shard is enough)")
    ap.add_argument("--packs", default=None, help="where packs live (default ./packs)")
    ap.add_argument("--family", default="qwen36", help="model family, decides the extra iq_pack flags (default qwen36)")
    ap.add_argument("--out", default=None, help="explicit output dir (default <packs>/<family>-<quant>)")
    ap.add_argument("--no-compat-bf16", action="store_true", help="do not pass --compat-bf16 (only if you know why)")
    ap.add_argument("--force", action="store_true", help="rebuild even if a pack for this GGUF already exists")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    gguf = pathlib.Path(a.gguf).expanduser().resolve()
    if not gguf.is_file():
        print(f"make-pack: not a file: {gguf}", file=sys.stderr)
        return 2
    if not IQ_PACK.is_file():
        print(f"make-pack: {IQ_PACK} is missing (run this from the Strata checkout)", file=sys.stderr)
        return 3

    packs_root = pathlib.Path(a.packs).expanduser().resolve() if a.packs else pathlib.Path.cwd() / "packs"
    if not a.force:
        found = existing_pack_for(gguf, packs_root)
        if found:
            print(f"make-pack: {gguf.name} already has a pack: {found}")
            print("make-pack: nothing to do (use --force to rebuild)")
            return 0

    out = pathlib.Path(a.out).expanduser().resolve() if a.out else packs_root / pack_tag(gguf, a.family)
    out.mkdir(parents=True, exist_ok=True)

    flags = [] if a.no_compat_bf16 else list(FAMILY_ARGS.get(a.family, []))
    cmd = [sys.executable, str(IQ_PACK), "--gguf", str(gguf), "--out", str(out), *flags]
    if not a.quiet:
        print(f"make-pack: {gguf.name}")
        print(f"make-pack: -> {out}")
        print(f"make-pack: {' '.join(cmd[1:])}")
    t0 = time.time()
    env = dict(os.environ)
    # let iq_pack import llama.cpp's gguf-py when the file needs dequantizing
    for cand in (HERE.parent / "llama.cpp" / "gguf-py",):
        if cand.is_dir() and "STRATA_GGUF_PY" not in env:
            env["STRATA_GGUF_PY"] = str(cand)
    rc = subprocess.call(cmd, env=env)
    if rc != 0:
        print(f"make-pack: iq_pack failed (exit {rc})", file=sys.stderr)
        return 4

    # the pack names the GGUF it was built from: make sure it is the one asked for
    named = native_header_gguf(out)
    if named and named.lower() != gguf.name.lower():
        print(f"make-pack: the pack points at {named}, not {gguf.name}", file=sys.stderr)
        return 5

    want = ("dense.bin", "index.txt", "native_experts.txt")
    missing = [f for f in want if not (out / f).exists()]
    if missing:
        print(f"make-pack: incomplete pack, missing: {', '.join(missing)}", file=sys.stderr)
        return 4

    mb = sum(p.stat().st_size for p in out.rglob("*") if p.is_file()) / 1e6
    print(f"make-pack: done in {time.time() - t0:.1f}s, {mb:.0f} MB in {out}")
    print(f"make-pack: the engine needs  --pack \"{out}\"  and  --native \"{gguf}\"")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
