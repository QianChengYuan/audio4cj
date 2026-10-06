#!/usr/bin/env python3
"""诊断工具链的评测：一致性、检出率、误报率、定位偏差、性能。

【评测设计：三层，层次不能混】

    第一层 · 横向一致性（真实素材，无真值）
        把 4 条独立解码路径两两对齐，量化"差多少、差在哪"：
        长度/位移、整体 RMS 比、峰值绝对差、逐窗归一化一致的分布。
        它回答的是"检测器的输入环境有多干净" —— 解码器之间的合法差异
        构成检测器的**噪声底**，误报率就是在这个底上量出来的。

    第二层 · 检出与定位（注入真值，有正确答案）
        向参照信号注入六类故障（位置/类型/幅度已知），衡量每个方法：
        检出率、误报率、漏报率、定位偏差。为了公平，
        **先按误报目标标定 k**（同一误报代价下比检出率），再报告工作点。
        检出/定位在**隔离条件**（注入版 vs 原始版）下测：那里没有解码器差异
        干扰，量到的是方法本身的能力上限；解码器差异的影响由第一层的
        噪声底 + 标定环节纳入 —— 也就是说，工作点是在真实噪声下选的，
        能力是在干净条件下量的，两者不混。

        真实素材上的实战表现由 `--pair` 模式给出（同一片段、四条解码路径，
        看分歧落在哪里）—— 那是本工具最终要回答的问题。

    第三层 · 性能
        运行时间、吞吐量、内存峰值、随输入长度的伸缩、多进程并发加速比。

【为什么误报率要在"真实条件"下标定】

    若用"注入版 vs 原始版"的隔离条件标定 k，噪声底为零，k 可以定得极低，
    标出来的工作点在真实素材上必然满屏误报。噪声底只能来自真实素材，
    所以标定走第一层、验证走第二层，两者用的是同一组 k。
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import platform
import statistics
import sys
import time
import tracemalloc
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from diag_common import (CLIPS, OURS, REFS, REPORTS, WORK, apply_lag, estimate_lag,
                         frame_rms, read_f32le)                      # noqa: E402
from inject import KINDS, inject, inject_single                    # noqa: E402
from localize import (DETECTORS, EDGE_MARGIN, METHODS, SERIES_METHODS, detect,
                      series)                                          # noqa: E402


def margin_for(lag: int) -> int:
    """边界屏蔽宽度 = 基础宽度 + |位移|。

    位移越大，两路在首尾"多出/被裁掉"的样本越多（本库保留完整帧序列，
    参照按 gapless 裁掉延迟与填充）。固定宽度在位移大时不够，噪声底会被
    残留的边界区抬高（实测：只取固定 3456 时 res-rms 仍有 0.58）。
    """
    return EDGE_MARGIN + abs(lag)

#: 鲁棒阈值里的 k **固定**：它管的是"窗内分布内的离群"，不是灵敏度主旋钮。
#: 灵敏度由地板系数 α 承担（见下）—— 把两件事分开调，报告才好解释。
K_FIXED = 4.0

#: 地板系数网格：地板 = α × 真实噪声底的 P99.9。
#: α=1 意味着"只要超过干净配对 99.9 分位就报"，α 越大越钝。
ALPHA_GRID = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0]

#: M0 没有"窗分布"，只有绝对判据：k 在这里的含义是"整体相对差 > k%"。
M0_K_GRID = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0]


# ---------------------------------------------------------------------------
# 数据装载
# ---------------------------------------------------------------------------


def load_clip(name: str, tag: str) -> np.ndarray | None:
    p = REFS / f"{name}.{tag}.f32le"
    if not p.exists():
        return None
    ch = 1 if "mono16k" in name else 2
    return read_f32le(p, ch)


def load_ours(name: str) -> np.ndarray | None:
    p = OURS / f"{name}.f32le"
    if not p.exists():
        return None
    ch = 1 if "mono16k" in name else 2
    return read_f32le(p, ch)


def dataset_names() -> list[str]:
    names = [p.stem for p in sorted(CLIPS.glob("*.mp3"))]
    return [n for n in names if load_ours(n) is not None]


# ---------------------------------------------------------------------------
# 第一层：横向一致性
# ---------------------------------------------------------------------------


def pair_metrics(ours: np.ndarray, ref: np.ndarray, sr: int) -> dict:
    """一对解码输出的对齐与差异度量。"""
    lag = estimate_lag(ours, ref, max_lag=8192, sr_hint=sr)
    x, y = apply_lag(ours, ref, lag)
    if len(x) < sr // 10:
        return {"lag": lag, "overlapFrames": int(len(x)), "error": "重叠区太短"}
    rx = float(np.sqrt(np.mean(x ** 2)))
    ry = float(np.sqrt(np.mean(y ** 2)))
    peak = float(np.max(np.abs(y))) or 1e-12
    res = x - y
    # 逐窗归一化一致度（50ms 窗）：反映"局部是否逐样本对得上"
    win = max(64, int(0.05 * sr))
    rms_x, centers = frame_rms(x.mean(axis=1), win, win)
    rms_y, _ = frame_rms(y.mean(axis=1), win, win)
    n = min(len(rms_x), len(rms_y))
    with np.errstate(divide="ignore", invalid="ignore"):
        ratio_db = 20 * np.log10((rms_x[:n] + 1e-12) / (rms_y[:n] + 1e-12))
    ratio_db = ratio_db[np.isfinite(ratio_db)]
    return {
        "lag": int(lag),
        "overlapFrames": int(len(x)),
        "rmsRelDb": float(abs(20 * np.log10((rx + 1e-12) / (ry + 1e-12)))),
        "maxAbsDiffOverPeak": float(np.max(np.abs(res)) / peak),
        "residualRmsOverSignalRms": float(np.sqrt(np.mean(res ** 2)) / (ry + 1e-12)),
        "winRatioDbP50": float(np.median(ratio_db)) if ratio_db.size else 0.0,
        "winRatioDbP95": float(np.quantile(np.abs(ratio_db), 0.95)) if ratio_db.size else 0.0,
        "winCount": int(n),
    }


def run_consistency(names: list[str]) -> dict:
    """两两比对全部解出路径，输出一致性矩阵。"""
    tags = ["fffloat", "fffixed", "sndfile"]
    out: dict[str, dict] = {}
    for name in names:
        ours = load_ours(name)
        if ours is None:
            continue
        sr = 16000 if "mono16k" in name else 44100
        entry: dict[str, dict] = {}
        for t in tags:
            ref = load_clip(name, t)
            if ref is None:
                continue
            entry[f"ours_vs_{t}"] = pair_metrics(ours, ref, sr)
        for a in range(len(tags)):
            for b in range(a + 1, len(tags)):
                ra, rb = load_clip(name, tags[a]), load_clip(name, tags[b])
                if ra is None or rb is None:
                    continue
                entry[f"{tags[a]}_vs_{tags[b]}"] = pair_metrics(ra, rb, sr)
        out[name] = entry
    return out


# ---------------------------------------------------------------------------
# 第二层：真值集与指标
# ---------------------------------------------------------------------------


def build_instances(names: list[str], positions: int = 5) -> list[dict]:
    """为每个片段造注入实例：一个"多故障"实例 + 一个"位移"实例。

    `slip` 必须单独注入：它改变长度，混在一起会让同实例内后续真值的坐标全部平移。
    """
    insts = []
    for name in names:
        base = load_clip(name, "fffloat")
        if base is None or len(base) < 44100:
            continue
        sr = 16000 if "mono16k" in name else 44100
        # 多故障实例
        sig, faults = inject(base, sr, positions=positions, seed=abs(hash(name)) % 100000)
        insts.append({"name": name, "kind": "multi", "sr": sr, "base": base,
                      "signal": sig, "faults": faults})
        # 位移实例（单独）
        pos = len(base) // 2
        sig2, f2 = inject_single(base, sr, "slip", pos)
        insts.append({"name": name, "kind": "slip", "sr": sr, "base": base,
                      "signal": sig2, "faults": [f2]})
    return insts


def match_faults(faults, suspects, min_overlap: float = 0.5) -> tuple[list, list]:
    """把疑点区间与真值配对。返回 (命中列表[(真值, 疑点)], 误报列表)。"""
    hits, used = [], set()
    for f in faults:
        dur = max(1, f.end - f.start)
        best = None
        for i, s in enumerate(suspects):
            ov = min(f.end, s.end) - max(f.start, s.start)
            if ov > 0 and ov >= min_overlap * dur and (best is None or ov > best[1]):
                best = (i, ov)
        if best:
            hits.append((f, suspects[best[0]]))
            used.add(best[0])
    fps = [s for i, s in enumerate(suspects) if i not in used]
    return hits, fps


def evaluate_method(method: str, k: float, floor: float, aligned_clean: list,
                    instances: list, aligned_ours: list | None = None) -> dict:
    """在给定工作点（k, floor）下评测一个方法的检出/定位表现。

    两处口径必须分开，否则数字会互相污染：
      · 精准率的假阳**只数注入实例里没配上真值的区间** —— 那是真正的"报错了"；
      · 误报率数的是**干净素材上被报出疑点的实例比例**（一个实例报 50 段也只算 1 次）——
        干净素材上任何区间都是假的，但"这张素材有没有被冤枉"才是使用者的代价。
    """
    tp = fp_intervals = fn = 0
    loc_err_ms: list[float] = []
    per_kind_tp = {kk: 0 for kk in KINDS}
    per_kind_total = {kk: 0 for kk in KINDS}

    for inst in instances:
        # `slip` 注入会改变长度：按较短者截断，比较才是良定义的。
        # （截断后位移点之后的整段都会成为残差 —— 这正是位移类故障的固有难点，
        #   由 per-kind 的检出率如实反映，不做特殊照顾。）
        sig, base = inst["signal"], inst["base"]
        n = min(len(sig), len(base))
        suspects = detect(method, sig[:n], base[:n], inst["sr"], k, floor, EDGE_MARGIN)
        hits, fps = match_faults(inst["faults"], suspects)
        tp += len(hits)
        fp_intervals += len(fps)
        fn += len(inst["faults"]) - len(hits)
        for f in inst["faults"]:
            per_kind_total[f.kind] += 1
        for f, s in hits:
            per_kind_tp[f.kind] += 1
            loc_err_ms.append(abs((s.start + s.end) / 2 - (f.start + f.end) / 2)
                              * 1000.0 / inst["sr"])

    flagged = len([1 for (x, y, sr, mg) in aligned_clean
                   if detect(method, x, y, sr, k, floor, mg)])
    total_pairs = len(aligned_clean)
    # "本库 vs 参照"上被标记的比例：这不是误报，而是**真实偏差的检出**
    # —— 参照互比才是噪声底（见 aligned_ref_pairs 的说明）
    ours_flagged = ours_total = 0
    for (x, y, sr, mg) in (aligned_ours or []):
        ours_total += 1
        if detect(method, x, y, sr, k, floor, mg):
            ours_flagged += 1

    total_faults = max(1, tp + fn)
    return {
        "method": method,
        "k": k,
        "floor": floor,
        "oursPairs": ours_total,
        "oursPairsFlagged": ours_flagged,
        "recall": tp / total_faults,
        "fnr": fn / total_faults,
        "precision": tp / max(1, tp + fp_intervals),
        "falsePositiveIntervals": fp_intervals,
        "cleanPairs": total_pairs,
        "cleanPairsFlagged": flagged,
        "fprPairs": flagged / total_pairs if total_pairs else None,
        "localizationErrMsMedian": float(statistics.median(loc_err_ms)) if loc_err_ms else None,
        "localizationErrMsP95": float(np.quantile(loc_err_ms, 0.95)) if loc_err_ms else None,
        "perKindRecall": {kk: (per_kind_tp[kk] / per_kind_total[kk]
                               if per_kind_total[kk] else None) for kk in KINDS},
    }


def aligned_ref_pairs(names: list[str]) -> list:
    """**参照之间**的配对（fffloat / fffixed / sndfile 两两），对齐后缓存。

    【为什么噪声底必须取参照互比，而不是"本库 vs 参照"】
      这是本次评估最关键的一处方法论修正。若拿"本库 vs 参照"当噪声底，
      就把**本库自身的偏差**当成"合法差异"写进了尺子里 —— 尺子会被待测对象
      拉长，检测器对所有真实缺陷随之变瞎。
      实测：三条相互独立的参照之间的残差是 ffmpeg 两条实现 8.3e-04
      （−62 dB）、libmpg123 vs ffmpeg 7.3e-07（−123 dB）；而本库与三者
      都差 6.4e-02 ~ 9.5e-02（−20 dB 量级）。前者才是"两套正确解码器之间
      应有的差异"，也就是噪声底。
    """
    out = []
    tags = ("fffloat", "fffixed", "sndfile")
    for n in names:
        sr = 16000 if "mono16k" in n else 44100
        for i in range(len(tags)):
            for j in range(i + 1, len(tags)):
                a, b = load_clip(n, tags[i]), load_clip(n, tags[j])
                if a is None or b is None:
                    continue
                lag = estimate_lag(a, b, max_lag=8192, sr_hint=sr)
                x, y = apply_lag(a, b, lag)
                if len(x) >= sr // 10:
                    out.append((x, y, sr, margin_for(lag)))
    return out


def aligned_ours_pairs(names: list[str]) -> list:
    """**本库 vs 各参照**的配对，对齐后缓存 —— 这些是**待定位的疑点**，不是噪声底。"""
    out = []
    for n in names:
        ours = load_ours(n)
        if ours is None:
            continue
        sr = 16000 if "mono16k" in n else 44100
        for t in ("fffloat", "fffixed", "sndfile"):
            ref = load_clip(n, t)
            if ref is None:
                continue
            lag = estimate_lag(ours, ref, max_lag=8192, sr_hint=sr)
            x, y = apply_lag(ours, ref, lag)
            if len(x) >= sr // 10:
                out.append((x, y, sr, margin_for(lag)))
    return out


def collect_noise_floor(aligned_clean: list) -> dict[str, float]:
    """从真实干净配对统计每个方法的**噪声底**：指标值的 P99.9。

    这是整份评测里最要紧的一个数：它把"两套正确解码器之间的合法差异"
    量化成了每个方法各自的一把尺子。没有它，任何阈值都是在赌。
    """
    pooled: dict[str, list] = {m: [] for m in SERIES_METHODS}
    for (x, y, sr, mg) in aligned_clean:
        for m in SERIES_METHODS:
            for b in series(m, x, y, sr, mg):
                # M4 会额外产出各带序列；噪声底只用"带间最大值"那条总序列，
                # 否则同一窗会被四个带重复计入、把分位数压低
                if b.label == "band-ratio" and m == "band-ratio":
                    pooled[m].append(b.values)
                elif m != "band-ratio":
                    pooled[m].append(b.values)
    floor = {}
    for m, chunks in pooled.items():
        if chunks:
            v = np.concatenate(chunks)
            v = v[~np.isnan(v)]              # 静音窗已被置 NaN，不计入噪声底
            floor[m] = float(np.quantile(v, 0.999)) if v.size else 0.0
        else:
            floor[m] = 0.0
    return floor


def calibrate(aligned_clean: list, floor: dict[str, float],
              target_fpr: float) -> dict[str, dict]:
    """按"干净素材上的**实例**误报比例"标定工作点。

    用实例比例而不是区间总数：一条素材报 1 个错区间和报 50 个错区间，
    对使用者的代价差别巨大，但"这张素材有没有被冤枉"是更稳定的口径。

    对 M1..M5：扫地板系数 α（地板 = α × P99.9），取满足误报目标的**最小** α
    —— 最小 α 意味着最灵敏的可接受工作点。
    对 M0：它没有分布可统计，扫的是"整体相对差 > k%"里的 k。
    """
    picks: dict[str, dict] = {}
    for method in DETECTORS:
        if method == "global":
            pick = {"k": M0_K_GRID[-1], "floor": 0.0}
            for k in M0_K_GRID:
                bad = sum(1 for (x, y, sr, mg) in aligned_clean
                          if detect(method, x, y, sr, k, 0.0, mg))
                if aligned_clean and bad / len(aligned_clean) <= target_fpr:
                    pick = {"k": k, "floor": 0.0}
                    break
            picks[method] = pick
            continue
        pick = {"k": K_FIXED, "floor": ALPHA_GRID[-1] * floor[method]}
        for alpha in ALPHA_GRID:
            fl = alpha * floor[method]
            bad = sum(1 for (x, y, sr, mg) in aligned_clean
                      if detect(method, x, y, sr, K_FIXED, fl, mg))
            if aligned_clean and bad / len(aligned_clean) <= target_fpr:
                pick = {"k": K_FIXED, "floor": fl, "alpha": alpha}
                break
        picks[method] = pick
    return picks


# ---------------------------------------------------------------------------
# 第三层：性能
# ---------------------------------------------------------------------------


def perf_method(method: str, x: np.ndarray, y: np.ndarray, sr: int,
                repeats: int = 3, k: float = 4.0, floor: float = 0.0,
                margin: int = EDGE_MARGIN) -> dict:
    """单个方法的耗时与内存峰值。"""
    detect(method, x, y, sr, k, floor, margin)      # 预热（首次含分配/页错误）
    times = []
    peak_mem = 0
    for _ in range(repeats):
        tracemalloc.start()
        t0 = time.perf_counter()
        detect(method, x, y, sr, k, floor, margin)
        dt = time.perf_counter() - t0
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        times.append(dt)
        peak_mem = max(peak_mem, peak)
    frames = len(x)
    samples = frames * x.shape[1]
    med = statistics.median(times)
    return {
        "method": method,
        "medianMs": med * 1000.0,
        "frames": frames,
        "channels": x.shape[1],
        "sampleRate": sr,
        "audioSeconds": frames / sr,
        "throughputMSamplesPerSec": samples / med / 1e6,
        "realtimeFactor": (frames / sr) / med,
        "peakMemMB": peak_mem / 1024 / 1024,
        "peakMemBytesPerSample": peak_mem / max(1, samples),
    }


def perf_scaling(method: str, x: np.ndarray, y: np.ndarray, sr: int,
                 seconds_list: list[float], k: float = 4.0,
                 floor: float = 0.0, margin: int = EDGE_MARGIN) -> list[dict]:
    """随输入长度的伸缩（判断是否线性、有无超线性开销）。"""
    rows = []
    for sec in seconds_list:
        n = min(len(x), int(sec * sr))
        if n < sr:
            continue
        xs, ys = x[:n], y[:n]
        detect(method, xs, ys, sr, k, floor, EDGE_MARGIN)   # 预热
        t0 = time.perf_counter()
        detect(method, xs, ys, sr, k, floor, EDGE_MARGIN)
        dt = time.perf_counter() - t0
        rows.append({"seconds": sec, "ms": dt * 1000.0})
    return rows


_WORKER: dict = {}


def _worker_init(payload: dict) -> None:
    _WORKER.update(payload)


def _worker_task(task) -> float:
    """一个批次任务：在某素材上跑一个方法。返回耗时秒。"""
    name, kind, method, k, floor, margin = task
    inst = _WORKER["insts"][(name, kind)]
    sig, base = inst["signal"], inst["base"]
    n = min(len(sig), len(base))
    t0 = time.perf_counter()
    detect(method, sig[:n], base[:n], inst["sr"], k, floor, margin)
    return time.perf_counter() - t0


def perf_concurrency(names: list[str], methods: list[str], k: float, floor: float,
                     workers_list: list[int]) -> list[dict]:
    """多进程并发：同一批任务在不同 worker 数下的墙钟时间与加速比。"""
    ours, refs, insts = {}, {}, {}
    for n in names:
        o = load_ours(n)
        r = load_clip(n, "fffloat")
        if o is None or r is None:
            continue
        sr = 16000 if "mono16k" in n else 44100
        base = r
        sig_multi, _ = inject(base, sr, positions=5, seed=abs(hash(n)) % 100000)
        sig_slip, _ = inject_single(base, sr, "slip", len(base) // 2)
        insts[(n, "multi")] = {"signal": sig_multi, "base": base, "sr": sr}
        insts[(n, "slip")] = {"signal": sig_slip, "base": base, "sr": sr}
        ours[n] = o
        refs[n] = r

    tasks = [(n, kind, m, k, floor, EDGE_MARGIN) for n in ours for kind in ("multi", "slip")
             for m in methods]
    payload = {"ours": ours, "refs": refs, "insts": insts}
    rows = []
    for w in workers_list:
        t0 = time.perf_counter()
        if w == 1:
            _worker_init(payload)
            for t in tasks:
                _worker_task(t)
        else:
            ctx = mp.get_context("spawn")
            with ctx.Pool(processes=w, initializer=_worker_init,
                          initargs=(payload,)) as pool:
                pool.map(_worker_task, tasks, chunksize=1)
        dt = time.perf_counter() - t0
        rows.append({"workers": w, "tasks": len(tasks), "wallSeconds": dt,
                     "tasksPerSec": len(tasks) / dt})
    base = rows[0]["wallSeconds"] if rows else 1.0
    for r in rows:
        r["speedupVs1"] = base / r["wallSeconds"]
        r["efficiency"] = r["speedupVs1"] / r["workers"]
    return rows


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def environment() -> dict:
    import subprocess

    def ver(cmd):
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                               errors="replace")
            return (p.stdout or p.stderr).strip().splitlines()[0]
        except Exception:                                     # noqa: BLE001
            return "n/a"

    import numpy
    import soundfile
    return {
        "os": f"{platform.system()} {platform.release()} ({platform.version()})",
        "cpu": platform.processor(),
        "cpuCount": os.cpu_count(),
        "python": platform.python_version(),
        "numpy": numpy.__version__,
        "soundfile": f"{soundfile.__version__} (libsndfile {soundfile.__libsndfile_version__})",
        "ffmpeg": ver(["ffmpeg", "-version"]),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="评测带定位能力的解码偏差检测")
    ap.add_argument("--target-fpr", type=float, default=0.05)
    ap.add_argument("--positions", type=int, default=5)
    ap.add_argument("--skip-perf", action="store_true")
    ap.add_argument("--pair", help="单对分析模式：给出片段名，逐参照报告疑点区间")
    ap.add_argument("--k", type=float, default=K_FIXED, help="--pair 模式下的鲁棒阈值 k")
    ap.add_argument("--floor", type=float, default=None, help="--pair 模式下的地板（缺省取标定值）")
    args = ap.parse_args()

    names = dataset_names()
    if not names:
        print("数据集为空：先跑 scripts/diag/make_dataset.py")
        return 1
    print(f"数据片段 {len(names)} 个：{', '.join(names)}")

    if args.pair:
        return report_pair(args.pair, args.k, args.floor)

    env = environment()
    print(f"环境：{env['os']} | CPU {env['cpu']} × {env['cpuCount']} 逻辑核 | "
          f"Python {env['python']} | numpy {env['numpy']} | {env['soundfile']}")

    print("【1/4】横向一致性（真实素材，4 条解码路径两两对齐）")
    cons = run_consistency(names)

    print("【2/4】对齐配对：噪声底取**参照互比**，本库 vs 参照作为待定位疑点")
    ref_pairs = aligned_ref_pairs(names)
    ours_pairs = aligned_ours_pairs(names)
    floor = collect_noise_floor(ref_pairs)
    print(f"  参照互比 {len(ref_pairs)} 对（噪声底）；本库 vs 参照 {len(ours_pairs)} 对（疑点）")
    print("  噪声底 P99.9：" + ", ".join(f"{m}={floor[m]:.4g}" for m in SERIES_METHODS))

    print("【3/4】构造注入真值集，按误报目标标定并测检出/定位")
    insts = build_instances(names, positions=args.positions)
    print(f"  实例 {len(insts)} 个，真值 {sum(len(i['faults']) for i in insts)} 条")
    picks = calibrate(ref_pairs, floor, args.target_fpr)
    rows_clean = []
    for method in DETECTORS:
        rows_clean.append(evaluate_method(method, picks[method]["k"],
                                         picks[method]["floor"], ref_pairs, insts,
                                         ours_pairs))
    for r in rows_clean:
        loc = r["localizationErrMsMedian"]
        print(f"  {METHODS[r['method']]:22s} α={picks[r['method']].get('alpha', '—'):<5} "
              f"检出 {r['recall']:6.1%}  漏报 {r['fnr']:6.1%}  精准 {r['precision']:6.1%}  "
              f"误报(参照互比) {r['cleanPairsFlagged']}/{r['cleanPairs']}  "
              f"本库偏差检出 {r['oursPairsFlagged']}/{r['oursPairs']}  "
              f"定位中位 {'—' if loc is None else f'{loc:.2f}'} ms")

    perf_rows, scale_rows, conc_rows = [], {}, []
    if not args.skip_perf:
        print("【4/4】性能：耗时/内存/伸缩/并发")
        big = None
        for n in names:
            o, r = load_ours(n), load_clip(n, "fffloat")
            if o is None or r is None or "mono16k" in n:
                continue
            sr = 44100
            lag = estimate_lag(o, r, max_lag=8192, sr_hint=sr)
            x, y = apply_lag(o, r, lag)
            if big is None or len(x) > len(big[0]):
                big = (x, y, sr, n, margin_for(lag))
        if big:
            x, y, sr, nm, mg = big
            print(f"  性能样本：{nm}（{len(x)} 帧 / {x.shape[1]} ch / "
                  f"{len(x) / sr:.1f} 秒音频）")
            for method in DETECTORS:
                row = perf_method(method, x, y, sr, k=picks[method]["k"],
                                  floor=picks[method]["floor"], margin=mg)
                perf_rows.append(row)
                print(f"    {method:11s} {row['medianMs']:8.1f} ms  "
                      f"{row['realtimeFactor']:6.2f}× 实时  "
                      f"峰值内存 {row['peakMemMB']:6.1f} MB")
                if method in ("res-rms", "band-ratio"):
                    scale_rows[method] = perf_scaling(
                        method, x, y, sr, [5, 10, 20, 30],
                        k=picks[method]["k"], floor=picks[method]["floor"], margin=mg)
            # 并发测试只用前 3 个片段：worker 之间要传输整份 PCM，
            # 素材越多，传输开销越会淹没真实的并行收益（那是 IPC 的性质，不是算法的）
            conc_rows = perf_concurrency(
                names[:3], ["res-rms", "res-peak", "band-ratio"],
                picks["res-rms"]["k"], picks["res-rms"]["floor"], [1, 2, 4, 6])
            for r in conc_rows:
                print(f"    并发 {r['workers']} 进程：{r['wallSeconds']:6.2f} s，"
                      f"加速 {r['speedupVs1']:5.2f}×，效率 {r['efficiency']:5.0%}")

    payload = {
        "environment": env,
        "dataset": {"clips": names, "instances": len(insts),
                    "faults": sum(len(i["faults"]) for i in insts),
                    "refPairs": len(ref_pairs), "oursPairs": len(ours_pairs)},
        "noiseFloorP999": floor,
        "consistency": cons,
        "calibration": {"targetFpr": args.target_fpr, "picks": picks},
        "metricsIsolated": rows_clean,
        "performance": perf_rows,
        "scaling": scale_rows,
        "concurrency": conc_rows,
    }
    REPORTS.mkdir(parents=True, exist_ok=True)
    (REPORTS / "localize_eval.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"结果已写入 {REPORTS / 'localize_eval.json'}")
    return 0


def report_pair(name: str, k: float, floor: float | None = None) -> int:
    """单对分析：对给定片段，逐个参照报告对齐量、全局量与**疑点区间**。

    这是"疑点定位"的实际用法：同一个片段、四条解码路径，看分歧落在哪里。
    地板缺省时按"干净配对的 P99.9"就地标定（同一次运行里现算），
    避免使用者手填一个数值 —— 没有地板的输出在这一层没有意义。
    """
    ours = load_ours(name)
    if ours is None:
        print(f"缺本库输出：{name}")
        return 1
    sr = 16000 if "mono16k" in name else 44100

    base_floor = {}
    if floor is None:
        ref_pairs = aligned_ref_pairs(dataset_names())
        base_floor = collect_noise_floor(ref_pairs)
        if not ref_pairs:
            print("无参照互比配对可用于标定地板：请先跑 make_dataset.py")
            return 1
    print(f"片段 {name}（{len(ours)} 帧 / {ours.shape[1]} ch / {sr} Hz），k={k}"
          + (f"，地板={floor}" if floor is not None else "，地板=1×噪声底 P99.9"))

    for tag in ("fffloat", "fffixed", "sndfile"):
        ref = load_clip(name, tag)
        if ref is None:
            continue
        lag = estimate_lag(ours, ref, max_lag=8192, sr_hint=sr)
        x, y = apply_lag(ours, ref, lag)
        mg = margin_for(lag)
        m = pair_metrics(ours, ref, sr)
        print(f"\n  参照 {tag}：位移 {lag} 样本（{lag * 1000.0 / sr:.1f} ms），"
              f"重叠 {len(x)} 帧（{len(x) / sr:.2f} 秒），"
              f"整体 RMS 差 {m.get('rmsRelDb', 0):.3f} dB，"
              f"残差/信号 RMS {m.get('residualRmsOverSignalRms', 0):.3e}，"
              f"逐窗能量比 P95 {m.get('winRatioDbP95', 0):.3f} dB")
        for method in DETECTORS:
            fl = 0.0 if method == "global" else (
                floor if floor is not None else base_floor.get(method, 0.0))
            s = detect(method, x, y, sr, k, fl, mg)
            if not s:
                print(f"    {method:11s} 无疑点")
                continue
            brief = ", ".join(
                f"[{a.start / sr:.3f}–{a.end / sr:.3f}s {a.label} {a.score:.3g}]"
                for a in s[:6])
            more = "" if len(s) <= 6 else f" …共 {len(s)} 段"
            print(f"    {method:11s} {len(s)} 段：{brief}{more}")

    # 对照组：参照之间互比 —— 它应当"干净"（没有疑点），
    # 否则说明地板没标定好，上面那些疑点也就不可信
    print("\n  [对照] 参照互比（预期：干净）")
    for ta, tb in (("fffloat", "fffixed"), ("fffloat", "sndfile")):
        a, b = load_clip(name, ta), load_clip(name, tb)
        if a is None or b is None:
            continue
        lag = estimate_lag(a, b, max_lag=8192, sr_hint=sr)
        x, y = apply_lag(a, b, lag)
        mg = margin_for(lag)
        hits = []
        for method in DETECTORS:
            fl = 0.0 if method == "global" else (
                floor if floor is not None else base_floor.get(method, 0.0))
            n = len(detect(method, x, y, sr, k, fl, mg))
            if n:
                hits.append(f"{method}×{n}")
        print(f"    {ta} vs {tb}（lag={lag}）："
              + ("无疑点 ✓" if not hits else "疑点 " + ", ".join(hits)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
