#!/usr/bin/env python3
"""带定位能力的解码偏差检测器：六种方法的集合。

【为什么需要"一组"方法，而不是一个"最好的"】

    "疑点检测"这四个字藏着一个含糊：检出与定位是**两种不同的能力**。
    本文件把方法按"定位能力由弱到强、覆盖的故障类型由窄到宽"排成一条谱：

        M0 global       全局标量（能量比/峰值/最大绝对差）—— **没有定位能力**，
                        它是对照组：用来证明"只看全局量"会漏掉什么
        M1 block-rms    定窗能量比 —— 最简单能定位的方法，定位粒度 = 窗宽
        M2 res-rms      对齐后残差的滑窗相对 RMS —— 对增益/静音/丢帧都敏感
        M3 res-peak     对齐后残差的滑窗相对峰值 —— 捕瞬时脉冲（能量小但尖）
        M4 band-ratio   分频带能量比 —— 能定位**且能指出"哪一段频率错了"**
        M5 coherence    逐窗归一化互相关系数 —— 捕时间/相位错乱，对纯增益不敏感

【指标一律无量纲，这是可移植的前提】

    M2/M3 若直接用"残差幅度"当指标，阈值就会随素材电平变化。因此两者都除以
    **同窗参照电平**：M2 = rms(res)/rms(ref)，M3 = peak(res)/rms(ref)。
    M1/M4 是分贝比、M5 是 1−ρ，本身无量纲。这样一套阈值可跨素材、跨采样率。

【阈值为什么必须有两道：统计异常 ≠ 缺陷】

    只用"中位数 + k×MAD"会有一个致命后果（本次实测）：两套**都正确**的解码器
    输出之间处处都有微小差异，"统计上离群"的窗永远存在。判据必须再加一道
    **绝对地板**：

        判为疑点  ⟺  值 > max(中位数 + k×1.4826·MAD,  地板)

    地板由真实噪声底标定：在"本库 vs 各参照"的干净配对上统计指标分布，
    取 P99.9 作为 1 倍地板，再乘灵敏度系数 α（由 evaluate.py 按误报率目标挑）。
    于是各方法是在**同等误报代价**下比检出率，而不是在各自的运气上比。

【两类窗必须被屏蔽，否则噪声底高到阈值失效】

    · **静音窗**：相对指标在静音处没有意义（参照窗 RMS 若为 1e-9，
      任何微小残差都会算出 +∞ dB）。实测不屏蔽时噪声底被抬到 53.6 dB。
    · **边界窗**：首尾各有一段是"一边有内容、另一边是编码器延迟/填充"——
      那是不同解码器对 gapless 的**策略差异**，不是解码差异。实测不屏蔽时
      噪声底 res-rms=100%、block-rms=53.6 dB，全部方法检出率塌到 0%。
      边界宽度取 `3×1152 + |位移|`：位移越大，两边的"多出来/被裁掉"越多。
"""

from __future__ import annotations

import numpy as np

from diag_common import frame_peak, frame_rms, merge_intervals, robust_threshold

#: 方法名 → 中文说明（报告里直接引用）
METHODS: dict[str, str] = {
    "global": "M0 全局标量（无定位）",
    "block-rms": "M1 定窗能量比",
    "res-rms": "M2 对齐残差滑窗 RMS",
    "res-peak": "M3 对齐残差滑窗峰值",
    "band-ratio": "M4 分频带能量比",
    "coherence": "M5 逐窗归一化互相关",
}

#: 分频带方法的频带划分（Hz）。上限按采样率截断。
BANDS: list[tuple[str, float, float]] = [
    ("低频<1k", 0.0, 1000.0),
    ("中低1-4k", 1000.0, 4000.0),
    ("中高4-8k", 4000.0, 8000.0),
    ("高频>8k", 8000.0, 1e9),
]

#: 需要"分布 + 地板"判据的方法（M0 走自己的绝对判据，不在此列）
SERIES_METHODS = ("block-rms", "res-rms", "res-peak", "band-ratio", "coherence")

#: 边界屏蔽的基础宽度（样本）= 3 倍 MPEG1 帧长（1152×3 = 3456，44.1kHz 下 78 ms）。
#: 覆盖编码器延迟（约 1105）+ 末尾填充帧的合理上限。
EDGE_MARGIN: int = 1152 * 3


