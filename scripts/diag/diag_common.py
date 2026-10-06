#!/usr/bin/env python3
"""带定位能力的解码偏差诊断 —— 公共设施。

【这套工具解决什么问题】

    本库的比对工具（`src/test/golden_test.cj`）给出的都是**全局标量**：
    整体能量比、最大绝对差、样本数。它们能回答"整体对不对"，**不能**回答
    "偏在哪一秒"。当一个素材出现"整体能量吻合、但局部峰值对不上"这类疑点时，
    必须具备**带定位**的检测手段，否则只能猜。

    本目录提供三件事：

        make_dataset.py  造数据集：ffmpeg/soundfile 参照解码 + 本库解码导出
        localize.py      检测器：M0..M5 六种方法，各自给出**疑点区间**
        inject.py        真值：向参照信号注入已知位置/类型的故障
        evaluate.py      指标与性能：检出率/误报/漏报/定位偏差 + 耗时/内存/吞吐/并发

【为什么必须有"对齐"这一步 —— 本文件最要紧的知识点】

    不同解码器对同一 MP3 的输出**长度天然不同**（合法差异，不是缺陷）：

        · LAME 在流首写入编码器延迟（576 样本/声道）、流尾补填充帧；
        · ffmpeg / libsndfile 会按 Xing/Info 的 gapless 信息把它们裁掉；
        · 本库输出**完整**帧序列，不裁剪。

    实测（1 秒 44.1kHz 立体声素材）：本库 46080 个交错样本，
    libsndfile 44100 个 —— 差 1980 个样本，全部落在首尾。

    因此"逐样本相减"之前**必须先估出这个位移**，否则错位的比较会把
    合法差异放大成满屏疑点。`estimate_lag()` 就是干这个的，它同时也是一个
    被评估的对象：对齐估错本身就是一种"定位偏差"。

【采样约定】

    一律 f32 交错，形状 (帧数, 声道数)。文件为裸字节流（无头），
    与 `testdata/golden/` 下的 `.f32le` 基准同口径。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

REPO = Path(__file__).resolve().parents[2]

#: 诊断工作区：所有中间产物与报告都落在这里。**已加入 .gitignore** ——
#: 它可能包含第三方版权素材的片段（从 musics/ 截取）与上百 MB 的 PCM，
#: 一律不得入库。
WORK = REPO / "eval_work"

CLIPS = WORK / "clips"          # 裁剪出的 MP3 片段（诊断输入）
REFS = WORK / "refs"            # 参照解码输出（ffmpeg×2 + libsndfile）
OURS = WORK / "ours"            # 本库解码输出（由 Cangjie 侧导出）
INJECTED = WORK / "injected"    # 注入故障后的信号 + 真值标注
REPORTS = WORK / "reports"      # 指标与定位报告

#: 本库导出清单：由 make_dataset.py 生成，被 src/test/diag_dump_test.cj 读取。
DUMP_LIST = REPO / "testdata" / "diag" / "dump.list"

#: 参照解码器（ffmpeg 的两条**不同**实现：浮点与定点）。
#: 它们同源但算法路径不同（浮点 vs 整数运算链），可用于交叉验证。
FFMPEG_DECODERS = {
    "fffloat": "mp3float",
    "fffixed": "mp3",
}

#: libsndfile 的 MP3 支持来自 libmpg123 —— 与 ffmpeg **不同血统**的第三方实现，
#: 是本次横向比对里最有价值的一条独立参照。
SNDFILE_NAME = "sndfile"


def ensure_dirs() -> None:
    """建好全部工作目录（幂等）。"""
    for d in (CLIPS, REFS, OURS, INJECTED, REPORTS):
        d.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# f32le 读写
# ---------------------------------------------------------------------------


def read_f32le(path: Path, channels: int) -> np.ndarray:
    """读裸 f32le，返回 (帧数, 声道数)。"""
    raw = np.fromfile(str(path), dtype="<f4")
    if raw.size % channels != 0:
        raise ValueError(f"{path} 样本数 {raw.size} 不是声道数 {channels} 的整数倍")
    return raw.reshape(-1, channels).astype(np.float64)


def write_f32le(path: Path, data: np.ndarray) -> None:
    """写裸 f32le（交错）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    np.asarray(data, dtype="<f4").tofile(str(path))


# ---------------------------------------------------------------------------
# 参照解码
# ---------------------------------------------------------------------------


def _run(cmd: list[str]) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        raise RuntimeError(f"命令失败（{p.returncode}）：{' '.join(cmd)}\n{p.stderr[-2000:]}")
    return p.stdout


