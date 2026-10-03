package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.drlibs.reinterpretF32Bytes
import audio4cj.format.BitReader
import audio4cj.format.DrLibsFlacKernel
import audio4cj.format.decodeFrame
import audio4cj.format.findFirstFrameOffset
import audio4cj.format.parseStreamInfo
import std.collection.ArrayList
import std.fs.*

/* ============================================================================
 * FLAC 帧解码测试（纯仓颉 vs dr_libs 逐样本对照）
 *
 * 【为什么这是最强验证】
 *   解码器最容易出的错不会让程序崩溃，而是让**样本值悄悄偏掉**
 *   （预测系数下标写反、zigzag 方向弄错、mid/side 还原少补一位……）。
 *   这些错误单元测试很难覆盖全，但"与一个成熟实现逐样本对照"能一次全部抓到。
 *
 *   因此本文件的判据是：对同一文件，纯仓颉解码器的输出与 dr_libs 的输出
 *   **逐样本完全相同（最大差 0）**。FLAC 全程整数运算，这个判据是成立的 ——
 *   只要归一化口径一致，就不该有任何误差，容差为 0 才有意义。
 *
 * 【归一化为什么不能复用 pcmToF32】
 *   WAV 的 8 位是无符号（需 -128 偏移），而 FLAC 的 8 位是**有符号**。
 *   因此这里使用 FLAC 口径 `sample / 2^(位深-1)`，与 dr_flac 一致。
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

/// 用 dr_libs（FFI）解出整个文件的 f32 交错样本。
private func ffDecodeFfi(path: String): Array<Float32> {
    let out = ArrayList<Float32>()
    let kernel = DrLibsFlacKernel(path)
    let channels = kernel.channels()

    let framesPerChunk: Int64 = 4096
    let buf = Array<UInt8>(framesPerChunk * channels * 4, repeat: 0)

    var got: Int64 = 1
    while (got > 0) {
        got = kernel.readF32Into(buf, framesPerChunk)
        if (got <= 0) {
            break
        }
        // 只重解释本批实际写入的字节
        for (v in reinterpretF32Bytes(buf[0..got * channels * 4])) {
            out.add(v)
        }
    }
    kernel.close()
    out.toArray()
}

/// 对照单个文件，不一致时给出可定位的信息（首个差异位置 + 最大差）。
private func ffCompareOne(path: String): Unit {
    let pure = ffDecodePure(path)
    let ffi = ffDecodeFfi(path)

    if (pure.size != ffi.size) {
        @Fail("${path} 样本数不一致：纯仓颉 ${pure.size} / FFI ${ffi.size}")
        return
    }

    var maxDiff: Float32 = 0.0
    var firstBad: Int64 = -1
    var i: Int64 = 0
    while (i < pure.size) {
        let diff = if (pure[i] > ffi[i]) {
            pure[i] - ffi[i]
        } else {
            ffi[i] - pure[i]
        }
        if (diff > maxDiff) {
            maxDiff = diff
        }
        if (diff > 0.0 && firstBad < 0) {
            firstBad = i
        }
        i += 1
    }

    if (maxDiff > 0.0) {
        @Fail(
            "${path} 存在不一致：首个差异在样本 ${firstBad}（纯仓颉 ${pure[firstBad]} / FFI ${ffi[firstBad]}），最大差 ${maxDiff}")
    }
}

@Test
class FlacFrameTest {
    /// 逐样本对照：仓库内全部 FLAC 素材（覆盖 16/24 位、单/立体声、16 kHz、静音、带标签、带封面）。
    ///
    /// 每个文件单独捕获异常：解码中途失步时，必须能指出**是哪个文件、第几帧**，
    /// 否则只看到一个位偏移，定位成本极高。
    @TestCase
    func decodedSamplesMatchFfiKernel() {
        let fixtures = [
            "testdata/flac/flac_s16_44100_stereo.flac",
            "testdata/flac/flac_s16_44100_mono.flac",
            "testdata/flac/flac_s16_16000_mono.flac",
            "testdata/flac/flac_s24_44100_stereo.flac",
            "testdata/flac/flac_silence.flac",
            "testdata/flac/flac_tagged.flac",
            "testdata/flac/flac_cover.flac"
        ]
        for (path in fixtures) {
            try {
                ffCompareOne(path)
            } catch (e: CorruptedFileException) {
                @Fail("${path} 在第 ${ffLastFrameIndex} 帧解码失败：${e.message}")
            }
        }
    }

    /// 逐帧定位首个不匹配的帧，并报告其块大小与声道分配。
    ///
    /// 这条用例的存在是为了让"样本值不一致"能快速收敛到**具体的帧特征**，
    /// 而不是靠猜：知道是第几帧、用了哪种去相关之后，就能直接构造针对性
    /// 的复现，不必在整文件里大海捞针。修好后它同时是一条回归用例。
    @TestCase
    func reportsFirstMismatchingFrame() {
        let path = "testdata/flac/flac_s16_44100_stereo.flac"
        let data = ffReadAll(path)
        let info = parseStreamInfo(data)
        let ffi = ffDecodeFfi(path)

        let reader = BitReader(data)
        reader.seekToBit(findFirstFrameOffset(data) * 8)
        let scale = Float32(Int64(1) << (info.bitsPerSample - 1))

        var base: Int64 = 0
        var index: Int64 = 0
        while (base < ffi.size) {
            let frame = decodeFrame(reader, info)
            let perFrame = frame.blockSize * frame.channels

            var maxDiff: Float32 = 0.0
            var i: Int64 = 0
            while (i < perFrame && base + i < ffi.size) {
                let pure = Float32(frame.samples[i % frame.channels][i / frame.channels]) / scale
                let diff = if (pure > ffi[base + i]) {
                    pure - ffi[base + i]
                } else {
                    ffi[base + i] - pure
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
        let data = ffReadAll("testdata/flac/flac_s16_44100_stereo.flac")
        // 首个元数据块的 24 位长度位于 byte[5..7]，改成远超文件大小
        data[5] = 0xFF
        data[6] = 0xFF
        data[7] = 0xFF
        @AssertThrows[CorruptedFileException](findFirstFrameOffset(data))
    }
}
