package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.pcm.reinterpretF32Bytes
import audio4cj.format.BitReader
import audio4cj.format.decodeFrame
import audio4cj.format.findFirstFrameOffset
import audio4cj.format.parseStreamInfo
import std.collection.ArrayList
import std.fs.*

/* ============================================================================
 * FLAC 帧解码测试（与 ffmpeg 基准逐样本对照）
 *
 * 【为什么这是最强验证】
 *   解码器最容易出的错不会让程序崩溃，而是让**样本值悄悄偏掉**
 *   （预测系数下标写反、zigzag 方向弄错、mid/side 还原少补一位……）。
 *   这些错误单元测试很难覆盖全，但"与一个成熟实现逐样本对照"能一次全部抓到。
 *
 *   因此本文件的判据是：对同一文件，纯仓颉解码器的输出与 **ffmpeg 的 golden
 *   基准**逐样本完全相同（最大差 0）。FLAC 全程整数运算，这个判据是成立的 ——
 *   只要归一化口径一致，就不该有任何误差，容差为 0 才有意义。
 *   （基准原先是 dr_libs 的输出；Tier 4 移除 C 依赖后改用 ffmpeg 基准，
 *     独立性反而更强：外部实现与我们的解码器之间没有任何共享代码。）
 *
 * 【归一化为什么不能复用 pcmToF32】
 *   WAV 的 8 位是无符号（需 -128 偏移），而 FLAC 的 8 位是**有符号**。
 *   因此这里使用 FLAC 口径 `sample / 2^(位深-1)`，与 ffmpeg 一致。
 * ========================================================================== */

/// 读取整个文件（测试辅助）。素材最大约 33 KB，用 1 MiB 缓冲一次读完。
private func ffReadAll(path: String): Array<UInt8> {
    let buf = Array<UInt8>(1 << 20, repeat: 0)
    var got: Int64 = 0
    try (f = File(path, Read)) {
        got = f.read(buf)
    }
    buf[0..got]
}

/// 最近一次纯仓颉解码**成功解出的帧数**（诊断用）。
///
/// 解码中途抛异常时，这个值能把"当前位偏移"翻译成"第几帧出的问题" ——
/// 位偏移本身对定位帮助有限，帧号才能快速收敛到具体的帧类型与预测方式。
private var ffLastFrameIndex: Int64 = 0

/// 用纯仓颉帧解码器解出整个文件的 f32 交错样本。
private func ffDecodePure(path: String): Array<Float32> {
    let data = ffReadAll(path)
    let info = parseStreamInfo(data)

    let reader = BitReader(data)
    reader.seekToBit(findFirstFrameOffset(data) * 8)

    let scale = Float32(Int64(1) << (info.bitsPerSample - 1))
    let out = ArrayList<Float32>()

    // 以 STREAMINFO 声明的总样本数为终止条件 —— 比"读到异常为止"精确，
    // 且顺带验证了声明长度与实际帧数一致
    var decoded: Int64 = 0
    ffLastFrameIndex = 0
    while (decoded < info.totalSamples) {
        let frame = decodeFrame(reader, info)
        ffLastFrameIndex += 1
        var i: Int64 = 0
        while (i < frame.blockSize) {
            var ch: Int64 = 0
            while (ch < frame.channels) {
                out.add(Float32(frame.samples[ch][i]) / scale)
                ch += 1
            }
            i += 1
        }
        decoded += frame.blockSize
    }
    out.toArray()
}

@Test
class FlacFrameTest {
    /// 帧级解码在**有基准的素材**上与 ffmpeg golden 逐样本一致。
    ///
    /// 【与 flac_bitstream_test 的分工】那里走的是**流式内核**（窗口回填 + 分块交付），
    ///   这里直接对整文件缓冲调 `decodeFrame` —— 两条驱动器压在同一个帧解码器上，
    ///   失效面并不相同（窗口边界 vs 整块缓冲），因此两者都保留，不是重复。
    ///
    /// 每个文件单独捕获异常：解码中途失步时，必须能指出**是哪个文件、第几帧**，
    /// 否则只看到一个位偏移，定位成本极高。
    @TestCase
    func decodedSamplesMatchGoldenOnCoveredFixtures() {
        if (gsSkipIfNoFixtures("decodedSamplesMatchGoldenOnCoveredFixtures")) {
            return
        }

        // (素材, golden 基准, 期望帧数)。期望帧数来自素材规格（见 scripts/gen_testdata.sh 的 DUR_*）。
        let fixtures = [
            ("testdata/flac/flac_s16_44100_stereo.flac", "sine_44100_stereo_s16.f32le", 44100),
            ("testdata/flac/flac_s16_44100_mono.flac", "sine_44100_mono_s16.f32le", 44100),
            ("testdata/flac/flac_s16_16000_mono.flac", "tone_16000_mono_s16.f32le", 16000),
            ("testdata/flac/flac_s24_44100_stereo.flac", "sine_44100_stereo_s24.f32le", 44100),
            // 2 秒素材：基准只覆盖其前 1 秒，故比前缀（正弦自 t=0 确定性生成）
            ("testdata/flac/flac_tagged.flac", "sine_44100_stereo_s16.f32le", 88200),
            ("testdata/flac/flac_cover.flac", "sine_44100_stereo_s16.f32le", 88200)
        ]

        for ((path, golden, expectFrames) in fixtures) {
            var pure = Array<Float32>(0, repeat: 0.0)
            try {
                pure = ffDecodePure(path)
            } catch (e: CorruptedFileException) {
                @Fail("${path} 在第 ${ffLastFrameIndex} 帧解码失败：${e.message}")
                continue
            }

            let info = parseStreamInfo(ffReadAll(path))
            if (pure.size != expectFrames * info.channels) {
                @Fail("${path}：帧数不符（实际 ${pure.size / info.channels}，规格 ${expectFrames}）")
                continue
            }

            let expected = gsLoadGolden(golden)
            let count = if (expected.size < pure.size) {
                expected.size
            } else {
                pure.size
            }
            if (let Some(msg) <- gsDiffPrefix(pure, 0, expected, count)) {
                @Fail("${path}（帧级）vs ${golden}：${msg}")
            }
        }
    }

