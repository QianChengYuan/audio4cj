#!/usr/bin/env python3
"""合成探针：把"偏差在哪一段代码"从频谱与时间两个方向夹出来。

【为什么要造这么一组输入】

    直接读 2000 行解码内核找 bug 是最慢的路。更快的路是**控制输入、看响应**：
    每条探针只压一条代码路径，偏差出现与否就能反推是哪条路径错了。

        tone_500 / 2000 / 5000 / 8000 / 10000 / 12000 / 15000 Hz
            稳态单音。若**某个频段**的纯音本身就错 → 反量化 / 标度因子频带映射 /
            抗混叠 / 合成滤波的频带相关错误（与时间无关）。
            若各频段纯音都对，则问题不在稳态路径。

        noise       宽带噪声，所有频带同时激励，最能暴露"频带串扰"类错误
        click_train 每 0.5 秒一个瞬态 → 强制编码器使用**短块**（block_type=2）
                    与窗切换。若只有它错、纯音对，则缺陷在短块/混合块路径。
        burst       噪声突发（块边界与瞬态同时压），补 click 的宽频版本

【怎么读输出】

    · 残差/信号 RMS：整体差异（<1e-3 才算达标 —— ffmpeg 浮点 vs 定点是 1.1e-3，
      libmpg123 vs ffmpeg 是 7.8e-7）
    · 最大谱偏差与所在频率：指出"哪个频段错"。只报参照谱显著（>−40 dBFS）的频点，
      否则会被数字噪声底部的垃圾差值主导
"""

from __future__ import annotations

import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from diag_common import (DUMP_LIST, OURS, REPO, WORK, apply_lag, estimate_lag,
                         read_f32le, write_f32le)                     # noqa: E402

PROBES = WORK / "probes"
SR = 44100
DUR = 3.0
N = int(SR * DUR)


