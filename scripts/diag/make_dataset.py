#!/usr/bin/env python3
"""造诊断数据集：同一条 MP3 片段，四条独立解码路径，全部落成裸 f32le。

【四条路径：为什么是这个组合】

    ours       本库（仓颉，纯仓颉 MP3 内核）—— 被测对象
    fffloat    ffmpeg 的 `mp3float`（浮点解码链）
    fffixed    ffmpeg 的 `mp3`（**定点**解码链，与浮点同源但运算路径不同）
    sndfile    libsndfile 1.2.2 → **libmpg123**，与 ffmpeg 完全不同的血统

    前两条同源、后一条异源。三者的多数表决才能回答"谁离群"。
    只用 ffmpeg 一个实现时，一旦 ffmpeg 与我们对不上，无法判断谁错 ——
    这正是本次评估要避免的处境。

【为什么切片要重新编码，而不是直接截字节】

    直接在 MP3 字节流里按偏移截取会产生"头部帧不完整"的片段，
    且不同解码器对残缺流的容忍度不同，会把"解码差异"和"截断处理差异"混在一起。
    用 ffmpeg 重新编码成 CBR 128k 的短片段，得到的是**合法、自洽**的输入，
    差异只来自解码器本身。

【片段选的什么】

    · `baihu_105s`（20 秒）刻意**覆盖 112.7 秒那个待定位疑点** ——
      它是本次评估要回答的真实问题；
    · `baihu_200s`（30 秒）供性能测量（吞吐/内存）；
    · 其余为不同编码参数（CBR/VBR、单声道/立体声、16 kHz/44.1 kHz）的覆盖，
      用来验证检测器不是只在某一种参数下有效。

【产物】

    eval_work/clips/*.mp3            片段
    eval_work/refs/*.{fffloat,fffixed,sndfile}.f32le
    eval_work/ours/*.f32le           本库解码（由 src/test/diag_dump_test.cj 导出）
    eval_work/dataset.json           数据集清单（采样率/声道/字节数/时长），报告引用它
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

from diag_common import (CLIPS, DUMP_LIST, FFMPEG_DECODERS, OURS, REFS, REPO, WORK,
                         ensure_dirs, ffmpeg_decode, ffmpeg_probe, sndfile_decode,
                         write_f32le)

BAIHU = REPO / "musics" / "陈瑞 白狐 - .mp3"
DAYU = REPO / "musics" / "大鱼（cover 周深） - Ciky心心.mp3"
FIX = REPO / "testdata" / "mp3"

#: (名称, 源路径, 起始秒, 时长秒)；时长为 0 表示"整份素材，直接复制不重编"
CLIP_SPECS: list[tuple[str, Path, float, float]] = [
    ("baihu_105s", BAIHU, 105.0, 20.0),      # 覆盖 112.7s 疑点
    ("baihu_200s", BAIHU, 200.0, 30.0),      # 性能测量样本
    ("baihu_30s", BAIHU, 30.0, 6.0),
    ("baihu_60s", BAIHU, 60.0, 6.0),
    ("dayu_20s", DAYU, 20.0, 6.0),
    ("fx_cbr128", FIX / "mp3_cbr_128k.mp3", 0.0, 0.0),
    ("fx_vbr", FIX / "mp3_vbr_q4.mp3", 0.0, 0.0),
    ("fx_mono16k", FIX / "mp3_16000_mono.mp3", 0.0, 0.0),
    ("fx_cover", FIX / "mp3_cover.mp3", 0.0, 0.0),
]


def make_clip(name: str, src: Path, start: float, dur: float) -> Path | None:
    """生成一个片段。整份素材直接复制（保持与入库素材逐字节一致）。"""
    dst = CLIPS / f"{name}.mp3"
    if not src.exists():
        print(f"  跳过 {name}：源素材不存在（{src}）")
        return None
    if dst.exists():
        return dst
    if dur <= 0.0:
        shutil.copyfile(src, dst)
        return dst
    cmd = ["ffmpeg", "-hide_banner", "-v", "error", "-y",
           "-ss", f"{start}", "-t", f"{dur}", "-i", str(src),
           "-c:a", "libmp3lame", "-b:a", "128k", str(dst)]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        print(f"  跳过 {name}：ffmpeg 切片失败\n{p.stderr[-500:]}")
        return None
    return dst


def decode_all_refs(clip: Path) -> dict:
    """三条参照路径各解一遍，落成 f32le。"""
    name = clip.stem
    info = ffmpeg_probe(clip)
    ch, sr = info["channels"], info["sampleRate"]
    out = {"sampleRate": sr, "channels": ch, "duration": info["duration"], "refs": {}}

    for tag, dec in FFMPEG_DECODERS.items():
        raw = REFS / f"{name}.{tag}.f32le"
        ffmpeg_decode(clip, raw, decoder=dec)
        out["refs"][tag] = {"bytes": raw.stat().st_size, "samples": raw.stat().st_size // 4}
        out["refs"][tag]["frames"] = out["refs"][tag]["samples"] // ch

    try:
        data, sr2 = sndfile_decode(clip)
        raw = REFS / f"{name}.sndfile.f32le"
        write_f32le(raw, data)
        out["refs"]["sndfile"] = {"bytes": raw.stat().st_size, "samples": data.size,
                                  "frames": len(data), "sampleRate": sr2}
        # libsndfile 的声道数若与 ffmpeg 不一致，必须显式暴露（下游按 ffmpeg 口径解释）
        if data.shape[1] != ch:
            out["refs"]["sndfile"]["channelMismatch"] = f"{data.shape[1]} vs {ch}"
    except Exception as e:                                    # noqa: BLE001
        print(f"  libsndfile 解码失败（{name}）：{type(e).__name__} {e}")
        out["refs"]["sndfile"] = {"error": f"{type(e).__name__}: {e}"}

    return out


def run_ours_dump(clips: list[Path]) -> None:
    """写清单 → 跑 Cangjie 侧导出用例 → 校验产物。"""
    DUMP_LIST.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# 由 scripts/diag/make_dataset.py 生成：本库解码导出清单",
             "# 格式：<源音频>|<目标 f32le>",
             "# 本文件与 eval_work/ 一并被 .gitignore 排除（含第三方版权素材片段）", ""]
    for c in clips:
        lines.append(f"{c.as_posix()}|{(OURS / (c.stem + '.f32le')).as_posix()}")
    DUMP_LIST.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print("  运行 cjpm test --filter DiagDumpTest（本库解码导出，纯仓颉内核，耗时较长）…")
    cmd = ["cjpm", "test", "--filter", "DiagDumpTest", "--show-all-output", "--no-color"]
    p = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    for line in (p.stdout or "").splitlines():
        if "导出" in line or "跳过（源文件" in line or "诊断导出完成" in line:
            print("    " + line.strip())


def main() -> int:
    ap = argparse.ArgumentParser(description="生成解码偏差诊断数据集")
    ap.add_argument("--reuse", action="store_true", help="已存在的产物不重算")
    ap.add_argument("--skip-ours", action="store_true", help="跳过本库解码导出（只造参照）")
    args = ap.parse_args()

    ensure_dirs()
    print("【1/3】生成片段")
    clips: list[Path] = []
    for name, src, start, dur in CLIP_SPECS:
        c = make_clip(name, src, start, dur)
        if c:
            clips.append(c)
            print(f"  {name:12s} {c.stat().st_size:>9,} 字节")

    print("【2/3】解码参照（ffmpeg×2 + libsndfile）")
    manifest = {"clips": {}, "clipsDir": str(CLIPS.relative_to(REPO))}
    for c in clips:
        if args.reuse and (REFS / f"{c.stem}.sndfile.f32le").exists():
            # 复用：仍要读回参数与尺寸，清单不能是空的
            info = ffmpeg_probe(c)
            entry = {"sampleRate": info["sampleRate"], "channels": info["channels"],
                     "duration": info["duration"],
                     "refs": {t: {"bytes": (REFS / f"{c.stem}.{t}.f32le").stat().st_size}
                              for t in list(FFMPEG_DECODERS) + ["sndfile"]}}
            for t, d in entry["refs"].items():
                d["samples"] = d["bytes"] // 4
                d["frames"] = d["samples"] // info["channels"]
        else:
            entry = decode_all_refs(c)
        manifest["clips"][c.stem] = entry
        refn = entry["refs"]
        print(f"  {c.stem:12s} {entry['sampleRate']:>6} Hz / {entry['channels']} ch / "
              f"fffloat {refn['fffloat']['frames']} 帧 / "
              f"sndfile {refn.get('sndfile', {}).get('frames', '—')} 帧")

    print("【3/3】本库解码导出")
    if not args.skip_ours:
        run_ours_dump(clips)
    for c in clips:
        raw = OURS / f"{c.stem}.f32le"
        if raw.exists():
            n = raw.stat().st_size // 4
            manifest["clips"][c.stem]["ours"] = {
                "bytes": raw.stat().st_size, "samples": n,
                "frames": n // manifest["clips"][c.stem]["channels"],
            }
        else:
            print(f"  !! 缺少本库导出：{raw}")

    (WORK / "dataset.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2),
                                       encoding="utf-8")
    print(f"清单已写入 {WORK / 'dataset.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