    /// 逐帧定位首个不匹配的帧，并报告其块大小与声道分配。
    ///
    /// 这条用例的存在是为了让"样本值不一致"能快速收敛到**具体的帧特征**，
    /// 而不是靠猜：知道是第几帧、用了哪种去相关之后，就能直接构造针对性
    /// 的复现，不必在整文件里大海捞针。
    ///
    /// 基准换成了 ffmpeg 的 golden（原先比的是 dr_libs 的输出）—— 判据的独立性
    /// 因此更强：外部实现与我们的解码器之间没有共享任何代码。
    @TestCase
    func reportsFirstMismatchingFrame() {
        if (gsSkipIfNoFixtures("reportsFirstMismatchingFrame")) {
            return
        }

        let path = "testdata/flac/flac_s16_44100_stereo.flac"
        let data = ffReadAll(path)
        let info = parseStreamInfo(data)
        let golden = gsLoadGolden("sine_44100_stereo_s16.f32le")

        let reader = BitReader(data)
        reader.seekToBit(findFirstFrameOffset(data) * 8)
        let scale = Float32(Int64(1) << (info.bitsPerSample - 1))

        var base: Int64 = 0
        var index: Int64 = 0
        while (base < golden.size) {
            let frame = decodeFrame(reader, info)
            let perFrame = frame.blockSize * frame.channels

            var maxDiff: Float32 = 0.0
            var i: Int64 = 0
            while (i < perFrame && base + i < golden.size) {
                let pure = Float32(frame.samples[i % frame.channels][i / frame.channels]) / scale
                let diff = if (pure > golden[base + i]) {
                    pure - golden[base + i]
                } else {
                    golden[base + i] - pure
                }
                if (diff > maxDiff) {
                    maxDiff = diff
                }
                i += 1
            }

            if (maxDiff > 0.0) {
                @Fail(
                    "首个不匹配：第 ${index} 帧（0 起始），块大小 ${frame.blockSize}，声道分配 ${frame.channelAssignment}，最大差 ${maxDiff}")
                return
            }

            base += perFrame
            index += 1
        }
    }

    /// 静音文件是 CONSTANT 子帧的典型形态：整块同一个值。
    ///
    /// 单独固定一条，是因为 CONSTANT 是四种预测类型里唯一不做残差解码的，
    /// 一旦它出错，会被其它文件的失败掩盖（其它文件多为 LPC/FIXED）。
    @TestCase
    func silenceUsesConstantSubframesAndDecodesToZero() {
        if (gsSkipIfNoFixtures("silenceUsesConstantSubframesAndDecodesToZero")) {
            return
        }

        let samples = ffDecodePure("testdata/flac/flac_silence.flac")
        if (samples.size == 0) {
            @Fail("静音文件不应解出 0 个样本")
        }
        var i: Int64 = 0
        while (i < samples.size) {
            if (samples[i] != 0.0) {
                @Fail("静音文件第 ${i} 个样本应为 0，实得 ${samples[i]}")
                return
            }
            i += 1
        }
    }

    /// 帧同步码被破坏 -> 必须抛出库内异常，而不是解出垃圾。
    @TestCase
    func rejectsBrokenFrameSync() {
        if (gsSkipIfNoFixtures("rejectsBrokenFrameSync")) {
            return
        }

        let data = ffReadAll("testdata/flac/flac_s16_44100_stereo.flac")
        let info = parseStreamInfo(data)
        let frameStart = findFirstFrameOffset(data)

        // 破坏帧起点第一个字节的高 6 位（同步码高 8 位为 0xFF）
        data[frameStart] = 0x00

        let reader = BitReader(data)
        reader.seekToBit(frameStart * 8)
        @AssertThrows[CorruptedFileException](decodeFrame(reader, info))
    }

    /// 元数据块长度被改成越界值 -> 定位首帧时必须拒绝，而不是把帧起点定到文件中间。
    @TestCase
    func rejectsMetadataBlockOverrunningFile() {
        if (gsSkipIfNoFixtures("rejectsMetadataBlockOverrunningFile")) {
            return
        }

        let data = ffReadAll("testdata/flac/flac_s16_44100_stereo.flac")
        // 首个元数据块的 24 位长度位于 byte[5..7]，改成远超文件大小
        data[5] = 0xFF
        data[6] = 0xFF
        data[7] = 0xFF
        @AssertThrows[CorruptedFileException](findFirstFrameOffset(data))
    }
}