class Suspect:
    """一个疑点区间（对齐后坐标）。"""

    def __init__(self, start: int, end: int, score: float, label: str = "") -> None:
        self.start = int(start)
        self.end = int(end)
        self.score = float(score)
        self.label = label

    def __repr__(self) -> str:  # pragma: no cover
        return f"Suspect({self.start}, {self.end}, {self.score:.4g}, {self.label!r})"


class Block:
    """一条指标序列及其坐标（分频带方法每带一条）。"""

    def __init__(self, values: np.ndarray, centers: np.ndarray, win: int, label: str) -> None:
        self.values = values
        self.centers = centers
        self.win = win
        self.label = label


def _ch_reduce(mat: np.ndarray, how: str) -> np.ndarray:
    """按**声道**归约：偏差类取 max（不放过单声道故障），相干类取 min。

    矩阵形状是 (声道数, 窗数)，因此归约轴是 0。写错成 axis=1 会按帧归约，
    把几千个窗压成"每声道一个数"，阈值随之失效、结果恒为空
    （实测踩过：M1/M2/M3/M5 全线 0 检出，而现象看起来"什么都没发生"）。
    """
    if mat.ndim == 1:
        return mat
    if mat.shape[0] == 0:
        return np.array([])
    return mat.max(axis=0) if how == "max" else mat.min(axis=0)


def _activity(ref: np.ndarray, win: int, hop: int) -> np.ndarray:
    """标出"有内容"的窗：参照的窗 RMS ≥ 全段 RMS 的 1%（且不低于 1e-7）。

    静音窗里的**相对**指标没有意义：参照窗 RMS 若为 1e-9，任何微小残差
    都会算出 100%（0 dB → +∞ dB）的比值。故障注入本身也刻意避开静音段
    （见 inject.py），两边口径因此一致。
    """
    mono = ref.mean(axis=1)
    sv, _ = frame_rms(mono, win, hop)
    g = float(np.sqrt(np.mean(mono ** 2))) or 1e-12
    return sv >= max(1e-7, 0.01 * g)


def _mask(values: np.ndarray, centers: np.ndarray, ref: np.ndarray, win: int, hop: int,
          margin: int) -> tuple[np.ndarray, np.ndarray]:
    """把静音窗与边界窗的指标置为 NaN（NaN 与阈值比较恒为 False，判据自动跳过）。"""
    act = _activity(ref, win, hop)
    n = min(len(values), len(act), len(centers))
    if n == 0:
        return np.array([]), np.array([])
    c = centers[:n]
    keep = act[:n] & (c >= margin) & (c <= len(ref) - margin)
    v = values[:n].astype(np.float64, copy=True)
    v[~keep] = np.nan
    return v, c


# ---------------------------------------------------------------------------
# 各方法的指标序列
# ---------------------------------------------------------------------------


def m1_block_rms(ours: np.ndarray, ref: np.ndarray, sr: int,
                 margin: int = EDGE_MARGIN) -> list[Block]:
    """M1：定窗能量比（dB）。定位粒度 = 窗宽（50ms），不需要对齐。"""
    win = max(64, int(0.05 * sr))
    mat, centers = [], np.array([])
    for c in range(ours.shape[1]):
        ox, oc = frame_rms(ours[:, c], win, win)
        ry, _ = frame_rms(ref[:, c], win, win)
        n = min(len(ox), len(ry))
        if n == 0:
            return []
        # 1e-9 防静音段 0 除；该量级远低于任何有意义的分贝差
        mat.append(np.abs(20.0 * np.log10((ox[:n] + 1e-9) / (ry[:n] + 1e-9))))
        centers = oc[:n]
    v, c = _mask(_ch_reduce(np.stack(mat), "max"), centers, ref, win, win, margin)
    return [Block(v, c, win, "block-rms")]


def m2_res_rms(ours: np.ndarray, ref: np.ndarray, sr: int,
               margin: int = EDGE_MARGIN) -> list[Block]:
    """M2：对齐后残差的滑窗相对 RMS = rms(res)/rms(ref)（无量纲）。"""
    win = max(64, int(0.02 * sr))
    hop = max(16, int(0.005 * sr))
    res = ours - ref
    mat, centers = [], np.array([])
    for c in range(ours.shape[1]):
        rv, rc = frame_rms(res[:, c], win, hop)
        sv, _ = frame_rms(ref[:, c], win, hop)
        n = min(len(rv), len(sv))
        if n == 0:
            return []
        mat.append(rv[:n] / (sv[:n] + 1e-9))
        centers = rc[:n]
    v, c = _mask(_ch_reduce(np.stack(mat), "max"), centers, ref, win, hop, margin)
    return [Block(v, c, win, "res-rms")]


