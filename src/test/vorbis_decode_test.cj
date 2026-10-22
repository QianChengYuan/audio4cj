package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import std.collection.ArrayList
import std.fs.*

/* ============================================================================
 * Ogg Vorbis 纯仓颉解码 —— 端到端回归
 *
 * 【为什么用「帧数 + 能量包络」而不是逐样本基准】
 *   Vorbis 是有损格式，而且本库的 IMDCT、floor1、residue 都是独立实现；
 *   不同实现的浮点运算顺序必然带来 1e-7 量级的差异。要求逐样本相等会把
 *   "实现正确"与"浮点舍入完全一致"混为一谈。
 *
 *   但只比总能量又太粗：丢一整个 packet、声道错位、采样率算错，都可能
 *   碰巧让总能量接近。因此这里采用四段能量 + 峰值 + 过零数：
 *     · 帧数/采样数：抓 packet 边界、首包丢弃、末页 granule 裁剪；
 *     · 四段能量：抓局部丢帧、增益错误、时间轴截断；
 *     · 峰值：抓幅度缩放/溢出；
 *     · 过零数：抓采样率或频率轴错误（440Hz 正弦在 44.1kHz 下约 880 次/秒）。
 *
 * 【基准来源】
 *   期望值由 libsndfile（soundfile 0.14.0，libvorbis 解码）导出 f32 后统计，
 *   不是用本库自己的输出回填。它和 ffmpeg 的差别只出现在 q4 的末 128 帧：
 *   ffmpeg 9.0.2 会少输出 128 帧（其 Ogg demuxer 的 discard padding 处理），
 *   libsndfile 输出完整的 44100 帧，与文件 granule 一致。本库与 libsndfile
 *   逐样本对齐到 1e-7 以内，故以 libsndfile 为基准。
 * ========================================================================== */

/// 一个 Vorbis 素材的期望形态与能量特征。
private class VorbisCase {
    let path: String
    let sampleRate: Int64
    let channels: Int64
    let frames: Int64
    let energy: Float64
    let peak: Float64
    let crossings: Array<Int64>
    let segments: Array<Float64>

    init(
        path: String,
        sampleRate: Int64,
        channels: Int64,
        frames: Int64,
        energy: Float64,
        peak: Float64,
        crossings: Array<Int64>,
        segments: Array<Float64>
    ) {
        this.path = path
        this.sampleRate = sampleRate
        this.channels = channels
        this.frames = frames
        this.energy = energy
        this.peak = peak
        this.crossings = crossings
        this.segments = segments
    }
}

/// 6 个真实素材覆盖：q0/q4/q8（码本规模与 residue 分支）、单声道、
/// 带 Vorbis comment 的素材、全静音（零能量边界）。
private let VD_CASES: Array<VorbisCase> = [
    VorbisCase(
        "testdata/ogg/ogg_vorbis_q0.ogg",
        44100,
        2,
        44100,
        345.45281522353986,
        0.09165722131729126,
        [879, 879],
        [86.411134, 86.63632, 85.995735, 86.409626]
    ),
    VorbisCase(
        "testdata/ogg/ogg_vorbis_q4.ogg",
        44100,
        2,
        44100,
        348.57742977085417,
        0.0905022844672203,
        [880, 880],
        [87.070411, 87.209121, 87.116751, 87.181147]
    ),
    VorbisCase(
        "testdata/ogg/ogg_vorbis_q8.ogg",
        44100,
        2,
        44100,
        349.8464740252333,
        0.08956442773342133,
        [880, 880],
        [87.485032, 87.526984, 87.480208, 87.35425]
    ),
    VorbisCase(
        "testdata/ogg/ogg_vorbis_q4_mono.ogg",
        16000,
        1,
        48000,
        369.6843577528797,
        0.13081929087638855,
        [6000],
        [92.334602, 92.37256, 92.50926, 92.467936]
    ),
    VorbisCase(
        "testdata/ogg/ogg_vorbis_tagged.ogg",
        44100,
        2,
        88200,
        697.9076794166368,
        0.0905022844672203,
        [1760, 1760],
        [174.279532, 174.331928, 174.721492, 174.574727]
    ),
    VorbisCase(
        "testdata/ogg/ogg_vorbis_silence.ogg",
        44100,
        2,
        132300,
        0.0,
        0.0,
        [0, 0],
        [0.0, 0.0, 0.0, 0.0]
    )
];