def _write_wav(path: Path, mono: np.ndarray) -> None:
    x = np.clip(mono, -1.0, 1.0)
    pcm = (x * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def _signals() -> dict[str, np.ndarray]:
    rng = np.random.default_rng(20261006)
    t = np.arange(N) / SR
    fade = np.minimum(1.0, np.minimum(t, DUR - t) / 0.02)      # 20ms 淡入淡出，避免边界爆音
    out: dict[str, np.ndarray] = {}
    for f in (500, 2000, 5000, 8000, 10000, 12000, 15000):
        out[f"tone_{f}"] = 0.5 * np.sin(2 * np.pi * f * t) * fade
    # 顶部频带的稳态探针：用来区分"最高几个子带本身解错"与"只在瞬态才错"
    for f in (16000, 17000, 18000, 20000):
        out[f"tone_{f}"] = 0.5 * np.sin(2 * np.pi * f * t) * fade
    out["noise"] = 0.2 * rng.standard_normal(N) * fade
    # 14–20kHz 限带噪声（稳态）：顶部频带的"有内容但不瞬态"对照
    hi = rng.standard_normal(N)
    spec = np.fft.rfft(hi)
    fr = np.fft.rfftfreq(N, d=1.0 / SR)
    spec[(fr < 14000) | (fr > 20000)] = 0
    out["noise_hi"] = 0.35 * np.fft.irfft(spec, n=N) * fade
    # 瞬态串：每 0.5s 一个 1ms 宽的噪声脉冲（强逼短块）
    clicks = np.zeros(N)
    for k in range(6):
        s = int((0.25 + 0.5 * k) * SR)
        e = min(N, s + int(0.001 * SR))
        clicks[s:e] = 0.8 * rng.standard_normal(e - s)
    out["click_train"] = clicks
    # 噪声突发：0.4s 噪声 + 0.2s 静音，反复（块边界 + 宽频瞬态）
    burst = np.zeros(N)
    for k in range(int(DUR / 0.6)):
        s = int(k * 0.6 * SR)
        e = min(N, s + int(0.4 * SR))
        burst[s:e] = 0.25 * rng.standard_normal(e - s)
    out["burst"] = burst
    return out


def make_probes() -> dict[str, Path]:
    PROBES.mkdir(parents=True, exist_ok=True)
    out: dict[str, Path] = {}
    for name, sig in _signals().items():
        wav, mp3 = PROBES / f"{name}.wav", PROBES / f"{name}.mp3"
        if not mp3.exists():
            _write_wav(wav, sig)
            p = subprocess.run(
                ["ffmpeg", "-hide_banner", "-v", "error", "-y", "-i", str(wav),
                 "-c:a", "libmp3lame", "-b:a", "128k", "-ar", str(SR), "-ac", "1",
                 str(mp3)], capture_output=True, text=True)
            if p.returncode != 0:
                print(f"  编码失败 {name}: {p.stderr[-300:]}")
                continue
            wav.unlink()
        out[name] = mp3
    return out


def decode_ours(names: list[str]) -> None:
    DUMP_LIST.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# 探针清单（probe_tones.py 生成）", ""]
    for n in names:
        lines.append(f"{(PROBES / (n + '.mp3')).as_posix()}|"
                     f"{(OURS / (n + '.f32le')).as_posix()}")
    DUMP_LIST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    p = subprocess.run(["cjpm", "test", "--filter", "DiagDumpTest", "--show-all-output",
                        "--no-color"], cwd=str(REPO), capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    for line in (p.stdout or "").splitlines():
        if "导出" in line or "诊断导出完成" in line:
            pass                       # 明细太长，只看产物存在性


def ffmpeg_decode(path: Path, dst: Path) -> None:
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-v", "error", "-y", "-c:a", "mp3float", "-i",
         str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-"], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode("utf-8", "replace")[-300:])
    dst.write_bytes(p.stdout)


#: 误差归因用的频带（Hz）
BANDS = [(0, 2000), (2000, 5000), (5000, 8000), (8000, 11000),
         (11000, 16000), (16000, 22050)]


def analyse(name: str) -> dict:
    """算三样东西：整体残差、**分频带误差能量**、边界区残差。

    【为什么是"分频带误差能量"而不是"显著频点的最大 dB 差"】
      最大 dB 差会被**弱频点**主导：那里信号本身接近噪声底，一点绝对差就是几十 dB，
      看着吓人却与听感无关（第一版指标就栽在这里，纯音上报 0.00 dB 而时域报 5%，
      两个数都真，但都没说清"错在哪"）。分频带误差能量 =
      Σ|X−Y|² / Σ|Y|²（同一带内），是有量纲一致性的口径：
      −60 dB 就表示该带内误差能量是信号能量的百万分之一，可直接跨带比较。
    """
    ours_p, ref_p = OURS / f"{name}.f32le", WORK / f"probes/{name}.fffloat.f32le"
    if not ours_p.exists() or not ref_p.exists():
        return {"name": name, "error": "缺产物"}
    ours = read_f32le(ours_p, 1)
    ref = read_f32le(ref_p, 1)
    lag = estimate_lag(ours, ref, max_lag=8192, sr_hint=SR)
    x, y = apply_lag(ours, ref, lag)
    x, y = x.ravel(), y.ravel()
    if len(y) < SR // 2:
        return {"name": name, "error": "重叠太短"}

    # 边界区：|位移| + 3 帧（与 localize.EDGE_MARGIN 同源）
    edge = abs(lag) + 1152 * 3
    lo, hi = min(edge, len(y) // 4), len(y) - min(edge, len(y) // 4)
    xin, yin = x[lo:hi], y[lo:hi]
    res_in = xin - yin
    ratio_in = float(np.sqrt((res_in ** 2).mean()) / (np.sqrt((yin ** 2).mean()) + 1e-12))
    res_all = x - y
    ratio_all = float(np.sqrt((res_all ** 2).mean()) /
                      (np.sqrt((y ** 2).mean()) + 1e-12))

    # 分频带误差能量（对内部区做 Welch 平均）
    nfft = 1 << 14
    win = np.hanning(nfft)
    fr = np.fft.rfftfreq(nfft, d=1.0 / SR)
    acc_err = np.zeros(fr.size)
    acc_sig = np.zeros(fr.size)
    starts = np.arange(0, max(1, len(yin) - nfft), nfft // 2)
    for s in starts[:16]:
        X = np.fft.rfft(xin[s:s + nfft] * win)
        Y = np.fft.rfft(yin[s:s + nfft] * win)
        acc_err += np.abs(X - Y) ** 2
        acc_sig += np.abs(Y) ** 2
    bands = {}
    for b_lo, b_hi in BANDS:
        sel = (fr >= b_lo) & (fr < b_hi)
        e, sg = acc_err[sel].sum(), acc_sig[sel].sum()
        bands[f"{b_lo//1000}k-{b_hi//1000}k"] = (
            float(10 * np.log10(e / sg)) if sg > 0 else None)
    return {"name": name, "lag": lag, "overlap": len(y),
            "residualRatioInner": ratio_in, "residualRatioAll": ratio_all,
            "bandErrorDb": bands}


def main() -> int:
    probes = make_probes()
    if not probes:
        print("无探针可用")
        return 1
    names = list(probes)
    print(f"探针 {len(names)} 条：{', '.join(names)}\n")
    for n in names:
        ffmpeg_decode(probes[n], WORK / f"probes/{n}.fffloat.f32le")
    print("解码本库输出（cjpm test）…")
    decode_ours(names)

    print(f"\n{'探针':13s} {'残差(内部)':>10s} {'残差(含边界)':>11s}  "
          + "  ".join(f"{b[0] // 1000}-{b[1] // 1000}k" for b in BANDS))
    rows = []
    for n in names:
        r = analyse(n)
        rows.append(r)
        if "error" in r:
            print(f"{n:13s} {r['error']}")
            continue
        b = r["bandErrorDb"]
        cells = "  ".join(
            ("   —  " if b[k] is None else f"{b[k]:6.1f}")
            for k in (f"{lo // 1000}k-{hi // 1000}k" for lo, hi in BANDS))
        print(f"{n:13s} {r['residualRatioInner']:10.3e} "
              f"{r['residualRatioAll']:11.3e}  {cells}")
    (WORK / "probe_result.json").write_text(
        __import__("json").dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