def m3_res_peak(ours: np.ndarray, ref: np.ndarray, sr: int,
                margin: int = EDGE_MARGIN) -> list[Block]:
    """M3：对齐后残差的滑窗相对峰值 = peak|res|/rms(ref)（捕瞬时脉冲）。"""
    win = max(32, int(0.01 * sr))
    hop = max(8, int(0.0025 * sr))
    res = ours - ref
    mat, centers = [], np.array([])
    for c in range(ours.shape[1]):
        pv, pc = frame_peak(res[:, c], win, hop)
        sv, _ = frame_rms(ref[:, c], win, hop)
        n = min(len(pv), len(sv))
        if n == 0:
            return []
        mat.append(pv[:n] / (sv[:n] + 1e-9))
        centers = pc[:n]
    v, c = _mask(_ch_reduce(np.stack(mat), "max"), centers, ref, win, hop, margin)
    return [Block(v, c, win, "res-peak")]


def m4_band_ratio(ours: np.ndarray, ref: np.ndarray, sr: int,
                  margin: int = EDGE_MARGIN) -> list[Block]:
    """M4：分频带能量比（dB），每带一条序列 —— 定位 + 指出"哪段频率错了"。

    除静音/边界外还要屏蔽**空频带**：某带参照能量若只占该帧总能量的
    −40 dB 以下，它的比值由数字噪声决定（实测 54 dB 量级），没有信息量。
    """
    win = 4096 if sr >= 32000 else 1024
    hop = win // 4
    window = np.hanning(win)
    freqs = np.fft.rfftfreq(win, d=1.0 / sr)
    sel_bands = [(name, sel) for name, lo, hi in BANDS
                 if (sel := (freqs >= lo) & (freqs < hi)).any()]
    if not sel_bands:
        return []

    per_band: list[tuple[str, np.ndarray, np.ndarray]] = []
    for bname, sel in sel_bands:
        mats, centers = [], np.array([])
        for c in range(ours.shape[1]):
            ox, rx = ours[:, c], ref[:, c]
            n = min(len(ox), len(rx))
            starts = np.arange(0, n - win + 1, hop)
            if starts.size == 0:
                continue
            idx = starts[:, None] + np.arange(win)[None, :]
            fo = np.abs(np.fft.rfft(ox[idx] * window, axis=1)) ** 2
            fr = np.abs(np.fft.rfft(rx[idx] * window, axis=1)) ** 2
            eo = fo[:, sel].sum(axis=1)
            er = fr[:, sel].sum(axis=1)
            total = fr.sum(axis=1) + 1e-20
            db = np.abs(10.0 * np.log10((eo + 1e-20) / (er + 1e-20)))
            db[er < 1e-4 * total] = np.nan            # 空频带：比值无意义
            mats.append(db)
            centers = starts + win // 2
        if mats:
            v, cc = _mask(_ch_reduce(np.stack(mats), "max"), centers, ref, win, hop, margin)
            per_band.append((bname, v, cc))
    if not per_band:
        return []
    # 带间最大值作为"总序列"（噪声底统计用它），各带序列保留（供标签）。
    # 手写逐元素 nan-aware 取最大：np.nanmax 遇到"整列皆 NaN"会发 RuntimeWarning，
    # 而整列皆 NaN 在这里是正常情况（该时刻所有带都被屏蔽）。
    stack = np.stack([p[1] for p in per_band])
    total = np.full(stack.shape[1], np.nan)
    for row in stack:
        total = np.where(np.isnan(total), row,
                         np.where(np.isnan(row), total, np.maximum(total, row)))
    out = [Block(total, per_band[0][2], win, "band-ratio")]
    for bname, vals, centers in per_band:
        out.append(Block(vals, centers, win, f"band {bname}"))
    return out


def m5_coherence(ours: np.ndarray, ref: np.ndarray, sr: int,
                 margin: int = EDGE_MARGIN) -> list[Block]:
    """M5：逐窗归一化互相关，指标 1−ρ（对时间/相位错乱敏感，对纯增益不敏感）。"""
    win = max(64, int(0.05 * sr))
    hop = max(16, int(0.025 * sr))
    mat, centers = [], np.array([])
    for c in range(ours.shape[1]):
        ox, rx = ours[:, c], ref[:, c]
        n = min(len(ox), len(rx))
        starts = np.arange(0, n - win + 1, hop)
        if starts.size == 0:
            continue
        idx = starts[:, None] + np.arange(win)[None, :]
        a, b = ox[idx], rx[idx]
        num = (a * b).sum(axis=1)
        den = np.sqrt((a * a).sum(axis=1) * (b * b).sum(axis=1)) + 1e-20
        mat.append(1.0 - num / den)
        centers = starts + win // 2
    if not mat:
        return []
    v, c = _mask(_ch_reduce(np.stack(mat), "max"), centers, ref, win, hop, margin)
    return [Block(v, c, win, "coherence")]