// ---------------------------------------------------------------------------
// 统计辅助
// ---------------------------------------------------------------------------

private func vdAbs(x: Float64): Float64 {
    if (x < 0.0) {
        -x
    } else {
        x
    }
}

private func vdEnergy(samples: Array<Float32>): Float64 {
    var sum = 0.0
    var i = 0
    while (i < samples.size) {
        let v = Float64(samples[i])
        sum += v * v
        i += 1
    }
    sum
}

private func vdPeak(samples: Array<Float32>): Float64 {
    var peak = 0.0
    var i = 0
    while (i < samples.size) {
        let v = vdAbs(Float64(samples[i]))
        if (v > peak) {
            peak = v
        }
        i += 1
    }
    peak
}

/// 每个声道的过零次数（方向无关：<=0 -> >0 与 >=0 -> <0 都算）。
private func vdCrossings(samples: Array<Float32>, channels: Int64): Array<Int64> {
    let out = Array<Int64>(channels, repeat: 0)
    var c = 0
    while (c < channels) {
        var prev = samples[c]
        var count: Int64 = 0
        var i = c + channels
        while (i < samples.size) {
            let cur = samples[i]
            if ((prev <= 0.0 && cur > 0.0) || (prev >= 0.0 && cur < 0.0)) {
                count += 1
            }
            prev = cur
            i += channels
        }
        out[c] = count
        c += 1
    }
    out
}

/// 把样本均分成 4 段，返回每段的平方和（跨声道累计）。
private func vdSegmentEnergies(samples: Array<Float32>, frames: Int64, channels: Int64): Array<Float64> {
    let out = Array<Float64>(4, repeat: 0.0)
    var s = 0
    while (s < 4) {
        let lo = frames * Int64(s) / 4
        let hi = frames * Int64(s + 1) / 4
        var sum = 0.0
        var i = lo * channels
        let end = hi * channels
        while (i < end) {
            let v = Float64(samples[i])
            sum += v * v
            i += 1
        }
        out[s] = sum
        s += 1
    }
    out
}

private func vdReadAllBytes(path: String): Array<UInt8> {
    var out = Array<UInt8>(0, repeat: 0)
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        if (got != size) {
            throw Exception("读取素材不完整：${path}（${got}/${size}）")
        }
        out = buf
    }
    out
}

