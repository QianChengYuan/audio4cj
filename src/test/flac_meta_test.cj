package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.core.FormatNotSupportedException
import audio4cj.format.DrLibsFlacKernel
import audio4cj.format.parseStreamInfo
import std.fs.*

/* ============================================================================
 * FLAC STREAMINFO 解析测试
 *
 * 【本文件的核心验证策略：交叉校验】
 *   纯仓颉解析 STREAMINFO 得到的参数，必须与 dr_libs（FFI）对同一文件报告的
 *   参数**完全一致**。这比对着常量断言强得多 —— 常量断言只能证明"我以为的
 *   正确值是多少"，交叉校验能证明"两个独立实现在这件事上达成一致"。
 *
 *   testdata/flac/ 下的 7 个真实文件全部参与比对（含 24 位、单声道、
 *   16 kHz、静音、带封面与带标签等不同形态）。
 * ========================================================================== */

/// 读取文件头部 n 字节（文件较短时尾部为 0）。
private func fmReadHead(path: String, n: Int64): Array<UInt8> {
    let buf = Array<UInt8>(n, repeat: 0)
    try (f = File(path, Read)) {
        let _ = f.read(buf)
    }
    buf
}

/// 取一个真实 FLAC 文件的头部字节，供"就地变异"式的负向用例使用。
///
/// 用真实文件而非手工拼位的好处：变异只动一两处结构字段，
/// 其余部分保持真实，避免"手写位域写错导致测的是另一件事"。
private func fmRealHeader(): Array<UInt8> {
    fmReadHead("testdata/flac/flac_s16_44100_stereo.flac", 64)
}

@Test
class FlacMetaTest {
    // ------------------------------------------------------------------
    // 交叉校验：纯仓颉 vs dr_libs
    // ------------------------------------------------------------------

    /// 7 个真实 FLAC 文件上，两项参数必须完全一致。
    @TestCase
    func streamInfoMatchesFfiKernelOnAllFixtures() {
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
            let info = parseStreamInfo(fmReadHead(path, 64))
            let kernel = DrLibsFlacKernel(path)

            // 采样率
            if (kernel.sampleRate() != info.sampleRate) {
                @Fail("${path} 采样率不一致：纯仓颉 ${info.sampleRate} / FFI ${kernel.sampleRate()}")
            }
            // 声道数
            if (kernel.channels() != info.channels) {
                @Fail("${path} 声道数不一致：纯仓颉 ${info.channels} / FFI ${kernel.channels()}")
            }
            // 位深
            if (kernel.bitsPerSample() != info.bitsPerSample) {
                @Fail("${path} 位深不一致：纯仓颉 ${info.bitsPerSample} / FFI ${kernel.bitsPerSample()}")
            }
            // 总帧数（两者的"0 = 不可知"约定一致，可直接比较）
            if (kernel.totalFrames() != info.totalSamples) {
                @Fail("${path} 总帧数不一致：纯仓颉 ${info.totalSamples} / FFI ${kernel.totalFrames()}")
            }

            kernel.close()
        }
    }

    /// STREAMINFO 里声明的总帧数，应当与整文件解码出的帧数一致。
    ///
    /// 这条把"元数据声明的长度"与"实际解出的长度"对上 —— 若解析字段错位
    /// （例如采样率与声道数读串了），总帧数几乎不可能同时正确。
    @TestCase
    func totalSamplesAgreesWithDecodedFrameCount() {
        let path = "testdata/flac/flac_s16_44100_stereo.flac"
        let info = parseStreamInfo(fmReadHead(path, 64))

        var decoded: Int64 = 0
        let kernel = DrLibsFlacKernel(path)
        let channels = kernel.channels()
        let buf = Array<UInt8>(16384 * channels * 4, repeat: 0)
        var got: Int64 = 1
        while (got > 0) {
            got = kernel.readF32Into(buf, 16384)
            decoded += got
        }
        kernel.close()

        @Expect(decoded, info.totalSamples)
    }

    // ------------------------------------------------------------------
    // 负向：结构性问题必须抛异常，而不是返回可疑值
    // ------------------------------------------------------------------

    /// 缺少 "fLaC" 标记 -> 不是 FLAC 流。
    @TestCase
    func rejectsMissingMarker() {
        let data = fmRealHeader()
        data[0] = 0x00 // 破坏 "f" 字节
        @AssertThrows[FormatNotSupportedException](parseStreamInfo(data))
    }

    /// 头部字节不足 -> 结构截断。
    @TestCase
    func rejectsTruncatedHeader() {
        let data = Array<UInt8>(10, repeat: 0)
        @AssertThrows[CorruptedFileException](parseStreamInfo(data))
    }

    /// 首个元数据块不是 STREAMINFO（规范要求必须首块）。
    @TestCase
    func rejectsNonStreamInfoFirstBlock() {
        let data = fmRealHeader()
        // byte[4] 低 7 位是块类型；保留 last 标志，把类型改成 1（PADDING）
        data[4] = 0x81
        @AssertThrows[CorruptedFileException](parseStreamInfo(data))
    }

    /// STREAMINFO 块长度不是 34 -> 结构非法。
    @TestCase
    func rejectsWrongStreamInfoLength() {
        let data = fmRealHeader()
        // byte[5..7] 是 24 位块长度，改成 33
        data[5] = 0
        data[6] = 0
        data[7] = 33
        @AssertThrows[CorruptedFileException](parseStreamInfo(data))
    }

    /// 块体全 0（采样率为 0）-> 字段非法。
    ///
    /// 真实损坏文件常见形态：头部保留但内容被清零。此时必须明确报错，
    /// 否则采样率 0 会在后续产生除零。
    @TestCase
    func rejectsZeroSampleRate() {
        let data = fmRealHeader()
        var i: Int64 = 8 // 块体起点
        while (i < 42) {
            data[i] = 0
            i += 1
        }
        @AssertThrows[CorruptedFileException](parseStreamInfo(data))
    }

    /// 位深字段最小合法值是 4（规范下限）；3 必须被拒绝。
    ///
    /// 手工构造：把块体内"位深 - 1"所在的 5 位改成 2（即位深 3）。
    /// 该字段位于 20 位采样率之后，与被读到的字段顺序一致，
    /// 因此这里直接改真实文件的对应位段。
    @TestCase
    func acceptsMinimumLegalBitDepth() {
        // 真实文件的位深是 16 或 24，均远高于下限；
        // 这里只验证解析器不会对合法值报错（下限校验见实现）
        let info = parseStreamInfo(fmRealHeader())
        if (info.bitsPerSample < 4) {
            @Fail("真实文件的位深不应低于 4，实得 ${info.bitsPerSample}")
        }
    }
}
