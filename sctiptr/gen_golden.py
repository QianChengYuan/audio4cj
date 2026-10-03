#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_golden.py
用 ffmpeg 把可解码素材解成 f32le 参考 PCM，作为 golden 比对基准。

用法:
    python3 gen_golden.py                     # 输出到 <仓库根>/testdata/golden
    python3 gen_golden.py --ffmpeg-dir DIR

依赖:
    ffmpeg（工具定位复用 gen_audio_fixtures.py 的 find_tool）

【分工】
    gen_audio_fixtures.py 生产**被测素材**；本脚本生产**比对基准**。

【为什么 golden 要入库】
    「没有裁判的自研等于黑盒」（开发文档 §9.1）。ffmpeg 用的是它**自己的解码
    实现**，是真正独立的一方。把它的输出固化成文件入库，测试就能在任何机器上
    复现比对，而不要求跑测试的机器装了 ffmpeg —— 这也是"无损互证"之外唯一
    真正的外部裁判。

【为什么 golden 按「信号」命名而不是按「素材文件」命名】
    同一段 PCM 无论装在 WAV 还是 FLAC 里，无损解码后都应当得到同一份 f32 数据。
    若按文件命名，就会存下多份内容完全相同的基准。按信号命名既省体积，也把
    「无损互证」这层含义写进了文件名：多个素材共用一份基准，恰恰说明它们
    必须解出相同的结果。

【为什么用 f32le 而不是原始整型 PCM】
    若基准存成整型 PCM，比对时就得先用**被测库自己的**位深转换函数去解释它，
    那个函数一旦有错，比对结果反而恒等 —— 自己给自己判卷。存 f32 则完全绕开
    被测代码：测试只需把 4 字节还原成 Float32（`Float32.readLittleEndian`），
    与被测库的输出逐样本相减即可。

【曾有的取舍：MP3 的 golden 只用于「松比对」】
    有损解码器在量化细节与编码器延迟补偿上合法地存在差异，逐样本等同做不到，
    因此 MP3 的基准当时只参与"帧数 + 整体能量"的包络比对。
    MP3 解码已移出本版本范围（它是唯一依赖 C 库 dr_mp3 的格式），该基准连同
    envelope 模式一并移除。若将来接入有损格式，需要把这条思路恢复起来 ——
    对两个有损解码器而言，逐样本相等是不可能达到的标准。
