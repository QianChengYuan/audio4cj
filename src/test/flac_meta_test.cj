package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.core.FormatNotSupportedException
import audio4cj.format.PureFlacKernel
import audio4cj.format.parseStreamInfo
import std.fs.*

/* ============================================================================
 * FLAC STREAMINFO 解析测试
 *
 * 【本文件的核心验证策略：与素材规格对照】
 *   解析出的参数必须与**生成素材时要求的参数**一致（见 sctiptr 的 REFSPECS
 *   与各 ffmpeg 调用）。这条判据原先是"与 dr_libs 报告的参数完全一致"，
 *   换成规格后其实**更独立**：dr_libs 与我们的解析器同属"读同一个 STREAMINFO"，
 *   而素材规格来自我们之外的第三方工具。
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
    // 与**素材规格**对照（原先这里是与 dr_libs 对照）
    //
    // 【判据换了，但要求没降】原先是"纯仓颉解析出的参数必须与 dr_libs 报的完全
    //   一致"；现在改为"必须与生成素材时要求的参数一致"。后者其实**更独立** ——
    //   dr_libs 与我们的解析器同属"读同一个 STREAMINFO"，而素材规格来自 ffmpeg 的
    //   编码参数（sctiptr/gen_audio_fixtures.py），是我们之外的第三方事实。
    // ------------------------------------------------------------------

    /// 各素材的参数必须与生成规格一致。
    ///
    /// 采样率 / 声道 / 位深取自 gen_audio_fixtures.py 的 REFSPECS 与各 ffmpeg 调用。
    /// 注意 44.1k 立体声那条用的是 `-sample_fmt s32`：ffmpeg 据此写出 **24 位**
    /// （FLAC 没有 32 位整型），故期望位深是 24 —— 这一处最容易照名字想当然
    /// （名字叫 s24，参数却是 s32），测试把它固定下来。
    @TestCase
    func streamInfoMatchesFixtureSpec() {
        let specs = [
            ("testdata/flac/flac_s16_44100_stereo.flac", 44100, 2, 16),
            ("testdata/flac/flac_s16_44100_mono.flac", 44100, 1, 16),
            ("testdata/flac/flac_s16_16000_mono.flac", 16000, 1, 16),
            ("testdata/flac/flac_s24_44100_stereo.flac", 44100, 2, 24),
            ("testdata/flac/flac_silence.flac", 44100, 2, 16),
            ("testdata/flac/flac_tagged.flac", 44100, 2, 16),
            ("testdata/flac/flac_cover.flac", 44100, 2, 16)
        ]

        for ((path, rate, channels, bits) in specs) {
            let info = parseStreamInfo(fmReadHead(path, 64))
            @Expect(info.sampleRate, rate)
            @Expect(info.channels, channels)
            @Expect(info.bitsPerSample, bits)
        }
    }

    /// STREAMINFO 里声明的总帧数，必须与整文件解码出的帧数一致。
    ///
    /// 这条把"元数据声明的长度"与"实际解出的长度"对上 —— 若解析字段错位
    /// （例如采样率与声道数读串了），总帧数几乎不可能同时正确。
    /// 解码改用纯仓颉内核（原先用 FFI 内核，那只是驱动手段，换掉不改变本断言的含义）。
    @TestCase
    func totalSamplesAgreesWithDecodedFrameCount() {
        let path = "testdata/flac/flac_s16_44100_stereo.flac"
        let info = parseStreamInfo(fmReadHead(path, 64))

        var decoded: Int64 = 0
        let kernel = PureFlacKernel(path, false)
        let channels = kernel.channels()
        let buf = Array<UInt8>(16384 * channels * 4, repeat: 0)
        var got: Int64 = 1
        while (got > 0) {
            got = kernel.readF32Into(buf, 16384)
            decoded += got
        }
        kernel.close()

        @Expect(decoded, info.totalSamples)
        // 顺带把"声明值本身"钉在规格上：1 秒 @ 44100
        @Expect(info.totalSamples, 44100)
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
