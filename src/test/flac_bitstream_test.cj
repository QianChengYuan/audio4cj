package audio4cj.test

import audio4cj.drlibs.reinterpretF32Bytes
import audio4cj.format.DrLibsFlacKernel
import audio4cj.format.FlacDecodeKernel
import audio4cj.format.PureFlacKernel
import std.collection.ArrayList

/* ============================================================================
 * 纯仓颉流式内核测试
 *
 * 【本文件的写法本身就是一次验证】
 *   `fbDecodeAll` 的参数类型是 `FlacDecodeKernel` 接口 —— 同一段驱动代码
 *   既能跑 FFI 实现也能跑纯仓颉实现。若两者输出一致，就说明"换内核"
 *   对上层完全透明，这正是当初抽出该接口的目的。
 *
 * 【块大小刻意取两种】
 *   1. 4096 —— 与帧边界对齐（通常的调用形态）；
 *   2. 1000 —— **刻意不与帧边界对齐**，用来压测 pending 路径：
 *      一帧解完但调用方只要一部分时，剩余样本必须留待下次交付，
 *      这条路径只有在块大小不是帧大小整数倍时才会被走到。
 * ========================================================================== */

/// 用给定内核对整个文件分块解码，返回 f32 交错样本。
private func fbDecodeAll(kernel: FlacDecodeKernel, chunkFrames: Int64): Array<Float32> {
    let channels = kernel.channels()
    let buf = Array<UInt8>(chunkFrames * channels * 4, repeat: 0)
    let out = ArrayList<Float32>()

    var got: Int64 = 1
    while (got > 0) {
        got = kernel.readF32Into(buf, chunkFrames)
        if (got <= 0) {
            break
        }
        for (v in reinterpretF32Bytes(buf[0..got * channels * 4])) {
            out.add(v)
        }
    }
    out.toArray()
}

/// 对照两个内核在指定块大小下的输出。
///
/// 纯仓颉侧的解码包在 try 里：一旦抛异常，立即取出内核的窗口/游标状态，
/// 把"比特流截断"翻译成可判定的位置关系（见 diagnosticState 的说明）。
private func fbCompare(path: String, chunkFrames: Int64): Unit {
    let ffiKernel = DrLibsFlacKernel(path)
    let ffi = fbDecodeAll(ffiKernel, chunkFrames)
    ffiKernel.close()

    let pureKernel = PureFlacKernel(path)
    var pure = Array<Float32>(0, repeat: 0.0)
    var failure: ?String = None
    try {
        pure = fbDecodeAll(pureKernel, chunkFrames)
    } catch (e: Exception) {
        failure = e.message
    }

    if (let Some(message) <- failure) {
        let (cursor, windowOffset, valid, firstFrame, delivered) = pureKernel.diagnosticState()
        pureKernel.close()
        @Fail(
            "${path}（块 ${chunkFrames}）解码失败：${message}\n" +
            "    游标=${cursor} 窗口起点=${windowOffset} 有效长度=${valid} 首帧偏移=${firstFrame} 已交付=${delivered}")
        return
    }
    pureKernel.close()

    if (pure.size != ffi.size) {
        @Fail("${path}（块 ${chunkFrames}）样本数不一致：纯仓颉 ${pure.size} / FFI ${ffi.size}")
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
            "${path}（块 ${chunkFrames}）不一致：首个差异样本 ${firstBad}（纯 ${pure[firstBad]} / FFI ${ffi[firstBad]}），最大差 ${maxDiff}")
    }
}

@Test
class FlacBitstreamTest {
    /// 全部真实素材上与 dr_libs 逐样本一致（块大小与帧边界对齐）。
    @TestCase
    func streamingMatchesFfiOnAllFixtures() {
        // 素材顺序刻意把**曾触发回填缺陷**的三个文件排在前面：
        // 一旦回归，失败信息会指向最能说明问题的那一个。
        // （fbCompare 内部已捕获异常并输出窗口/游标状态，故此处不再包 try。）
        let fixtures = [
            "testdata/flac/flac_s16_44100_mono.flac",
            "testdata/flac/flac_tagged.flac",
            "testdata/flac/flac_cover.flac",
            "testdata/flac/flac_s16_44100_stereo.flac",
            "testdata/flac/flac_s16_16000_mono.flac",
            "testdata/flac/flac_s24_44100_stereo.flac",
            "testdata/flac/flac_silence.flac"
        ]
        for (path in fixtures) {
            fbCompare(path, 4096)
        }
    }

    /// 块大小**不与帧边界对齐**时仍须逐样本一致 —— 这条专门压测 pending 路径。
    @TestCase
    func oddChunkSizeMatchesFfi() {
        fbCompare("testdata/flac/flac_s16_44100_stereo.flac", 1000)
        fbCompare("testdata/flac/flac_s24_44100_stereo.flac", 1000)
    }

    /// 极小块（小到一帧都装不下）仍须正确 —— 此时 pending 会跨多次调用累积。
    @TestCase
    func tinyChunkSizeMatchesFfi() {
        fbCompare("testdata/flac/flac_s16_44100_stereo.flac", 7)
    }

    /// 内核报出的参数必须与 STREAMINFO 一致（顺带验证流式元数据解析）。
    @TestCase
    func kernelReportsStreamInfoParameters() {
        let path = "testdata/flac/flac_s24_44100_stereo.flac"
        let kernel = PureFlacKernel(path)
        let ffi = DrLibsFlacKernel(path)

        @Expect(kernel.sampleRate(), ffi.sampleRate())
        @Expect(kernel.channels(), ffi.channels())
        @Expect(kernel.bitsPerSample(), ffi.bitsPerSample())
        @Expect(kernel.totalFrames(), ffi.totalFrames())

        kernel.close()
        ffi.close()
    }

    /// seek 后读出的样本，必须与"从头顺序解码到该位置"的样本逐位相同。
    ///
    /// 目标刻意包含**落在帧中间**的位置（如 4097、1001）：
    /// 帧粒度与请求粒度不一致是 seek 最容易出错的地方。
    @TestCase
    func seekMatchesSequentialDecode() {
        let path = "testdata/flac/flac_s16_44100_stereo.flac"
        let reference = PureFlacKernel(path)
        let full = fbDecodeAll(reference, 4096)
        reference.close()

        let channels: Int64 = 2
        let targets = [0, 1, 1001, 4096, 4097, 20000, 40000]

        for (target in targets) {
            let kernel = PureFlacKernel(path)
            if (!kernel.seekToFrame(target)) {
                @Fail("seek 到 ${target} 返回 false")
                kernel.close()
                continue
            }

            let buf = Array<UInt8>(512 * channels * 4, repeat: 0)
            let got = kernel.readF32Into(buf, 512)
            let samples = reinterpretF32Bytes(buf[0..got * channels * 4])

            var i: Int64 = 0
            var mismatch: Bool = false
            while (i < samples.size) {
                let refIndex = target * channels + i
                if (refIndex >= full.size) {
                    break
                }
                if (samples[i] != full[refIndex]) {
                    @Fail(
                        "seek 到 ${target} 后第 ${i} 个样本不符：${samples[i]} vs 顺序解码的 ${full[refIndex]}")
                    mismatch = true
                    break
                }
                i += 1
            }
            kernel.close()
            if (mismatch) {
                continue
            }
        }
    }
}