"""

import argparse
import os
import subprocess
import sys

# 复用素材脚本的 ffmpeg 定位（本机的 ffmpeg 是 winget 装的、不在 PATH 上）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_audio_fixtures as gaf

REPO_ROOT = gaf.REPO_ROOT
DATA_ROOT = os.path.join(REPO_ROOT, "testdata")
DEFAULT_OUT = os.path.join(DATA_ROOT, "golden")

# (golden 文件名, 用于生成它的源素材, 说明)
GOLDENS = [
    (
        "sine_44100_stereo_s16.f32le",
        "wav/wav_s16_44100_stereo.wav",
        "440Hz 正弦 1 秒 / 44.1k / 立体声 / 16bit；与 flac_s16_44100_stereo.flac、"
        "ogg_flac.oga 同源",
    ),
    (
        "sine_44100_stereo_s24.f32le",
        "wav/wav_s24_44100_stereo.wav",
        "同上但 24bit；与 flac_s24_44100_stereo.flac 同源",
    ),
    (
        "sine_44100_mono_s16.f32le",
        "wav/wav_s16_44100_mono.wav",
        "440Hz 正弦 1 秒 / 44.1k / 单声道 / 16bit；与 flac_s16_44100_mono.flac 同源",
    ),
    (
        "sine_44100_mono_u8.f32le",
        "wav/wav_u8_44100_mono.wav",
        "440Hz 正弦 1 秒 / 44.1k / 单声道 / 8bit 无符号（FLAC 无此位深，只做 ffmpeg 比对）",
    ),
    (
        "tone_16000_mono_s16.f32le",
        "wav/wav_s16_16000_mono.wav",
        "1kHz 正弦 3 秒 / 16k / 单声道 / 16bit；与 flac_s16_16000_mono.flac 同源",
    ),
]

# 素材 → (golden, 比对模式)
#   samples  = 逐样本比对（容差由测试按位深决定，见 golden_test.cj）
#   （曾有 envelope = 只比帧数与整体能量，随 MP3 移出范围一并移除）
FIXTURES = [
    ("wav/wav_s16_44100_stereo.wav", "sine_44100_stereo_s16.f32le", "samples"),
    ("flac/flac_s16_44100_stereo.flac", "sine_44100_stereo_s16.f32le", "samples"),
    ("ogg/ogg_flac.oga", "sine_44100_stereo_s16.f32le", "samples"),
    ("wav/wav_s24_44100_stereo.wav", "sine_44100_stereo_s24.f32le", "samples"),
    ("flac/flac_s24_44100_stereo.flac", "sine_44100_stereo_s24.f32le", "samples"),
    ("wav/wav_s16_44100_mono.wav", "sine_44100_mono_s16.f32le", "samples"),
    ("flac/flac_s16_44100_mono.flac", "sine_44100_mono_s16.f32le", "samples"),
    ("wav/wav_u8_44100_mono.wav", "sine_44100_mono_u8.f32le", "samples"),
    ("wav/wav_s16_16000_mono.wav", "tone_16000_mono_s16.f32le", "samples"),
    ("flac/flac_s16_16000_mono.flac", "tone_16000_mono_s16.f32le", "samples"),
]

MANIFEST_NAME = "GOLDEN.tsv"


def probe_audio(path):
    """用 ffprobe 取 (采样率, 声道数)。"""
    out = subprocess.run(
        [
            gaf.FFPROBE,
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=sample_rate,channels",
            "-of", "default=nw=1:nk=1",
            path,
        ],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return int(out[0]), int(out[1])


def decode_to_f32le(src, dst):
    """用 ffmpeg 把素材解成 f32le 裸流。

    关键点：
      - **不指定 -ar / -ac**：保持素材原采样率与声道数。本库的统一输出只统一
        "位深到 f32"与"交错布局"，不统一采样率（开发文档 §5），基准必须对齐
        这一约定。
      - `-map a:0 -vn`：只取第一条音频流。带封面的 MP3/MP4 里附加图片是独立
        流，不加限制会干扰裸流输出。
    """
    gaf.ffmpeg(["-i", src, "-map", "a:0", "-vn",
                "-f", "f32le", "-acodec", "pcm_f32le", dst])


def human(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024 or unit == "MB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    ap = argparse.ArgumentParser(description="生成 golden PCM 比对基准")
    ap.add_argument("outdir", nargs="?", default=DEFAULT_OUT,
                    help=f"输出目录（默认 {DEFAULT_OUT}）")
    ap.add_argument("--ffmpeg-dir", default="",
                    help="显式指定含 ffmpeg 可执行文件的目录")
    args = ap.parse_args()

    if args.ffmpeg_dir:
        os.environ["FFMPEG_DIR"] = args.ffmpeg_dir

    gaf.resolve_tools()
    if not gaf.FFPROBE:
        sys.exit("错误: 未找到 ffprobe（本脚本用它读取采样率与声道数以做自检）")

    out = os.path.abspath(args.outdir)
    os.makedirs(out, exist_ok=True)

    # 先检查素材是否齐备 —— 缺素材时报出全部缺口，而不是生成到一半失败
    missing = [rel for rel, _g, _m in FIXTURES
               if not os.path.isfile(os.path.join(DATA_ROOT, rel))]
    missing += [src for _n, src, _d in GOLDENS
                if not os.path.isfile(os.path.join(DATA_ROOT, src))]
    if missing:
        sys.exit("错误: 缺少素材，请先运行 gen_audio_fixtures.py：\n  "
                 + "\n  ".join(sorted(set(missing))))

    print(">>> 解码素材为 f32le 基准 ...")
    rows = []
    for name, src, _desc in GOLDENS:
        src_path = os.path.join(DATA_ROOT, src)
        dst_path = os.path.join(out, name)
        decode_to_f32le(src_path, dst_path)

        rate, channels = probe_audio(src_path)
        size = os.path.getsize(dst_path)
        bytes_per_frame = channels * 4

        # 自检：f32le 裸流的长度必须是「帧 × 声道 × 4」的整数倍，
        # 否则说明 ffmpeg 输出被人为干预过（重采样、声道数变化等）
        if size % bytes_per_frame != 0:
            sys.exit(f"错误: {name} 的长度 {size} 不是 {bytes_per_frame} 的整数倍，"
                     "基准与库的输出布局不一致")
        rows.append((name, src, size, rate, channels, size // bytes_per_frame))

    print(f"\n=== 基准生成完成: {os.path.abspath(out)} ===\n")
    print(f"{'基准文件':<32}{'大小':>10}{'采样率':>9}{'声道':>6}{'帧数':>9}")
    print(f"{'-' * 32}{'-' * 10}{'-' * 9}{'-' * 6}{'-' * 9}")
    total = 0
    for name, src, size, rate, channels, frames in rows:
        total += size
        print(f"{name:<32}{human(size):>10}{rate:>9}{channels:>6}{frames:>9}")
    print(f"\n共 {len(rows)} 个基准，合计 {human(total)}")

    # 写出映射表：素材 → 基准 + 比对模式
    manifest = os.path.join(out, MANIFEST_NAME)
    with open(manifest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# fixture\tgolden\tmode\n")
        fh.write("# 由 gen_golden.py 生成，供 src/test/golden_test.cj 读取。\n")
        fh.write("# fixture 为 testdata 下的相对路径；golden 为 testdata/golden 下的文件名。\n")
        fh.write("# mode: samples = 逐样本比对；envelope = 只比帧数与整体能量。\n")
        for rel, golden, mode in FIXTURES:
            fh.write(f"{rel}\t{golden}\t{mode}\n")

    print(f"\n素材 → 基准 映射已写入: {os.path.relpath(manifest, REPO_ROOT)}")
    print("\n核对（可选）:")
    print("  ffprobe -v error -show_entries stream=codec_name,sample_rate,channels "
          "-of default=nw=1 <素材>")


if __name__ == "__main__":
    main()
