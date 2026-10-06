#!/usr/bin/env python3
"""解码耗时横向对比：本库（仓颉）vs ffmpeg×2 vs libmpg123。

【为什么需要单独做一次，而不能沿用检测器的耗时】

    检测器的耗时（`evaluate.py` 的性能段）量的是"对已有 PCM 做比对"，
    而这里量的是"把 MP3 变成 PCM"。两者的单位、瓶颈、可比对象都不同：
    前者的对手是 numpy，后者的对手是 C 实现。

【怎么做到尽量公平】

    1. **同一份输入**：所有实现解同一个文件，输出都丢弃（不落盘、不比较）。
    2. **剔除进程启动**：ffmpeg 是子进程，短素材上启动时间与解码时间同量级。
       因此同时报 ffmpeg 自带的 `-benchmark` CPU 时间（utime，不含进程创建）
       与端到端墙钟；后者再减去 `ffmpeg -version` 的墙钟基线（即启动成本）。
    3. **剔除首次开销**：每个实现先跑一次预热，再取 N 次中位数。
    4. **本库走官方基准**：1 秒素材用 `cjpm bench --filter mp3DecodeAll`
       （框架自带预热与统计，是最可信的口径）；30 秒素材用"导出用例耗时 − 空清单
       基线"，扣除 cjpm 自身的启动与检查开销，并在报告里注明这包含了写出
       f32le（10.6 MB）的 IO 成本。
    5. 报两个口径：**实时倍速**（音频秒/墙钟秒，与素材码率无关）与
       **输入吞吐**（MP3 压缩字节/秒，反映"一秒能吞多少文件"）。
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from diag_common import CLIPS, DUMP_LIST, OURS, REPO, WORK, ffmpeg_probe  # noqa: E402

import numpy as np                                                        # noqa: E402


def _run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", **kw)


def ffmpeg_startup_baseline(repeats: int = 5) -> float:
    """`ffmpeg -version` 的墙钟中位数 = 进程启动成本（要从未含 benchmark 的墙钟里扣掉）。"""
    ts = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        _run(["ffmpeg", "-hide_banner", "-version"])
        ts.append(time.perf_counter() - t0)
    return statistics.median(ts)


def bench_ffmpeg(path: Path, decoder: str, startup: float, repeats: int = 5) -> dict:
    """ffmpeg 解码：报 utime（CPU，含解码+少量启动）与扣掉启动的墙钟。

    注意**不能用 `-v error`**：`-benchmark` 的那行 `bench: utime=...` 是 INFO 级日志，
    被 `-v error` 一并抑制，utime 会恒为空（踩过）。这里用 `-nostats` 压掉进度条，
    但保留日志级别。
    """
    cmd = ["ffmpeg", "-hide_banner", "-nostats", "-benchmark", "-y",
           "-c:a", decoder, "-i", str(path), "-f", "null", "-"]
    utimes, walls = [], []
    for i in range(repeats + 1):                       # 第 1 次预热
        t0 = time.perf_counter()
        p = _run(cmd)
        dt = time.perf_counter() - t0
        if i == 0:
            continue
        m = re.search(r"utime=([0-9.]+)", p.stderr or "")
        if m:
            utimes.append(float(m.group(1)))
        walls.append(dt)
    return {
        "impl": f"ffmpeg {decoder}",
        "cpuSeconds": statistics.median(utimes) if utimes else None,
        "wallSeconds": statistics.median(walls),
        "wallMinusStartup": statistics.median(walls) - startup,
    }


def bench_soundfile(path: Path, repeats: int = 5) -> dict:
    """libsndfile(libmpg123) 解码：进程内，天然不含启动成本。"""
    import soundfile as sf

    ts = []
    for i in range(repeats + 1):
        t0 = time.perf_counter()
        sf.read(str(path), dtype="float32", always_2d=True)
        dt = time.perf_counter() - t0
        if i:
            ts.append(dt)
    return {"impl": "libsndfile(libmpg123)", "wallSeconds": statistics.median(ts)}


def bench_ours_bench_suite() -> dict | None:
    """本库 1 秒素材：直接取官方 `cjpm bench` 的数字（最可信口径）。"""
    p = _run(["cjpm", "bench", "--filter", "BenchDecode", "--no-color"], cwd=str(REPO))
    out = re.sub(r"\x1b\[[0-9;]*m", "", (p.stdout or "") + (p.stderr or ""))
    m = re.search(r"mp3DecodeAll.*?mean:\s*([0-9.]+) ms\s*\.\.\s*([0-9.]+) ms",
                  out, re.S)
    if not m:
        return None
    return {"impl": "本库（仓颉，cjpm bench）",
            "wallSeconds": (float(m.group(1)) + float(m.group(2))) / 2 / 1000.0,
            "source": "cjpm bench mp3DecodeAll（框架预热 + 统计）"}


def bench_ours_dump(clip: Path, repeats: int = 2) -> dict:
    """本库任意素材：跑导出用例，扣掉"空清单"基线 = 解码 + 写出 f32le 的净耗时。"""
    def run(list_lines: list[str]) -> float:
        DUMP_LIST.parent.mkdir(parents=True, exist_ok=True)
        DUMP_LIST.write_text("\n".join(list_lines) + "\n", encoding="utf-8")
        ts = []
        for _ in range(repeats):
            t0 = time.perf_counter()
            _run(["cjpm", "test", "--filter", "DiagDumpTest", "--no-color"],
                 cwd=str(REPO))
            ts.append(time.perf_counter() - t0)
        return statistics.median(ts)

    base = run(["# 基线：空清单"])
    real = run([f"{clip.as_posix()}|{(OURS / (clip.stem + '.f32le')).as_posix()}"])
    DUMP_LIST.write_text("# 诊断导出清单（bench_decode.py 已清空）\n", encoding="utf-8")
    return {"impl": "本库（仓颉，导出用例−基线）", "wallSeconds": real - base,
            "baselineSeconds": base, "withIo": True}


def main() -> int:
    ap = argparse.ArgumentParser(description="解码耗时横向对比")
    ap.add_argument("--repeats", type=int, default=5)
    args = ap.parse_args()

    # 1 秒素材（与官方基准同一份，便于与 cjpm bench 对照）+ 30 秒真实音乐
    targets = [CLIPS / "fx_cbr128.mp3", CLIPS / "baihu_200s.mp3"]
    targets = [t for t in targets if t.exists()]
    if not targets:
        print("缺片段：先跑 scripts/diag/make_dataset.py")
        return 1

    startup = ffmpeg_startup_baseline()
    print(f"ffmpeg 进程启动基线（墙钟中位）：{startup * 1000:.1f} ms\n")

    rows = []
    for clip in targets:
        info = ffmpeg_probe(clip)
        sr, ch = info["sampleRate"], info["channels"]
        frames = info["duration"] * sr
        size = clip.stat().st_size
        print(f"=== {clip.stem}：{info['duration']:.1f} 秒 / {sr} Hz / {ch} ch / "
              f"{size / 1024:.0f} KB ===")
        cands: list[dict] = []
        if clip.stem == "fx_cbr128":
            b = bench_ours_bench_suite()
            if b:
                cands.append(b)
        try:
            cands.append(bench_ours_dump(clip, repeats=2))
        except Exception as e:                                   # noqa: BLE001
            print(f"  （本库导出计时失败：{type(e).__name__} {e}）")
        for dec in ("mp3float", "mp3"):
            cands.append(bench_ffmpeg(clip, dec, startup, args.repeats))
        try:
            cands.append(bench_soundfile(clip, args.repeats))
        except Exception as e:                                   # noqa: BLE001
            print(f"  （libsndfile 计时失败：{type(e).__name__} {e}）")

        ours = min((c["wallSeconds"] for c in cands if c["impl"].startswith("本库")),
                   default=None)
        for c in cands:
            # 只用"可比耗时"：ffmpeg 扣掉进程启动；本库扣掉 cjpm 基线；
            # libsndfile 进程内调用天然不含启动
            secs = c.get("wallMinusStartup") or c["wallSeconds"]
            c["audioSeconds"] = info["duration"]
            c["realtimeFactor"] = info["duration"] / secs
            c["inputMBps"] = size / 1e6 / secs
            c["comparableSeconds"] = secs
            c["note"] = ""
            if c.get("wallMinusStartup"):
                c["note"] = f"已扣 ffmpeg 启动基线 {startup * 1000:.1f} ms"
            if c.get("baselineSeconds"):
                c["note"] = (f"已扣空清单基线 {c['baselineSeconds']:.2f}s；"
                             f"含写出 f32le（{frames * ch * 4 / 1e6:.1f} MB）")
            if c.get("cpuSeconds"):
                c["note"] += f"；ffmpeg 自报 CPU {c['cpuSeconds'] * 1000:.1f} ms"
            c["vsOursSlowdown"] = (secs / ours) if ours else None
            c["vsOursFaster"] = (ours / secs) if ours else None
            print(f"  {c['impl']:28s} 可比耗时 {secs * 1000:9.1f} ms  "
                  f"{c['realtimeFactor']:7.1f}× 实时  "
                  f"{c['inputMBps']:6.2f} MB/s" +
                  (f"（本库的 {c['vsOursSlowdown']:.3f}×，即快 {c['vsOursFaster']:.0f}×）"
                   if c["vsOursSlowdown"] else "")
                  + (f"  [{c['note']}]" if c["note"] else ""))
            rows.append({"clip": clip.stem, "sr": sr, "ch": ch,
                         "audioSeconds": info["duration"], **c})
        print()

    (WORK / "bench_decode.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"结果已写入 {WORK / 'bench_decode.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
