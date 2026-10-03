package audio4cj.test

import audio4cj.pcm.reinterpretF32Bytes
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
/// `oggWrapped` 决定纯仓颉侧用哪个字节源（原生裸文件 / Ogg 页体重建流）。
/// FFI 侧不需要它 —— dr_flac 自己会识别封装类型，这正是"独立裁判"的体现。
private func fbCompare(path: String, chunkFrames: Int64, oggWrapped: Bool): Unit {
    let ffiKernel = DrLibsFlacKernel(path)
    let ffi = fbDecodeAll(ffiKernel, chunkFrames)
    ffiKernel.close()

    let pureKernel = PureFlacKernel(path, oggWrapped)
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
            fbCompare(path, 4096, false)
        }
    }

    /// 块大小**不与帧边界对齐**时仍须逐样本一致 —— 这条专门压测 pending 路径。
    @TestCase
    func oddChunkSizeMatchesFfi() {
        fbCompare("testdata/flac/flac_s16_44100_stereo.flac", 1000, false)
        fbCompare("testdata/flac/flac_s24_44100_stereo.flac", 1000, false)
    }

    /// 极小块（小到一帧都装不下）仍须正确 —— 此时 pending 会跨多次调用累积。
    @TestCase
    func tinyChunkSizeMatchesFfi() {
        fbCompare("testdata/flac/flac_s16_44100_stereo.flac", 7, false)
    }

    /// 内核报出的参数必须与 STREAMINFO 一致（顺带验证流式元数据解析）。
    @TestCase
    func kernelReportsStreamInfoParameters() {
        let path = "testdata/flac/flac_s24_44100_stereo.flac"
        let kernel = PureFlacKernel(path, false)
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
        let reference = PureFlacKernel(path, false)
        let full = fbDecodeAll(reference, 4096)
        reference.close()

        let channels: Int64 = 2
        let targets = [0, 1, 1001, 4096, 4097, 20000, 40000]

        for (target in targets) {
            let kernel = PureFlacKernel(path, false)
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

    // ------------------------------------------------------------------
    // Ogg 封装的 FLAC（纯仓颉 Ogg 字节源）
    // ------------------------------------------------------------------

    /// Ogg 封装的 FLAC：**纯仓颉 Ogg 字节源** vs dr_libs（dr_flac 自带 Ogg 支持）。
    ///
    /// 【这条对照为什么特别有价值】
    ///   dr_flac 对 Ogg 封装的支持是一条**完全独立**的实现 —— 它自己解析 Ogg 页、
    ///   自己重组 packet；我们的 Ogg 源是纯仓颉新写的。两者输出逐位相同，
    ///   证明的是"拆容器这件事做对了"，而**不是**"两边共用同一份 Ogg 代码
    ///   所以当然一致"。这正是本库对自研实现的一贯要求：裁判必须独立。
    @TestCase
    func oggWrappedMatchesFfi() {
        let fixtures = ["testdata/ogg/ogg_flac.oga", "testdata/ogg/ogg_flac_tagged.oga"]
        for (path in fixtures) {
            fbCompare(path, 4096, true)
            fbCompare(path, 1000, true) // 非帧边界块大小，压 pending 通路
        }
    }

    /// Ogg 封装的 FLAC：seek 后的样本必须与"从头顺序解码到该位置"逐位相同。
    ///
    /// 【为什么 Ogg 侧的 seek 必须单独验】它与原生文件的 seek 是**不同的错误面**：
    ///   原生：按 SEEKTABLE 偏移移动文件指针即可；
    ///   Ogg ：要先在**重建流**的坐标系里跳到该偏移 —— 源必须逐页按段表算出
    ///         页体长度越过，并正确定位到"落在某页中间"的那个字节。
    /// 一个是移动指针，一个是要自己算出跨了几页、页内偏移多少，
    /// 不能靠原生用例通过来推断。
    ///
    /// 注意 Ogg-FLAC 的 STREAMINFO 常把总样本数写成 0（不可知），
    /// 故本用例只比对**实际解出的样本**，不依赖 totalFrames。
    @TestCase
    func oggWrappedSeekMatchesSequentialDecode() {
        let path = "testdata/ogg/ogg_flac.oga"
        let reference = PureFlacKernel(path, true)
        let full = fbDecodeAll(reference, 4096)
        reference.close()
        @Assert(full.size > 0)

        let channels: Int64 = 2
        let targets = [0, 1, 1001, 4096, 4097, 20000]

        for (target in targets) {
            let kernel = PureFlacKernel(path, true)
            if (!kernel.seekToFrame(target)) {
                @Fail("Ogg/FLAC seek 到 ${target} 返回 false")
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
                        "Ogg/FLAC seek 到 ${target} 后第 ${i} 个样本不符：${samples[i]} vs 顺序解码的 ${full[refIndex]}")
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

    /// Ogg 侧的参数必须与内嵌 STREAMINFO 一致，且与 dr_flac 读出的一致。
    ///
    /// 总样本数这一项刻意也比对：Ogg-FLAC 常写 0（不可知），本项目如实报告 -1；
    /// 两侧都应给出同一个"不可知"，而不是一边猜一个数。
    @TestCase
    func oggKernelReportsStreamInfoParameters() {
        let path = "testdata/ogg/ogg_flac.oga"
        let kernel = PureFlacKernel(path, true)
        let ffi = DrLibsFlacKernel(path)

        @Expect(kernel.sampleRate(), ffi.sampleRate())
        @Expect(kernel.channels(), ffi.channels())
        @Expect(kernel.bitsPerSample(), ffi.bitsPerSample())
        @Expect(kernel.totalFrames(), ffi.totalFrames())

        kernel.close()
        ffi.close()
    }
}
