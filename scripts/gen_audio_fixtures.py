#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_audio_fixtures.py
生成 audio4cj 的测试素材矩阵（固定测试资产，纳入版本控制）

【历史实现 —— 现行来源是 scripts/gen_testdata.sh 与 scripts/gen_testdata.ps1】
  本脚本是素材生成的**最初实现**，保留在仓库中供溯源：它含按信号/容器分组的 REFSPECS
  规格表，若干测试注释以它为规格依据。
  **但现行流程不再跑它**：制品包随发 scripts/gen_testdata.sh（POSIX）与
  scripts/gen_testdata.ps1（Windows），两者产出与 testdata/ 已入库版本**逐项同构**
  （实测：文件清单一致、54 个音频的编码/声道/采样率/时长零差异、两个 TSV 与
  5 个 golden 基准逐字节相同）。
  因此改动素材规格时**必须同时改这三处**（本文件 + 两份新脚本），否则必然漂移。

用法:
    python3 gen_audio_fixtures.py                     # 输出到 <仓库根>/testdata
    python3 gen_audio_fixtures.py ./testdata
    python3 gen_audio_fixtures.py --only flac,mp3     # 只重新生成指定分组
    python3 gen_audio_fixtures.py --keep-ref          # 复用已有参考 WAV

依赖:
    ffmpeg / ffprobe
    必需编码器: aac / libvorbis / libopus / flac / libmp3lame
    可选编码器: libspeex（缺失时跳过 Speex 样本，不影响其他分组）

授权:
    本脚本生成的全部素材均由**合成信号**编码而来，不含任何第三方版权内容，
    可自由纳入版本控制。
    注意：仓库中 musics/ 目录下的歌曲属第三方版权内容，已在 .gitignore 中排除。

设计要点（为什么是这些素材）:
    1. **覆盖库真正能解码的格式**。库首期承诺 WAV / FLAC / MP3，而本脚本最早
       只生成 AAC / OGG —— 一个能解码的格式都没有，无法做解码正确性验证。
       现在每个可解码格式都有素材。
    2. **合成信号而非音乐**。解码正确性靠"输出 vs 已知期望值"比对。合成信号
       能精确知道该输出什么频率、多少个采样点，定位问题远比音乐素材快，
       且完全没有版权问题。
    3. **参考信号是唯一输入源**。同一份参考 WAV 分别编码成 WAV/FLAC/MP3，
       构成"无损互证"（WAV 与 FLAC 都是无损，解码输出必须一致）。
    4. **体积由时长控制**。f32 交错 44.1kHz 立体声 1 秒约 352 KB，故所有
       素材时长都压在 1~3 秒（见下方 DUR_* 常量）。
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------- 体积旋钮
#
# 素材体积几乎完全由时长决定。这三个常量是控制仓库体积的**唯一旋钮**，
# 调大之前请先评估 testdata/ 的总体积（report() 会打印合计）。
DUR_REF = 3.0        # 参考信号时长（秒）
DUR_MATRIX = 1.0     # 位深 / 声道 / 采样率矩阵样本时长
DUR_TAGGED = 2.0     # 带标签样本时长（稍长，便于验证时长计算）

REQUIRED_ENCODERS = ("aac", "libvorbis", "libopus", "flac", "libmp3lame")
OPTIONAL_ENCODERS = ("libspeex",)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO_ROOT, "testdata")

SECTIONS = ("wav", "flac", "mp3", "ogg", "aac", "mp4")

# 由 resolve_tools() 填充
FFMPEG = None
FFPROBE = None


# ---------------------------------------------------------------- 工具定位

def resolve_tools():
    """定位 ffmpeg / ffprobe，找不到时给出可操作的提示。

    为什么不假设它在 PATH 上：本机的实际情形就是 winget 安装且**没有加入
    PATH**（Windows 侧 where.exe 找不到，WSL 侧也没有），但素材确实生成成功过。
    盲目假设 PATH 会让脚本在换了台机器后报"未找到 ffmpeg"而没有任何线索。
    """
    global FFMPEG, FFPROBE

    FFMPEG = find_tool("ffmpeg")
    FFPROBE = find_tool("ffprobe")

    if not FFMPEG:
        sys.exit(
            "错误: 未找到 ffmpeg。请任选一种方式：\n"
            "  1) 安装并加入 PATH（Windows: winget install Gyan.FFmpeg）\n"
            "  2) 设置环境变量 FFMPEG_DIR 指向含 ffmpeg 可执行文件的目录\n"
            "  3) 用 --ffmpeg-dir 显式指定"
        )
    if not FFPROBE:
        # ffprobe 只用于 report() 的核对提示，缺失不致命
        print("[warn] 未找到 ffprobe，report() 的核对提示仍可用但需自行补路径")
    print(f"[ok] ffmpeg : {FFMPEG}")


