#!/usr/bin/env python3
"""向参照信号注入**已知位置、已知类型**的故障，为"检出率/误报率/定位偏差"造真值。

【为什么必须注入，而不是只用真实素材】

    "检出率""误报率""定位偏差"这三个词都隐含一个前提：**知道正确答案**。
    真实素材上没有正确答案 —— 我们只知道"两套解码器的输出不同"，
    不知道谁对、更不知道差异出现在第几个样本。因此：

        · 用**真实素材**回答：多实现之间的一致性如何、分歧落在哪里（→ 定位疑点）；
        · 用**注入真值**回答：检测器本身的能力有多强（→ 检出率/误报/定位偏差）。

    两者缺一不可：只有真实素材，就说不清"没检出"是素材干净还是检测器太钝；
    只有注入，就无法保证检测器在真实解码噪声下还站得住。

【注入的六类故障：每类对应一种真实可能】

    gain        增益偏移（某窗整体缩放）—— 对应缩放系数/反量化出错
    zero-gap    一小段被抹成静音 —— 对应丢帧、位池读空
    chan-swap   声道短暂互换 —— 对应立体声处理（MS/强度）分支写错通道
    click       瞬时脉冲 —— 对应单点样值写错、越界写
    band-cut    某频带被压 —— 对应缩放因子频带算错、IMDCT 频带错位
    slip        插入少量样本造成位移 —— **最苛刻的一类**：全局单一对齐假设被破坏，
                残差类方法会把位移之后的整段都报成疑点。它被单独统计，
                因为"报得又长又偏"与"没报"是两种不同的失败。

【注入位置怎么选：能量加权，避开静音】

    随机撒点在真实音乐上会大量落在静音段 —— 那里的故障**本来就不可检出**
    （残差近零、能量比无意义），把这种情况算成"漏报"是在冤枉检测器。
    因此从"局部能量排在前 20% 的位置"里挑，且彼此保持最小间隔，
    让六类故障都落在真正有内容的地方。
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

#: 故障类型 → 中文说明
KINDS: dict[str, str] = {
    "gain": "增益偏移",
    "zero-gap": "静音缺口（丢帧）",
    "chan-swap": "声道互换",
    "click": "瞬时脉冲",
    "band-cut": "频带压缩",
    "slip": "样本位移",
}

#: 注入时长（毫秒）
DURATION_MS: dict[str, float] = {
    "gain": 200.0,
    "zero-gap": 26.1,   # 一个 MPEG1 帧：1152 样本 @44.1kHz
    "chan-swap": 100.0,
    "click": 0.2,       # 脉冲本身极短（下文会用指数衰减拖出几个样本）
    "band-cut": 300.0,
    "slip": 1.5,        # 插入 64 个样本造成的位移区间
}


@dataclass
class Fault:
    """一条真值：故障类型 + 区间（对齐后坐标）+ 参数。"""

    kind: str
    start: int
    end: int
    severity: float
    note: str = ""

    def to_json(self) -> dict:
        return asdict(self)


def _active_positions(sig: np.ndarray, sr: int, count: int,
                      min_sep_ms: float = 400.0) -> list[int]:
    """挑 `count` 个"局部能量强"的位置（样本下标）。

    做法：算 50ms 窗能量，取能量 ≥ 80 分位的位置，贪心地按最小间隔散布。
    """
    win = max(64, int(0.05 * sr))
    hop = win
    mono = sig.mean(axis=1)
    n = len(mono)
    if n < win * 4:
        return [n // 2]
    starts = np.arange(0, n - win + 1, hop)
    energy = np.array([float(np.mean(mono[s:s + win] ** 2)) for s in starts])
    order = np.argsort(energy)[::-1]
    thresh = np.quantile(energy, 0.80)

    picked: list[int] = []
    min_sep = int(min_sep_ms / 1000.0 * sr)
    # 避开首尾：既避开 5% 的淡入淡出区，也避开检测器的边界屏蔽区
    # （localize.EDGE_MARGIN）—— 否则注入的故障落在被屏蔽的窗里，
    # 会被记成"漏报"，那是在冤枉检测器。
    edge = max(int(n * 0.05), 1152 * 3)
    for i in order:
        if energy[i] < thresh:
            break
        pos = int(starts[i] + win // 2)
        if pos < edge or pos > n - edge:
            continue
        if any(abs(pos - p) < min_sep for p in picked):
            continue
        picked.append(pos)
        if len(picked) >= count:
            break
    while len(picked) < count:                      # 素材太短时的兜底
        picked.append(int(n * (0.25 + 0.25 * len(picked))))
    return sorted(picked)


def _apply_one(kind: str, sig: np.ndarray, sr: int, pos: int,
               rng: np.random.Generator) -> tuple[np.ndarray, Fault]:
    """就地注入一条故障，返回 (新信号, 真值)。函数式：不改原数组。"""
    out = sig.copy()
    n = len(out)
    span = max(1, int(DURATION_MS[kind] / 1000.0 * sr))

    if kind == "gain":
        g = float(rng.choice([1.25, 0.8, 1.5, 0.6]))
        s, e = max(0, pos - span // 2), min(n, pos + span // 2)
        out[s:e] *= g
        return out, Fault(kind, s, e, g, f"×{g:g}")

    if kind == "zero-gap":
        s, e = max(0, pos - span // 2), min(n, pos + span // 2)
        out[s:e] = 0.0
        return out, Fault(kind, s, e, float(e - s), f"{e - s} 样本被抹零")

    if kind == "chan-swap":
        if out.shape[1] < 2:
            # 单声道没有声道可换：退化为"取反"（同样是写错分支才会有的后果）
            s, e = max(0, pos - span // 2), min(n, pos + span // 2)
            out[s:e] *= -1.0
            return out, Fault(kind, s, e, 1.0, "单声道退化为极性反转")
        s, e = max(0, pos - span // 2), min(n, pos + span // 2)
        out[s:e] = out[s:e][:, ::-1]
        return out, Fault(kind, s, e, 1.0, "L/R 互换")

    if kind == "click":
        s = min(max(0, pos), n - 1)
        amp = float(rng.choice([0.5, -0.5, 0.9]))
        tail = 8
        e = min(n, s + tail)
        decay = np.exp(-np.arange(e - s) / 2.0)
        out[s:e] += amp * decay[:, None]
        return out, Fault(kind, s, e, abs(amp), f"幅值 {amp:g}")

    if kind == "band-cut":
        s, e = max(0, pos - span // 2), min(n, pos + span // 2)
        seg = out[s:e]
        if len(seg) < 64:
            return out, Fault(kind, s, e, 0.0, "段太短，未注入")
        gain_hi = float(rng.choice([0.25, 0.05]))
        fc = 6000.0
        spec = np.fft.rfft(seg, axis=0)
        fr = np.fft.rfftfreq(len(seg), d=1.0 / sr)
        mask = (fr >= fc).astype(np.float64)
        scale = 1.0 - mask * (1.0 - gain_hi)
        out[s:e] = np.fft.irfft(spec * scale[:, None], n=len(seg), axis=0)
        return out, Fault(kind, s, e, gain_hi, f">{fc:.0f}Hz ×{gain_hi:g}")

    if kind == "slip":
        k = 64
        s = min(max(1, pos), n - 1)
        out = np.concatenate([out[:s], np.zeros((k, out.shape[1])), out[s:]])
        return out, Fault(kind, s, s + k, float(k), f"插入 {k} 样本")

    raise KeyError(kind)


def inject(sig: np.ndarray, sr: int, kinds: list[str] | None = None,
           positions: int = 3, seed: int = 20261006) -> tuple[np.ndarray, list[Fault]]:
    """在同一份信号上注入多条故障（**位置互不重叠**，便于逐条匹配）。

    返回 (注入后的信号, 真值列表)。`slip` 会改变长度，因此它单独注入
    （见 `inject_single`），不与其它故障混在一起 —— 否则后面所有真值的坐标
    都会平移，真值表就不可信了。
    """
    kinds = kinds or [k for k in KINDS if k != "slip"]
    rng = np.random.default_rng(seed)
    pos_list = _active_positions(sig, sr, positions)
    out = sig
    faults: list[Fault] = []
    for i, kind in enumerate(kinds):
        pos = pos_list[i % len(pos_list)]
        out, f = _apply_one(kind, out, sr, pos, rng)
        faults.append(f)
    return out, faults


def inject_single(sig: np.ndarray, sr: int, kind: str, pos: int,
                  seed: int = 20261006) -> tuple[np.ndarray, Fault]:
    """单独注入一条故障（`slip` 类必须走这条）。"""
    return _apply_one(kind, sig, sr, pos, np.random.default_rng(seed))


def save_truth(path: Path, faults: list[Fault], sr: int, meta: dict) -> None:
    """真值表落盘（JSON）：位置用样本下标与毫秒两种表示，便于人工核对。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "sampleRate": sr,
        "meta": meta,
        "faults": [dict(f.to_json(), startMs=f.start * 1000.0 / sr,
                        endMs=f.end * 1000.0 / sr) for f in faults],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def load_truth(path: Path) -> tuple[list[Fault], int, dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    faults = [Fault(f["kind"], f["start"], f["end"], f["severity"], f.get("note", ""))
              for f in payload["faults"]]
    return faults, int(payload["sampleRate"]), payload.get("meta", {})


if __name__ == "__main__":
    # 独立自检：注入后真值区间**确实**发生了变化，且未波及区间没被动过
    sr = 44100
    rng = np.random.default_rng(7)
    sig = np.cumsum(rng.standard_normal((sr, 2)), axis=0) * 0.1

    for kind in KINDS:
        out, f = inject_single(sig, sr, kind, pos=sr // 2)
        changed = np.flatnonzero(np.any(out != sig, axis=1)) if len(out) == len(sig) else None
        if changed is None:
            print(f"  {kind:10s} 长度 {len(sig)} → {len(out)}，真值 [{f.start}, {f.end}]")
            continue
        lo, hi = int(changed.min()), int(changed.max())
        ok = abs(lo - f.start) <= sr // 100 and abs(hi - f.end) <= sr // 100
        print(f"  {kind:10s} 真值 [{f.start}, {f.end}] 实际变化 [{lo}, {hi}] {'OK' if ok else 'FAIL'}")