/// 对单个案例做形状 + 能量包络检查，错误累积到 errors。
private func vdCheckCase(c: VorbisCase, errors: ArrayList<String>): Unit {
    let f = AudioFile.open(c.path)
    try {
        let info = f.info()
        if (info.sampleRate != c.sampleRate) {
            errors.add("${c.path} 采样率：实际 ${info.sampleRate}，期望 ${c.sampleRate}")
        }
        if (info.channels != c.channels) {
            errors.add("${c.path} 声道数：实际 ${info.channels}，期望 ${c.channels}")
        }
        if (info.bitDepth != 32) {
            errors.add("${c.path} 位深标记：实际 ${info.bitDepth}，期望 32（f32）")
        }
        if (info.totalFrames != c.frames) {
            errors.add("${c.path} 声明帧数：实际 ${info.totalFrames}，期望 ${c.frames}")
        }
        let expectedMs = c.frames * 1000 / c.sampleRate
        if (info.durationMs != expectedMs) {
            errors.add("${c.path} 时长：实际 ${info.durationMs}ms，期望 ${expectedMs}ms")
        }

        let fmt = f.format()
        if (fmt.container != "ogg" || fmt.codec != "vorbis" || fmt.codecId != "ogg/vorbis") {
            errors.add("${c.path} 格式标识：${fmt.container}/${fmt.codec}/${fmt.codecId}")
        }
        let tracks = f.tracks()
        if (tracks.size != 1 || tracks[0].codecId != "vorbis") {
            errors.add("${c.path} 轨道描述不符合预期")
        }

        let buf = f.readAll()
        if (buf.frameCount != c.frames) {
            errors.add("${c.path} 解出帧数：实际 ${buf.frameCount}，期望 ${c.frames}")
        }
        let expectedSamples = c.frames * c.channels
        if (buf.sampleCount != expectedSamples) {
            errors.add("${c.path} 解出样本数：实际 ${buf.sampleCount}，期望 ${expectedSamples}")
        }
        if (buf.frameCount != c.frames) {
            // 帧数已经错了，后续统计没有意义；直接返回，避免用错位数据产生噪声告警。
            return
        }

        let samples = buf.samples
        let energy = vdEnergy(samples)
        if (c.energy == 0.0) {
            if (energy != 0.0) {
                errors.add("${c.path} 静音素材能量：实际 ${energy}，期望 0")
            }
        } else if (vdAbs(energy - c.energy) > c.energy * 0.01) {
            errors.add("${c.path} 总能量：实际 ${energy}，期望 ${c.energy}")
        }

        let peak = vdPeak(samples)
        if (c.peak == 0.0) {
            if (peak != 0.0) {
                errors.add("${c.path} 静音素材峰值：实际 ${peak}，期望 0")
            }
        } else if (vdAbs(peak - c.peak) > c.peak * 0.01) {
            errors.add("${c.path} 峰值：实际 ${peak}，期望 ${c.peak}")
        }

        let crossings = vdCrossings(samples, c.channels)
        var ci = 0
        while (ci < c.crossings.size) {
            let delta = if (crossings[ci] >= c.crossings[ci]) {
                crossings[ci] - c.crossings[ci]
            } else {
                c.crossings[ci] - crossings[ci]
            }
            if (delta > 2) {
                errors.add("${c.path} 声道 ${ci} 过零数：实际 ${crossings[ci]}，期望 ${c.crossings[ci]}")
            }
            ci += 1
        }

        let segments = vdSegmentEnergies(samples, c.frames, c.channels)
        var si = 0
        while (si < 4) {
            let expected = c.segments[si]
            if (expected == 0.0) {
                if (segments[si] != 0.0) {
                    errors.add("${c.path} 第 ${si} 段能量：实际 ${segments[si]}，期望 0")
                }
            } else if (vdAbs(segments[si] - expected) > expected * 0.02) {
                errors.add("${c.path} 第 ${si} 段能量：实际 ${segments[si]}，期望 ${expected}")
            }
            si += 1
        }
    } finally {
        f.close()
    }
}