def find_tool(name):
    """在 PATH 与各平台常见安装位置中查找 ffmpeg / ffprobe。

    之所以独立成公开函数：`gen_golden.py` 需要复用同一套定位逻辑
    （本机的 ffmpeg 就是 winget 安装且不在 PATH 上）。
    """
    exe = name + (".exe" if os.name == "nt" else "")

    hit = shutil.which(name)
    if hit:
        return hit

    candidates = []

    env_dir = os.environ.get("FFMPEG_DIR")
    if env_dir:
        candidates.append(os.path.join(env_dir, exe))

    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA", "")
        # winget 的包目录形如：
        #   <LOCALAPPDATA>\Microsoft\WinGet\Packages\Gyan.FFmpeg_<源>_<哈希>\
        #       ffmpeg-<版本>-full_build\bin\ffmpeg.exe
        # 版本号在路径里，只能遍历找。
        winget = os.path.join(local, "Microsoft", "WinGet", "Packages")
        if os.path.isdir(winget):
            for entry in sorted(os.listdir(winget)):
                if "ffmpeg" in entry.lower():
                    for root, _dirs, files in os.walk(os.path.join(winget, entry)):
                        if exe in files:
                            candidates.append(os.path.join(root, exe))
        candidates += [
            os.path.join("C:\\ffmpeg\\bin", exe),
            os.path.join("C:\\Program Files\\ffmpeg\\bin", exe),
            os.path.join(os.environ.get("ProgramData", ""), "chocolatey", "bin", exe),
            os.path.join(os.environ.get("USERPROFILE", ""), "scoop", "shims", exe),
        ]
    else:
        candidates += [
            os.path.join("/usr/local/bin", name),
            os.path.join("/opt/ffmpeg/bin", name),
        ]

    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


def run(cmd, quiet=True):
    """执行命令，失败时抛出清晰的错误。"""
    try:
        subprocess.run(
            cmd,
            check=True,
            stdout=subprocess.PIPE if quiet else None,
            stderr=subprocess.PIPE if quiet else None,
        )
    except FileNotFoundError:
        sys.exit(f"错误: 未找到可执行文件 {cmd[0]}")
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or b"").decode("utf-8", "replace").strip()
        sys.exit(f"错误: 命令失败\n  {' '.join(cmd)}\n{detail}")


def ffmpeg(args, quiet=True):
    run([FFMPEG, "-y", "-loglevel", "error"] + args, quiet=quiet)


def ffmpeg_soft(args, what):
    """执行 ffmpeg，失败时**只警告不中断**。

    用于可选素材（如 Speex）——某个编码器在当前 ffmpeg 构建里缺失，
    不应该让整个素材集生成失败。
    """
    try:
        subprocess.run(
            [FFMPEG, "-y", "-loglevel", "error"] + args,
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return True
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or b"").decode("utf-8", "replace").strip()
        print(f"[warn] 跳过 {what}: {detail.splitlines()[0] if detail else '未知错误'}")
        return False


def check_env():
    """校验 ffmpeg 编码器齐备情况。"""
    encoders = subprocess.run(
        [FFMPEG, "-hide_banner", "-encoders"],
        capture_output=True, text=True, check=True,
    ).stdout

    missing = [e for e in REQUIRED_ENCODERS if f" {e} " not in encoders]
    if missing:
        sys.exit(f"错误: 当前 ffmpeg 缺少必需编码器 {', '.join(missing)}")

    print(f"[ok] 编码器检查通过: {' / '.join(REQUIRED_ENCODERS)}")

    absent = [e for e in OPTIONAL_ENCODERS if f" {e} " not in encoders]
    if absent:
        print(f"[warn] 可选编码器缺失，将跳过对应素材: {', '.join(absent)}")


# ---------------------------------------------------------------- 魔数识别