def ffmpeg_decode(src: Path, dst: Path, decoder: str | None = None) -> dict:
    """用 ffmpeg 解码为裸 f32le，返回其自报的流信息。

    刻意用 `-f f32le` 而不是 wav：与我们的比对口径一致，且免去解析容器头。
    `decoder` 指定时用 `-c:a <name>` 强制走某条实现（mp3float / mp3）。
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-hide_banner", "-v", "error", "-y"]
    if decoder:
        cmd += ["-c:a", decoder]
    cmd += ["-i", str(src), "-f", "f32le", str(dst)]
    _run(cmd)
    return ffmpeg_probe(src)


def ffmpeg_probe(src: Path) -> dict:
    """读 ffprobe 的参数（采样率/声道/时长/解码器名）。"""
    import json

    out = _run([
        "ffprobe", "-hide_banner", "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=sample_rate,channels,duration,codec_name",
        "-of", "json", str(src),
    ])
    st = json.loads(out)["streams"][0]
    return {
        "sampleRate": int(st["sample_rate"]),
        "channels": int(st["channels"]),
        "duration": float(st.get("duration") or 0.0),
        "codec": st.get("codec_name", ""),
    }


def sndfile_decode(src: Path) -> tuple[np.ndarray, int]:
    """用 libsndfile（libmpg123 血统）解码。"""
    import soundfile as sf

    data, sr = sf.read(str(src), dtype="float32", always_2d=True)
    return data.astype(np.float64), int(sr)


# ---------------------------------------------------------------------------
# 对齐：估出参照与本库之间的整样本位移
# ---------------------------------------------------------------------------


def _box_decimate(sig: np.ndarray, factor: int) -> np.ndarray:
    """盒式（均值）降采样。

    【为什么不能直接 `sig[::factor]`】那是**丢样**而不是降采样：白噪声这类
    相邻样本不相关的信号，丢样后两路在"非 factor 整数倍"的位移上**完全不相关**，
    粗搜索会随机落点（实测：已知位移 1 被估成 -6160）。均值把 factor 个样本
    先低通再合成为一个，粗峰因此是**宽峰**，对亚粗格位移仍然稳定。
    """
    n = len(sig) - len(sig) % factor
    if n <= 0:
        return sig
    return sig[:n].reshape(-1, factor).mean(axis=1)


def _coarse_peaks(xd: np.ndarray, yd: np.ndarray, mc: int, seg_c: int, fac: int,
                  topk: int = 8) -> list[int]:
    """粗定位：返回**前 K 个**候选粗 lag（fac 的整数倍），而不是一个 argmax。

    【为什么不能只要 argmax】纯音素材（本仓库的合成测试音就是）的自相关是
    **周期性**的：峰峰等高，argmax 会在等价的峰之间任意挑一个，一旦挑到搜索
    边界（实测 fx_mono16k 得到 lag=-8047），整条逐样本对比就是垃圾 ——
    噪声底随之被抬到 100%，所有方法失效。取前 K 个候选、交给细级用
    "残差最小"定夺，才不受周期性影响。

    用 `yd` 的**中段**做模板：避开首尾静音/淡入淡出（那两处几乎不含对齐信息）。
    """
    start_c = max(mc, (len(yd) - seg_c) // 2)
    if start_c + seg_c + mc > len(xd):
        start_c = max(mc, len(xd) - seg_c - mc)
    if start_c - mc < 0 or start_c + seg_c + mc > len(xd):
        start_c = mc
        seg_c = min(len(yd), max(1, len(xd) - 2 * mc))
    if seg_c <= 0 or start_c + seg_c > len(yd):
        return [0]
    yseg_c = yd[start_c:start_c + seg_c]
    a_c = xd[start_c - mc:start_c + seg_c + mc]
    if len(a_c) < len(yseg_c) or len(yseg_c) == 0:
        return [0]
    cc = np.correlate(a_c, yseg_c, mode="valid")
    k = min(topk, cc.size)
    idx = np.argsort(cc)[::-1][:k]
    return [(int(i) - mc) * fac for i in idx]


def _coarse_lag(xd: np.ndarray, yd: np.ndarray, mc: int, seg_c: int, fac: int) -> int:
    """单个粗 lag（保留给"只想要一点锚"的调用方）。"""
    return _coarse_peaks(xd, yd, mc, seg_c, fac, topk=1)[0]


def estimate_lag(ours: np.ndarray, ref: np.ndarray, max_lag: int = 4096,
                 sr_hint: int = 44100, seg_seconds: float = 0.5) -> int:
    """估计 `ours` 相对 `ref` 的整样本位移（正数表示 ours 开头多出这么多样本）。

    两级收敛：粗级在盒式降采样的 8 倍格上定位，细级在全速率上收敛 ±8 样本。
    直接在全速率上搜 ±4096 要 (2·4096+1)×22050 ≈ 1.8 亿次乘加（数十毫秒起），
    两级法把它压到百万量级，代价是一次盒式低通 —— 值得。
    """
    x_raw = ours.mean(axis=1).astype(np.float64)
    y_raw = ref.mean(axis=1).astype(np.float64)
    # 差分版（预加重）：差分是 LTI，**不改变位移本身**，但让相关峰变尖锐
    x_dif = np.diff(x_raw)
    y_dif = np.diff(y_raw)

    seg = max(1024, int(seg_seconds * sr_hint))
    fac = 8
    seg_c = max(64, seg // fac)
    mc = max(1, max_lag // fac)

    # ------------------------------------------------------------------
    # 粗级：两条候选，各自独立，最后由细级仲裁
    #
    # 单一预处理**无法同时**覆盖两类信号（实测）：
    #   · 原始信号在宽带噪声（相邻样本不相关）上稳，但在低频主导的真实音乐上
    #     峰会弥散、argmax 锁到搜索边界（棕噪声：已知 576 被估成 -4088）；
    #   · 差分信号反之（白噪声：已知 1 被估成 -1064）。
    # 因此两条都提，交给细级用"谁的相关峰更尖锐"来裁决 —— 差分对两类信号
    # 都能给出尖锐峰，所以细级一律在差分域打分。
    # ------------------------------------------------------------------
    cands = _coarse_peaks(_box_decimate(x_raw, fac), _box_decimate(y_raw, fac),
                          mc, seg_c, fac)
    cands += _coarse_peaks(_box_decimate(x_dif, fac), _box_decimate(y_dif, fac),
                           mc, seg_c, fac)
    # 去重；同分或同格时优先靠近 0 的 lag（真实位移只来自编码器延迟与填充，
    # 量级在数千样本内；周期性素材上"最小位移"是最稳的偏向）
    cands = sorted(set(cands), key=lambda d: abs(d))

    # 细级：在每条候选的 ±1 粗格内全速率搜索，判据是**归一化残差最小** ——
    # 直接优化"我们要拿去比较的那个量"。用原始信号（不是差分信号）算残差：
    # 差分域的峰对相位不敏感，无法区分"相位对齐"与"差半个周期"。
    start = max(seg, len(y_raw) // 2)
    if start + seg > len(y_raw):
        start = max(0, len(y_raw) - seg)
    yseg = y_raw[start:start + seg]
    ynorm = float(np.sqrt(np.dot(yseg, yseg)))
    if ynorm <= 0 or len(yseg) == 0:
        return 0

    def res_at(d: int) -> float | None:
        a0 = d + start
        if a0 < 0 or a0 + seg > len(x_raw):
            return None
        r = x_raw[a0:a0 + seg] - yseg
        return float(np.sqrt(np.dot(r, r))) / ynorm

    # 第一轮：每条候选 ±1 个粗格
    best_lag, best_res = (cands[0] if cands else 0), np.inf
    for coarse in cands:
        for d in range(coarse - fac, coarse + fac + 1):
            s = res_at(d)
            if s is not None and s < best_res - 1e-12:
                best_res, best_lag = s, d

    # 第二轮：围绕胜者再扩 ±4 个粗格。
    # 周期信号上粗峰与"真实最小残差点"可能差若干粗格（正弦周期 44.1 样本不是
    # 整数，粗格 8 样本），只修 ±1 格会停在残差 20% 的次优点上（实测）。
    lo = max(-max_lag, best_lag - 4 * fac)
    hi = min(max_lag, best_lag + 4 * fac)
    for d in range(lo, hi + 1):
        s = res_at(d)
        if s is not None and s < best_res - 1e-12:
            best_res, best_lag = s, d
    return best_lag


def apply_lag(ours: np.ndarray, ref: np.ndarray, lag: int) -> tuple[np.ndarray, np.ndarray]:
    """按 lag 把两路裁成等长可逐样本比较的序列。"""
    if lag >= 0:
        x = ours[lag:]
        n = min(len(x), len(ref))
        return x[:n], ref[:n]
    y = ref[-lag:]
    n = min(len(ours), len(y))
    return ours[:n], y[:n]


# ---------------------------------------------------------------------------
# 窗口统计与鲁棒阈值
# ---------------------------------------------------------------------------


def frame_rms(sig: np.ndarray, win: int, hop: int) -> tuple[np.ndarray, np.ndarray]:
    """滑窗 RMS。返回 (每窗值, 每窗中心样本下标)。"""
    if len(sig) < win:
        return np.array([]), np.array([])
    csum = np.concatenate([[0.0], np.cumsum(sig * sig)])
    starts = np.arange(0, len(sig) - win + 1, hop)
    sums = csum[starts + win] - csum[starts]
    return np.sqrt(sums / win), starts + win // 2


def frame_peak(sig: np.ndarray, win: int, hop: int) -> tuple[np.ndarray, np.ndarray]:
    """滑窗峰值 |·|。用 stride 视图做，避免 Python 循环。"""
    if len(sig) < win:
        return np.array([]), np.array([])
    starts = np.arange(0, len(sig) - win + 1, hop)
    idx = starts[:, None] + np.arange(win)[None, :]
    peaks = np.abs(sig[idx]).max(axis=1)
    return peaks, starts + win // 2


def robust_threshold(values: np.ndarray, k: float) -> float:
    """中位数 + k × 1.4826·MAD 的鲁棒上界。

    用 MAD 而不是标准差：疑点本身是离群点，会**抬高**标准差，
    让阈值被自己抬走（这正是 M1/M2 要避免的自掩蔽）。
    """
    if values.size == 0:
        return float("inf")
    med = float(np.median(values))
    mad = float(np.median(np.abs(values - med)))
    return med + k * 1.4826 * mad


def merge_intervals(spans: list[tuple[int, int]], gap: int) -> list[tuple[int, int]]:
    """合并间隔小于 gap 的区间（同一疑点被多窗命中时不该报成多个）。"""
    if not spans:
        return []
    spans = sorted(spans)
    out = [list(spans[0])]
    for s, e in spans[1:]:
        if s - out[-1][1] <= gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def sample_to_ms(idx: int, sample_rate: int) -> float:
    return idx * 1000.0 / sample_rate


# ---------------------------------------------------------------------------
# 自检：对齐必须正确，否则后面所有定位都是错的
# ---------------------------------------------------------------------------


def selftest() -> int:
    """验证 estimate_lag 在已知位移上能精确恢复。

    这条不是形式主义的自测：对齐是本工具链的**地基**，它错了，
    后续"定位偏差"的每一列数字都不可信，而那种错又不会自己喊出来。
    """
    rng = np.random.default_rng(20261006)
    n = 80000                 # 约 1.8 秒 @44.1kHz
    sr = 44100
    t = np.arange(n) / sr
    # 三条代表性信号：宽带不相关、低频主导、**周期**（最难，峰峰等高）
    makers = {
        "白噪声": lambda: rng.standard_normal((n, 2)) * 0.2,
        "有色噪声(近似音乐)": lambda: _brown(rng, n),
        "纯音 1kHz(周期)": lambda: np.stack([np.sin(2 * np.pi * 1000 * t)] * 2, axis=1) * 0.5,
    }
    fails = 0
    for kind, maker in makers.items():
        for d in (0, 1, 576, 1105, 1980, -529, 4096, -4096):
            y = maker()
            x = np.concatenate([np.zeros((d, 2)), y]) if d >= 0 else y[-d:]
            got = estimate_lag(x, y)
            xa, ya = apply_lag(x, y, got)
            # 残差只取**中段**：本用例的前缀是人为补的零，只有在错位量超过补零长度时
            # 才会污染首部 —— 那是构造方式带来的边界效应，不是对齐的错误。
            # 检测器统计指标时同样以窗为单位、并以活动窗屏蔽边界/静音（见 localize.py）。
            half = len(ya) // 4
            xs, ys = xa[half:len(ya) - half], ya[half:len(ya) - half]
            res = (float(np.sqrt(np.mean((xs - ys) ** 2))) /
                   (float(np.sqrt(np.mean(ys ** 2))) or 1.0))
            # 判据：位移精确恢复，**或**中段对齐残差 < 2%。
            # 后者是周期信号的必要放宽：差整数个周期在"逐样本比较"意义下完全等价
            # （实测 1kHz 纯音的 664 与 1105 相差 441 = 整 10 个周期），
            # 硬要求 lag 相等是在考一个与用途无关的指标。
            ok = (got == d) or res < 0.02
            print(f"  [{kind}] 已知位移 {d:>6} → 估计 {got:>6}，对齐残差 {res:.4g}  "
                  f"{'OK' if ok else 'FAIL'}")
            fails += 0 if ok else 1
    print(f"自检{'通过' if fails == 0 else f'失败 {fails} 项'}")
    return 1 if fails else 0


def _brown(rng: np.random.Generator, n: int) -> np.ndarray:
    """棕噪声（累积和），低频主导，用来代表真实音乐的相关性。"""
    y = np.cumsum(rng.standard_normal((n, 2)), axis=0)
    return y / (np.abs(y).max() + 1e-12) * 0.8


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        raise SystemExit(selftest())
    print(__doc__)