private func vdSamplesEqual(a: Array<Float32>, aOffset: Int64, b: Array<Float32>, bOffset: Int64, count: Int64): Bool {
    var i: Int64 = 0
    while (i < count) {
        if (a[aOffset + i] != b[bOffset + i]) {
            return false
        }
        i += 1
    }
    true
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class VorbisDecodeTest {
    /// 6 个真实素材：帧数、形状、总能量、峰值、过零数与四段能量包络。
    @TestCase
    func decodesFixturesWithExpectedShapeAndEnergyEnvelope(): Unit {
        if (gsSkipIfNoFixtures("decodesFixturesWithExpectedShapeAndEnergyEnvelope")) {
            return
        }

        let errors = ArrayList<String>()
        for (c in VD_CASES) {
            vdCheckCase(c, errors)
        }
        if (!errors.isEmpty()) {
            @Fail("Vorbis 解码回归失败：\n${errors.toString()}")
        }
    }

    /// seek 的正确性用「与从头解码的同一段逐样本相同」来判定。
    ///
    /// 本库的 seek 第一版是"重开 + 从流首解码丢弃到目标帧"，因此它必须与
    /// 顺序解码在位级上一致；不一致只可能是丢弃边界/缓存拼接写错了。
    @TestCase
    func seekMatchesSequentialDecode(): Unit {
        if (gsSkipIfNoFixtures("seekMatchesSequentialDecode")) {
            return
        }

        let path = "testdata/ogg/ogg_vorbis_q4.ogg"
        let channels: Int64 = 2

        let fullFile = AudioFile.open(path)
        var full: Array<Float32> = []
        try {
            full = fullFile.readAll().samples
        } finally {
            fullFile.close()
        }

        let s1 = AudioFile.open(path)
        let landed = s1.seekTo(500)
        if (landed != 500) {
            @Fail("seekTo(500) 返回 ${landed}，期望 500")
        }
        let tail = s1.readAll()
        let targetFrame: Int64 = 22050
        let expectedFrames = 44100 - targetFrame
        if (tail.frameCount != expectedFrames) {
            @Fail("seek 后帧数：实际 ${tail.frameCount}，期望 ${expectedFrames}")
        }
        let expectedSamples = expectedFrames * channels
        if (tail.sampleCount != expectedSamples) {
            @Fail("seek 后样本数：实际 ${tail.sampleCount}，期望 ${expectedSamples}")
        }
        if (!vdSamplesEqual(full, targetFrame * channels, tail.samples, 0, expectedSamples)) {
            @Fail("seek(500ms) 后的 PCM 与从头顺序解码不一致")
        }

        // 回到 0：整段必须与首次完整解码逐样本相同。
        // readAll 是一次性 API（消费完即关闭 AudioFile），故每一步重新打开。
        let s2 = AudioFile.open(path)
        let zero = s2.seekTo(0)
        if (zero != 0) {
            @Fail("seekTo(0) 返回 ${zero}，期望 0")
        }
        let again = s2.readAll()
        if (again.frameCount != 44100) {
            @Fail("seek 回 0 后帧数：实际 ${again.frameCount}，期望 44100")
        }
        if (!vdSamplesEqual(full, 0, again.samples, 0, full.size)) {
            @Fail("seek(0) 后的 PCM 与首次完整解码不一致")
        }

        // 越过末尾：按契约钳制到时长（1000ms），并立即读完。
        let s3 = AudioFile.open(path)
        let beyond = s3.seekTo(5000)
        if (beyond != 1000) {
            @Fail("seekTo(5000) 返回 ${beyond}，期望钳制到 1000")
        }
        if (!s3.readAll().isEmpty()) {
            @Fail("seek 到末尾后 readAll 应当为空")
        }
    }

    /// openBytes 与 open 必须走同一条解码内核，输出逐样本相同。
    @TestCase
    func openBytesMatchesFileDecode(): Unit {
        if (gsSkipIfNoFixtures("openBytesMatchesFileDecode")) {
            return
        }

        let path = "testdata/ogg/ogg_vorbis_q4.ogg"
        let bytes = vdReadAllBytes(path)

        let fileDecoded = AudioFile.open(path)
        var expected: Array<Float32> = []
        var expectedInfo: AudioInfo = AudioInfo(0, 0, 0, 0, -1)
        try {
            expectedInfo = fileDecoded.info()
            expected = fileDecoded.readAll().samples
        } finally {
            fileDecoded.close()
        }

        let memoryDecoded = AudioFile.openBytes(bytes)
        try {
            let info = memoryDecoded.info()
            if (info.totalFrames != expectedInfo.totalFrames || info.sampleRate != expectedInfo.sampleRate ||
                info.channels != expectedInfo.channels) {
                @Fail("openBytes 的 info 与 open 不一致")
            }
            let actual = memoryDecoded.readAll().samples
            if (actual.size != expected.size) {
                @Fail("openBytes 样本数：实际 ${actual.size}，期望 ${expected.size}")
            }
            if (!vdSamplesEqual(expected, 0, actual, 0, expected.size)) {
                @Fail("openBytes 的 PCM 与 open 不一致")
            }
        } finally {
            memoryDecoded.close()
        }
    }

    /// Vorbis comment 必须能从生产读取器（而不是独立的 readTags 旁路）拿到。
    @TestCase
    func metadataIsAvailableOnOpenedFile(): Unit {
        if (gsSkipIfNoFixtures("metadataIsAvailableOnOpenedFile")) {
            return
        }

        let f = AudioFile.open("testdata/ogg/ogg_vorbis_tagged.ogg")
        try {
            let tag = f.metadata()
            if (tag.title.getOrThrow() != "OGG Vorbis 标题") {
                @Fail("标题解析错误：${tag.title.getOrThrow()}")
            }
            if (tag.artist.getOrThrow() != "元宝") {
                @Fail("艺术家解析错误：${tag.artist.getOrThrow()}")
            }
            if (tag.album.getOrThrow() != "Test Fixtures") {
                @Fail("专辑解析错误：${tag.album.getOrThrow()}")
            }
            if (tag.year.getOrThrow() != "2026") {
                @Fail("年份解析错误：${tag.year.getOrThrow()}")
            }
            if (tag.genre.getOrThrow() != "Test") {
                @Fail("流派解析错误：${tag.genre.getOrThrow()}")
            }
            if (tag.track.getOrThrow() != 5) {
                @Fail("轨号解析错误：${tag.track.getOrThrow()}")
            }

            // 读标签不要求先解码；同一条 metadata 也不应改变播放游标。
            if (f.info().totalFrames != 88200) {
                @Fail("读取 metadata 后 info().totalFrames 异常")
            }
        } finally {
            f.close()
        }
    }

    /// 页 CRC 必须真正生效：改掉末页正文一个字节，解码必须在读取该页时失败。
    ///
    /// 打开阶段只扫描页头（不做正文 CRC），所以这里先确认 openBytes 能成功，
    /// 再确认 readAll 抛 CorruptedFileException —— 这正好覆盖"页体在播放路径上
    /// 才被校验"的真实调用顺序。
    @TestCase
    func corruptedPageBodyFailsCrc(): Unit {
        if (gsSkipIfNoFixtures("corruptedPageBodyFailsCrc")) {
            return
        }

        let path = "testdata/ogg/ogg_vorbis_q4.ogg"
        let bytes = vdReadAllBytes(path)
        let corrupt = bytes.clone()
        corrupt[corrupt.size - 1] = corrupt[corrupt.size - 1] ^ 0xFFu8

        var opened = false
        var rejected = false
        try {
            let f = AudioFile.openBytes(corrupt)
            opened = true
            try {
                let _ = f.readAll()
            } catch (e: CorruptedFileException) {
                rejected = true
            } finally {
                f.close()
            }
        } catch (e: CorruptedFileException) {
            // 有些布局下末字节可能落在页头/段表上，open 阶段就拒绝也符合契约。
            opened = true
            rejected = true
        }

        if (!opened || !rejected) {
            @Fail("末页正文被破坏后应当以 CRC 错误拒绝（opened=${opened}, rejected=${rejected}）")
        }
    }

    /// 截断必须给出 CorruptedFileException，而不是越界异常或静默短音频。
    @TestCase
    func truncatedStreamFailsGracefully(): Unit {
        if (gsSkipIfNoFixtures("truncatedStreamFailsGracefully")) {
            return
        }

        let path = "testdata/ogg/ogg_vorbis_q4.ogg"
        let bytes = vdReadAllBytes(path)
        let truncated = bytes[0..bytes.size - 10]

        var rejected = false
        try {
            let f = AudioFile.openBytes(truncated)
            f.close()
        } catch (e: CorruptedFileException) {
            rejected = true
        }
        if (!rejected) {
            @Fail("截断的 Ogg Vorbis 流应当抛 CorruptedFileException")
        }
    }
}