def sniff(path):
    """读文件头魔数判断真实格式，返回 (容器, 子编码)。

    别信扩展名 —— 样本库里"改名"是常见缺陷，会静默让你的测试失去意义。

    仓颉侧的探测层（src/probe/magic.cj）判定结果必须与本函数一致；
    本函数的输出会写入 MANIFEST.tsv，作为识别矩阵测试的对照基准
    （两侧独立实现，互为交叉检查）。
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(64)
    except OSError:
        return ("??", "")

    if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
        return ("wav", "")
    if head[:4] == b"OggS":
        # Ogg 页头固定 27 字节 + segment table（段数由 head[26] 给出），
        # payload 起点 = 27 + n_segments。**写死 28 会漏判多段页。**
        if len(head) < 27:
            return ("ogg", "")
        start = 27 + head[26]
        payload = head[start:]
        if payload[:8] == b"OpusHead":
            return ("ogg", "opus")
        if payload[:5] == b"\x7fFLAC":
            return ("ogg", "flac")
        if payload[1:7] == b"vorbis":
            return ("ogg", "vorbis")
        if payload[:8] == b"Speex   ":
            return ("ogg", "speex")
        return ("ogg", "")
    if head[:4] == b"fLaC":
        return ("flac", "")
    # ADTS 的 AAC（同步字 0xFFF + layer 字段 00）必须先于裸 MPEG 同步判定，
    # 否则会被归成 mp3。
    if head[:2] in (b"\xff\xf1", b"\xff\xf9"):
        return ("aac", "")
    if head[4:8] == b"ftyp":
        return ("mp4", "")
    if head[:3] == b"ID3":
        return ("mp3", "")
    if len(head) >= 2 and head[0] == 0xFF and (head[1] & 0xE0) == 0xE0:
        return ("mp3", "")
    return ("unknown", "")


def file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def human(n):
    for unit in ("B", "KB", "MB"):
        if n < 1024 or unit == "MB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


# ---------------------------------------------------------------- 分组：参考信号

# 参考信号是**所有编码分组的唯一输入源**，也是"无损互证"的基准。
# 名称保持与原脚本一致（仅缩短时长以控制体积），避免无谓的改动。
REFSPECS = {
    "sine": (
        "ref_440hz_44100_s16_stereo.wav",
        ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=44100:duration={DUR_REF}",
         "-ac", "2", "-c:a", "pcm_s16le"],
        "基础基准：验证频率与时长",
    ),
    "sweep": (
        "ref_sweep_44100_s16_stereo.wav",
        ["-f", "lavfi",
         "-i", f"aevalsrc='sin(2*PI*(200*t+390*t*t))':s=44100:d={DUR_REF}:c=stereo",
         "-c:a", "pcm_s16le"],
        "扫频：瞬时频率 f(t)=200+780t，相位 2*PI*(200t+390t^2)，验证频响完整性与整段不丢帧",
    ),
    "mono": (
        "ref_1khz_16000_s16_mono.wav",
        ["-f", "lavfi", "-i", f"sine=frequency=1000:sample_rate=16000:duration={DUR_REF}",
         "-ac", "1", "-c:a", "pcm_s16le"],
        "低采样率单声道：语音场景",
    ),
    "silence": (
        "ref_silence_44100_s16_stereo.wav",
        ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", str(DUR_REF),
         "-c:a", "pcm_s16le"],
        "静音：验证静音不被解码成噪声、时长计算正确",
    ),
}


def gen_reference(out, keep_ref):
    """生成参考信号，返回 {键: 路径}。"""
    refs = {}
    for key, (name, args, desc) in REFSPECS.items():
        path = os.path.join(out, name)
        refs[key] = path

    if keep_ref and all(os.path.isfile(p) for p in refs.values()):
        print(">>> 复用已有参考信号（--keep-ref）")
        return refs

    print(">>> 生成参考信号 ...")
    for _key, (name, args, _desc) in REFSPECS.items():
        ffmpeg(args + [os.path.join(out, name)])
    return refs


# ---------------------------------------------------------------- 分组：WAV

def gen_wav(out, refs):
    """WAV 位深 / 声道 / 采样率矩阵。

    WAV 的解码是**纯仓颉**实现（位深转换），因此 isSupportedPcmFormat 声称
    支持的每个位深（8 / 16 / 24 / 32 整型）都必须有素材覆盖 —— 这是自研
    代码路径，必须有解码正确性验证。

    附带一个带 LIST/INFO 标签的样本。实测确认 ffmpeg 的 wav muxer 会写
    LIST/INFO（含 INAM 等子块），无需自行注入 chunk。
    """
    print(">>> 生成 WAV 矩阵 ...")
    d = os.path.join(out, "wav")
    os.makedirs(d, exist_ok=True)

    sine = refs["sine"]
    mono = refs["mono"]

    specs = [
        ("wav_u8_44100_mono.wav",    sine, ["-ac", "1", "-c:a", "pcm_u8"]),
        ("wav_s16_44100_mono.wav",   sine, ["-ac", "1", "-c:a", "pcm_s16le"]),
        ("wav_s16_44100_stereo.wav", sine, ["-ac", "2", "-c:a", "pcm_s16le"]),
        ("wav_s24_44100_mono.wav",   sine, ["-ac", "1", "-c:a", "pcm_s24le"]),
        ("wav_s24_44100_stereo.wav", sine, ["-ac", "2", "-c:a", "pcm_s24le"]),
        ("wav_s32_44100_mono.wav",   sine, ["-ac", "1", "-c:a", "pcm_s32le"]),
        ("wav_s32_44100_stereo.wav", sine, ["-ac", "2", "-c:a", "pcm_s32le"]),
        ("wav_s16_22050_mono.wav",   sine, ["-ar", "22050", "-ac", "1", "-c:a", "pcm_s16le"]),
        ("wav_s16_48000_stereo.wav", sine, ["-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le"]),
        ("wav_s16_96000_stereo.wav", sine, ["-ar", "96000", "-ac", "2", "-c:a", "pcm_s16le"]),
        ("wav_s16_16000_mono.wav",   mono, ["-c:a", "pcm_s16le"]),
    ]
    for name, src, codec_args in specs:
        ffmpeg(["-i", src, "-t", str(DUR_MATRIX)] + codec_args + [os.path.join(d, name)])

    # 带 LIST/INFO 标签的样本。值一律用 ASCII：本仓库的 WAV INFO 解析器
    # 对编码的处理已在自包含测试里覆盖，这里要验证的是"真实 ffmpeg 产物能读"，
    # 混入编码问题会让失败原因变得不明确。
    ffmpeg([
        "-i", sine, "-t", str(DUR_TAGGED), "-c:a", "pcm_s16le",
        "-metadata", "title=WAV INFO Title",
        "-metadata", "artist=WAV INFO Artist",
        "-metadata", "album=WAV INFO Album",
        "-metadata", "date=2026",
        "-metadata", "genre=Test",
        "-metadata", "comment=WAV INFO Comment",
        "-metadata", "track=3",
        os.path.join(d, "wav_info_tagged.wav"),
    ])


# ---------------------------------------------------------------- 分组：FLAC

def gen_flac(out, refs):
    """FLAC 样本 —— 无损互证与 golden 比对的主要输入。

    FLAC 与 WAV 都是无损的，因此"同一信号的 WAV 与 FLAC 解码输出必须逐位
    相等"是一条**不依赖任何外部工具**的强一致性检查（CI 无 ffmpeg 也能跑）。
    """
    print(">>> 生成 FLAC 样本 ...")
    d = os.path.join(out, "flac")
    os.makedirs(d, exist_ok=True)

    sine = refs["sine"]
    mono = refs["mono"]
    silence = refs["silence"]

    # (a) 与 wav/ 下的同名样本构成无损互证对（相同时长、相同参数）
    ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-ac", "1", "-c:a", "flac",
            os.path.join(d, "flac_s16_44100_mono.flac")])
    ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-ac", "2", "-c:a", "flac",
            "-sample_fmt", "s16", os.path.join(d, "flac_s16_44100_stereo.flac")])
    ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-ac", "2", "-c:a", "flac",
            "-sample_fmt", "s32", os.path.join(d, "flac_s24_44100_stereo.flac")])
    # 时长必须与 wav/wav_s16_16000_mono.wav 一致（同为 DUR_MATRIX）——
    # 否则两者不构成合法的"无损互证"对：同一段 PCM 才能要求解码结果相同。
    # （wav 矩阵那个循环对每条都加了 -t，这里此前漏了，导致 flac 版本是 3 秒。）
    ffmpeg(["-i", mono, "-t", str(DUR_MATRIX), "-c:a", "flac",
            os.path.join(d, "flac_s16_16000_mono.flac")])
    ffmpeg(["-i", silence, "-c:a", "flac", os.path.join(d, "flac_silence.flac")])

    # (b) Vorbis comment 标签（FLAC 的标签体系就是 Vorbis comment）。
    #     规范规定为 UTF-8，故此处可以安全地包含非 ASCII 值。
    ffmpeg([
        "-i", sine, "-t", str(DUR_TAGGED), "-c:a", "flac",
        "-metadata", "title=FLAC 测试标题",
        "-metadata", "artist=元宝",
        "-metadata", "album=Test Fixtures",
        "-metadata", "album_artist=Various",
        "-metadata", "date=2026",
        "-metadata", "genre=Test",
        "-metadata", "comment=中文注释",
        "-metadata", "composer=Composer Name",
        "-metadata", "track=3/12",
        "-metadata", "disc=1/2",
        "-metadata", "ENCODER_CUSTOM=custom-value",
        os.path.join(d, "flac_tagged.flac"),
    ])

    # (c) 封面：FFmpeg 会把附加图片写成 FLAC 的 PICTURE 元数据块
    gen_cover_and_attach(
        sine, os.path.join(d, "flac_cover.flac"),
        ["-t", str(DUR_TAGGED), "-c:a", "flac",
         "-metadata", "title=FLAC 封面标题",
         "-metadata", "artist=元宝",
         "-metadata", "album=Test Fixtures"],
    )


# ---------------------------------------------------------------- 分组：MP3

def gen_mp3(out, refs):
    """MP3 样本 —— ID3 各版本 + 封面。

    【ID3v1 样本为什么必须用纯 ASCII 元数据】
      ffmpeg 的 -write_id3v1 写的是 **UTF-8**（其 muxer 帮助里明确提示
      "ID3v1 tags are written in UTF-8 which may not be supported by most
      software"），而 ID3v1 规范规定是 ISO-8859-1。若在这里塞中文，测出来的
      是"ffmpeg 与规范不一致"这个编码问题，而不是我们的解析逻辑。
      因此 ID3v1 样本只用 ASCII，中文编码路径由自包含测试覆盖。
    """
    print(">>> 生成 MP3 样本 ...")
    d = os.path.join(out, "mp3")
    os.makedirs(d, exist_ok=True)

    sine = refs["sine"]
    mono = refs["mono"]

    # (a) 基础：CBR / VBR / 单声道
    ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "libmp3lame", "-b:a", "128k",
            os.path.join(d, "mp3_cbr_128k.mp3")])
    ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "libmp3lame", "-q:a", "4",
            os.path.join(d, "mp3_vbr_q4.mp3")])
    ffmpeg(["-i", mono, "-c:a", "libmp3lame", "-b:a", "64k",
            os.path.join(d, "mp3_16000_mono.mp3")])

    # (b) ID3 各版本（三者元数据内容相同，只有标签版本不同）
    common = [
        "-metadata", "title=MP3 Title",
        "-metadata", "artist=MP3 Artist",
        "-metadata", "album=MP3 Album",
        "-metadata", "date=2026",
        "-metadata", "genre=Test",
        "-metadata", "comment=MP3 Comment",
    ]

    # ID3v1 only：-id3v2_version 0 关闭 ID3v2
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "libmp3lame", "-b:a", "128k",
            "-id3v2_version", "0", "-write_id3v1", "1"] + common +
           [os.path.join(d, "mp3_id3v1.mp3")])

    # ID3v2.3
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "libmp3lame", "-b:a", "128k",
            "-id3v2_version", "3", "-write_id3v1", "0"] + common +
           [os.path.join(d, "mp3_id3v23.mp3")])

    # ID3v2.4
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "libmp3lame", "-b:a", "128k",
            "-id3v2_version", "4", "-write_id3v1", "0"] + common +
           [os.path.join(d, "mp3_id3v24.mp3")])

    # 同时含 ID3v2.3 与 ID3v1 —— 用于验证"多体系共存时的逐字段回填"
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "libmp3lame", "-b:a", "128k",
            "-id3v2_version", "3", "-write_id3v1", "1"] + common +
           [os.path.join(d, "mp3_id3v23_plus_v1.mp3")])

    # (c) 封面：APIC 帧
    gen_cover_and_attach(
        sine, os.path.join(d, "mp3_cover.mp3"),
        ["-t", str(DUR_TAGGED), "-c:a", "libmp3lame", "-b:a", "128k",
         "-id3v2_version", "3"] + common,
    )


# ---------------------------------------------------------------- 分组：OGG

def gen_ogg(out, refs):
    """OGG 样本。

    OGG 是**容器**不是编码，里面至少三种编码都要覆盖：
      Vorbis（最常见）/ Opus（内部强制 48kHz）/ FLAC（无损变体）/ Speex（窄带语音）
    """
    print(">>> 生成 OGG 样本 ...")
    d = os.path.join(out, "ogg")
    os.makedirs(d, exist_ok=True)

    sine = refs["sine"]
    mono = refs["mono"]
    silence = refs["silence"]

    # (a) Vorbis 多质量档
    for q in ("0", "4", "8"):
        ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "libvorbis", "-q:a", q,
                os.path.join(d, f"ogg_vorbis_q{q}.ogg")])
    ffmpeg(["-i", mono, "-c:a", "libvorbis", "-q:a", "4",
            os.path.join(d, "ogg_vorbis_q4_mono.ogg")])

    # (b) Vorbis comment 标签（Ogg 的注释头就是 Vorbis comment，规范为 UTF-8）
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "libvorbis", "-q:a", "4",
            "-metadata", "title=OGG Vorbis 标题",
            "-metadata", "artist=元宝",
            "-metadata", "album=Test Fixtures",
            "-metadata", "date=2026",
            "-metadata", "genre=Test",
            "-metadata", "track=5",
            os.path.join(d, "ogg_vorbis_tagged.ogg")])

    # (c) Opus —— 内部采样率被强制为 48kHz，f32 转换要处理这个
    for br in ("32k", "96k"):
        ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "libopus", "-b:a", br,
                os.path.join(d, f"ogg_opus_{br}.opus")])
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "libopus", "-b:a", "64k",
            "-metadata", "title=OGG Opus 标题",
            "-metadata", "artist=元宝",
            "-metadata", "album=Test Fixtures",
            os.path.join(d, "ogg_opus_tagged.opus")])

    # (d) FLAC-in-Ogg 变体 —— 本库可解码它（起初借 dr_flac 对 Ogg 的 transparent
    #     支持，现已改为本库自己的纯仓颉页级读取器）；此前探测层把它当通用 ogg
    #     拒绝，属"本可支持却被拒绝"的缺口，已修正为可解码。
    ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "flac", "-f", "ogg",
            os.path.join(d, "ogg_flac.oga")])

    # (d2) FLAC-in-Ogg 且带标签 —— 它的标签**不在首个 packet** 里，而是散在后续
    #      packet 承载的 FLAC 元数据块链中，因此专门用来验证
    #      「Ogg 页重组 + FLAC 块链复原」这条路径确实打通了。
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "flac", "-f", "ogg",
            "-metadata", "title=Ogg FLAC 标题",
            "-metadata", "artist=元宝",
            "-metadata", "album=Test Fixtures",
            "-metadata", "track=7",
            os.path.join(d, "ogg_flac_tagged.oga")])

    # (e) 静音 —— 验证无声内容解码后不产生噪声
    ffmpeg(["-i", silence, "-c:a", "libvorbis", "-q:a", "4",
            os.path.join(d, "ogg_vorbis_silence.ogg")])

    # (f) Speex —— 窄带语音编码。libspeex 属可选编码器，缺失时跳过。
    #     Speex 只支持 8/16/32 kHz，必须显式 -ar。
    ffmpeg_soft(["-i", mono, "-t", str(DUR_MATRIX), "-ar", "16000", "-ac", "1",
                 "-c:a", "libspeex", os.path.join(d, "ogg_speex_16000.spx")],
                "Ogg/Speex 样本")


# ---------------------------------------------------------------- 分组：AAC

def gen_aac(out, refs):
    """AAC 样本。

    AAC 必须准备两种形态，这是最容易漏的一点：
      (a) ADTS 裸流 .aac —— 每帧带 7/9 字节同步头，探测层据此识别
      (b) MP4 封装 .m4a —— 需要 isomp4 demuxer 才能取到，探测层识别为 mp4
    只准备 .m4a 的话，ADTS 那条识别路径根本跑不起来。
    """
    print(">>> 生成 AAC 样本 ...")
    d = os.path.join(out, "aac")
    os.makedirs(d, exist_ok=True)

    sine = refs["sine"]
    mono = refs["mono"]

    # (a) ADTS 裸流 —— -f adts 是关键，不加会被自动封装成 MP4
    for br in ("64k", "128k", "256k"):
        ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "aac", "-b:a", br,
                "-f", "adts", os.path.join(d, f"aac_adts_{br}.aac")])
    ffmpeg(["-i", mono, "-c:a", "aac", "-b:a", "64k", "-f", "adts",
            os.path.join(d, "aac_adts_64k_mono.aac")])


# ---------------------------------------------------------------- 分组：MP4

def gen_mp4(out, refs):
    """MP4 样本 —— 重点是标签（ilst 原子）。

    MP4 的元数据在 format 层读得到，而 OGG 的 Vorbis comment 在 stream 层
    （见脚本末尾提示），写标签测试时容易踩。
    """
    print(">>> 生成 MP4 样本 ...")
    d = os.path.join(out, "mp4")
    os.makedirs(d, exist_ok=True)

    sine = refs["sine"]

    # (a) AAC-in-MP4 多码率
    for br in ("64k", "128k", "256k"):
        ffmpeg(["-i", sine, "-t", str(DUR_MATRIX), "-c:a", "aac", "-b:a", br,
                os.path.join(d, f"aac_mp4_{br}.m4a")])

    # (b) 少量标签（与原素材对齐）
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "aac", "-b:a", "128k",
            "-metadata", "title=MP4 测试标题",
            "-metadata", "artist=元宝",
            "-metadata", "album=Test Fixtures",
            "-metadata", "date=2026",
            os.path.join(d, "aac_mp4_tagged.m4a")])

    # (c) 全字段标签 —— 覆盖 ilst 主要原子：
    #     ©nam ©ART ©alb aART ©day ©gen ©cmt ©wrt trkn disk
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "aac", "-b:a", "128k",
            "-metadata", "title=MP4 全字段标题",
            "-metadata", "artist=MP4 艺术家",
            "-metadata", "album=MP4 专辑",
            "-metadata", "album_artist=MP4 专辑艺术家",
            "-metadata", "date=2026",
            "-metadata", "genre=Test",
            "-metadata", "comment=MP4 注释",
            "-metadata", "composer=MP4 作曲",
            "-metadata", "track=3/12",
            "-metadata", "disc=1/2",
            os.path.join(d, "mp4_tagged_full.m4a")])

    # (d) 封面：covr 原子
    gen_cover_and_attach(
        sine, os.path.join(d, "mp4_cover.m4a"),
        ["-t", str(DUR_TAGGED), "-c:a", "aac", "-b:a", "128k",
         "-metadata", "title=MP4 Cover"],
    )

    # (e) faststart 变体：把 moov 移到**文件前部**。
    #     上面 (c) 是 ffmpeg 的默认布局（moov 在**文件末尾**），两者内容相同、
    #     布局相反，专门用来验证标签读取的**两条定位路径**都能走通 ——
    #     只测其中一种，另一种就会在真实文件上静默失效。
    ffmpeg(["-i", sine, "-t", str(DUR_TAGGED), "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            "-metadata", "title=MP4 faststart 标题",
            "-metadata", "artist=MP4 艺术家",
            "-metadata", "album=MP4 专辑",
            os.path.join(d, "mp4_tagged_faststart.m4a")])


# ---------------------------------------------------------------- 封面辅助

def make_covers(tmpdir):
    """用 ffmpeg 生成两张极小的封面图（PNG 与 JPEG）。

    不引入任何外部图片资源 —— 封面必须是"脚本自己生成的"，才能保证素材
    整体无版权问题。
    """
    png = os.path.join(tmpdir, "cover.png")
    jpg = os.path.join(tmpdir, "cover.jpg")
    ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=16x16", "-frames:v", "1", png])
    ffmpeg(["-f", "lavfi", "-i", "color=c=blue:s=16x16", "-frames:v", "1", jpg])
    return png, jpg


_COVERS = None


def gen_cover_and_attach(src_audio, dst, codec_args):
    """把封面附着到音频上，写出 dst。

    封面图由 make_covers() 用 ffmpeg 现造，不引入任何外部图片资源 ——
    这样整个 testdata/ 才可以保证"零第三方版权内容"。

    不做任何清理：本函数只产出 dst 一个文件，其它都是临时目录里的东西。
    """
    global _COVERS
    if _COVERS is None:
        tmpdir = tempfile.mkdtemp(prefix="a4cj_covers_")
        _COVERS = make_covers(tmpdir)

    png, _jpg = _COVERS
    extra = []
    if dst.endswith(".mp3"):
        # APIC：MP3 的封面帧需要给出图片用途说明，否则部分解析器不认
        extra = ["-c:v", "copy", "-metadata:s:v", "title=Album cover",
                 "-metadata:s:v", "comment=Cover (front)"]
    else:
        # FLAC 的 PICTURE 块 / MP4 的 covr 原子：attached_pic 即可
        extra = ["-c:v", "copy", "-disposition:v", "attached_pic"]

    ffmpeg(["-i", src_audio, "-i", png, "-map", "0:a", "-map", "1:v"]
           + codec_args + extra + [dst])


# ---------------------------------------------------------------- 汇总

# 识别矩阵的对照基准。每行: 相对路径 <TAB> 容器 <TAB> 子编码
MANIFEST_NAME = "MANIFEST.tsv"


def report(out):
    exts = (".wav", ".aac", ".m4a", ".mp3", ".ogg", ".oga", ".opus", ".spx", ".flac")
    files = []
    for root, _dirs, names in os.walk(out):
        for n in sorted(names):
            if n.endswith(exts):
                files.append(os.path.join(root, n))
    files.sort()

    print(f"\n=== 生成完成: {os.path.abspath(out)} ===\n")
    print(f"{'文件':<42}{'大小':>10}  真实格式")
    print(f"{'-' * 42}{'-' * 10}  {'-' * 16}")

    kinds = {}
    total = 0
    rows = []
    for path in files:
        rel = os.path.relpath(path, out).replace(os.sep, "/")
        size = file_size(path)
        total += size
        container, codec = sniff(path)
        label = container + ("/" + codec if codec else "")
        kinds[label] = kinds.get(label, 0) + 1
        rows.append((rel, container, codec))
        print(f"{rel:<42}{human(size):>10}  {label}")

    # 写出识别矩阵的对照基准（供 src/test/probe_matrix_test.cj 读取）
    manifest = os.path.join(out, MANIFEST_NAME)
    with open(manifest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# path\tcontainer\tcodec\n")
        fh.write("# 由 gen_audio_fixtures.py 生成，作为探测层识别矩阵测试的对照基准。\n")
        fh.write("# container/codec 由本脚本的 sniff() 独立识别，与仓颉探测层互为交叉检查。\n")
        for rel, container, codec in rows:
            fh.write(f"{rel}\t{container}\t{codec}\n")

    print(f"\n共 {len(files)} 个文件，合计 {human(total)}，格式分布:")
    for label, count in sorted(kinds.items()):
        print(f"  {label:<16} {count}")
    print(f"\n识别矩阵基准已写入: {os.path.relpath(manifest, REPO_ROOT)}")

    print("\n核对解码结果:")
    print("  ffprobe -v error -show_entries "
          "stream=codec_name,sample_rate,channels -of default=nw=1 <文件>")
    print("\n核对标签（注意层级差异，写 tag 层测试时容易踩）:")
    print("  MP4  : 元数据在 format_tags")
    print("  OGG  : Vorbis comment 在 stream_tags，format_tags 读不到")


def main():
    # Windows 控制台默认不是 UTF-8，中文表头会乱码。尽量切到 UTF-8 ——
    # 失败也无害（纯粹是显示问题，不影响生成的文件与 MANIFEST 的内容）。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass

    ap = argparse.ArgumentParser(description="生成 audio4cj 的测试素材矩阵")
    ap.add_argument("outdir", nargs="?", default=DEFAULT_OUT,
                    help=f"输出目录（默认 {DEFAULT_OUT}）")
    ap.add_argument("--keep-ref", action="store_true",
                    help="复用已存在的参考 WAV，不重新生成")
    ap.add_argument("--only", default="",
                    help=f"逗号分隔的分组名，默认全部。可选: {', '.join(SECTIONS)}")
    ap.add_argument("--report-only", action="store_true",
                    help="只扫描素材并重写 MANIFEST.tsv，不做任何编码"
                         "（清理或手工增删素材后重建基准用）")
    ap.add_argument("--ffmpeg-dir", default="",
                    help="显式指定含 ffmpeg 可执行文件的目录")
    args = ap.parse_args()

    out = os.path.abspath(args.outdir)
    os.makedirs(out, exist_ok=True)

    if args.report_only:
        # 纯扫描，不需要 ffmpeg
        report(out)
        return

    if args.ffmpeg_dir:
        os.environ["FFMPEG_DIR"] = args.ffmpeg_dir

    resolve_tools()
    check_env()

    want = [s.strip() for s in args.only.split(",") if s.strip()] or list(SECTIONS)
    for s in want:
        if s not in SECTIONS:
            sys.exit(f"错误: 未知分组 '{s}'，可选: {', '.join(SECTIONS)}")

    # 参考信号是所有编码分组的输入源，任何分组都需要它
    refs = gen_reference(out, args.keep_ref)

    if "wav" in want:
        gen_wav(out, refs)
    if "flac" in want:
        gen_flac(out, refs)
    if "mp3" in want:
        gen_mp3(out, refs)
    if "ogg" in want:
        gen_ogg(out, refs)
    if "aac" in want:
        gen_aac(out, refs)
    if "mp4" in want:
        gen_mp4(out, refs)

    report(out)


if __name__ == "__main__":
    main()