def m0_global(ours: np.ndarray, ref: np.ndarray, sr: int) -> list[Suspect]:
    """M0：只看全局标量（对照组）。

    判据是**绝对**的（整体 RMS 相对差），因为它没有窗分布可以统计。
    命中时只能把整段报成疑点 —— 这正是它在定位维度上必然失败的根源。
    """
    rx = float(np.sqrt(np.mean(ours ** 2)))
    ry = float(np.sqrt(np.mean(ref ** 2))) or 1e-12
    return [Suspect(0, len(ours), abs(rx - ry) / ry, "global")]


SERIES_FUNCS = {
    "block-rms": m1_block_rms,
    "res-rms": m2_res_rms,
    "res-peak": m3_res_peak,
    "band-ratio": m4_band_ratio,
    "coherence": m5_coherence,
}


def series(method: str, ours: np.ndarray, ref: np.ndarray, sr: int,
           margin: int = EDGE_MARGIN) -> list[Block]:
    """取某方法的全部指标序列（不做阈值判断）。"""
    if method not in SERIES_FUNCS:
        raise KeyError(f"{method} 没有指标序列（M0 走绝对判据）")
    return SERIES_FUNCS[method](ours, ref, sr, margin)


def _flag_block(block: Block, k: float, floor: float) -> list[Suspect]:
    """对一条序列做"双判据"标记：统计离群 **且** 越过噪声地板。"""
    v, c = block.values, block.centers
    if v.size == 0:
        return []
    valid = ~np.isnan(v)
    if not valid.any():
        return []
    # 阈值只在**有效窗**上统计：NaN 不能参与中位数/MAD，否则中位数变 NaN、判据整体失效
    thr = max(robust_threshold(v[valid], k), floor)
    hot = np.where(v > thr)[0]
    if hot.size == 0:
        return []
    spans = [(int(c[i]) - block.win // 2, int(c[i]) + block.win // 2) for i in hot]
    merged = merge_intervals(spans, gap=block.win)
    out = []
    for s, e in merged:
        sel = [v[i] for i in hot if s <= c[i] <= e]
        out.append(Suspect(s, e, max(sel) if sel else thr, block.label))
    return out


def _dedup(spans: list[Suspect], gap: int) -> list[Suspect]:
    """按区间重叠合并（保留最高分，标签取并集）。"""
    if not spans:
        return []
    spans = sorted(spans, key=lambda s: s.start)
    out = [spans[0]]
    for s in spans[1:]:
        last = out[-1]
        if s.start <= last.end + gap:
            last.end = max(last.end, s.end)
            last.score = max(last.score, s.score)
            if s.label not in last.label:
                last.label = f"{last.label}|{s.label}"
        else:
            out.append(s)
    return out


def detect(method: str, ours: np.ndarray, ref: np.ndarray, sr: int,
           k: float = 4.0, floor: float = 0.0,
           margin: int = EDGE_MARGIN) -> list[Suspect]:
    """按方法名派发。入参必须是**已对齐、等长**的数组。

    `floor` 是绝对地板（由真实噪声底标定，见模块文档）；缺省 0 表示
    "只看统计离群" —— 那只适用于分析合成故障，不适用于真实素材。
    `margin` 是首尾屏蔽宽度；位移越大越要放大（见 EDGE_MARGIN 的说明）。
    """
    if ours.shape != ref.shape:
        raise ValueError(f"要求等长输入，实际 {ours.shape} vs {ref.shape}")
    if method == "global":
        s = m0_global(ours, ref, sr)
        return [x for x in s if x.score * 100.0 > k] if k > 0 else s
    out: list[Suspect] = []
    for b in series(method, ours, ref, sr, margin):
        out.extend(_flag_block(b, k, floor))
    return _dedup(out, gap=max(16, sr // 100))


DETECTORS = ("global", "block-rms", "res-rms", "res-peak", "band-ratio", "coherence")
