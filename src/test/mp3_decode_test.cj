package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.facade.AudioFile
import std.fs.*

/* ============================================================================
 * MP3 解码测试 —— MP3 回到解码范围（纯仓颉内核）
 *
 * 【与 FLAC 测试的关键差异：为什么不能自包含构造】
 *   FLAC 有 **verbatim 子帧**（未经压缩的原始样本可直接内联），因此
 *   flac_decode_test 能在内存里拼出合法且可解码的流。MP3 **没有**这种后门：
 *   它的帧数据是 Huffman 编码 + 频域变换的产物，手工构造"有意义的音频"
 *   等价于实现一个 MP3 编码器。因此本文件的**正向**用例依赖 testdata/ 里的
 *   MP3 素材（由 scripts/gen_testdata.* 用 ffmpeg 从合成信号编码而来，
 *   不含第三方版权内容），走 `gsSkipIfNoFixtures` 守卫（制品包内不含素材时跳过）。
 *
 *   **负向**用例可以自包含：构造"有同步字但没有合法帧"的字节即可，
 *   它压的是"帧同步 + 连续帧校验"与"不崩溃"这两条性质。
 *
 * 【正确性判据是包络，不是逐样本】
 *   有损解码器之间在量化细节与编码器延迟补偿上**合法地**存在差异，
 *   因此与 ffmpeg 的比对在 golden_test.cj 里以 envelope 模式进行
 *   （长度 + 整体能量），本文件只钉"信息面"与"行为面"：
 *   参数是否报对、定位是否落在合法落点、坏数据是否被拒绝。
 * ========================================================================== */
@Test
class Mp3DecodeTest {
    /// 打开报告：采样率 / 声道 / 位深（32 表示 float32）/ 总帧数 / 格式标识
    @TestCase
    func openReportsMp3Info() {
        if (gsSkipIfNoFixtures("openReportsMp3Info")) {
            return
        }

        try (f = AudioFile.open("testdata/mp3/mp3_cbr_128k.mp3")) {
            let info = f.info()
            @Expect(info.sampleRate, 44100)
            @Expect(info.channels, 2)
            // 有损格式无源位深，恒为 32（含义是"输出为 float32"，不是 32 位整数）
            @Expect(info.bitDepth, 32)
            // 由 Xing/Info 标签声明：40 个 MP3 帧 × 1152 样本 = 46080
            @Expect(info.totalFrames, 46080)

            let fmt = f.format()
            @Expect(fmt.container, "mp3")
            @Expect(fmt.codec, "")
            @Expect(fmt.codecId, "mp3")
            @Expect(fmt.mimeType, "audio/mpeg")

            // 真正解一段：帧数与声道数必须自洽
            let buf = f.readFrames(4096)
            @Assert(buf.samples.size > 0)
            @Expect(buf.frameCount, 4096)
            @Expect(buf.channels, 2)
        }
    }

    /// VBR（Xing）与 MPEG2（16 kHz 单声道，每帧 576 样本）都能打开
    @TestCase
    func vbrAndMpeg2Open() {
        if (gsSkipIfNoFixtures("vbrAndMpeg2Open")) {
            return
        }

        try (v = AudioFile.open("testdata/mp3/mp3_vbr_q4.mp3")) {
            @Expect(v.info().sampleRate, 44100)
            @Expect(v.info().channels, 2)
        }

        try (m = AudioFile.open("testdata/mp3/mp3_16000_mono.mp3")) {
            @Expect(m.info().sampleRate, 16000)
            @Expect(m.info().channels, 1)
            // MPEG2 每帧 576 样本；86 帧 × 576 = 49536
            @Expect(m.info().totalFrames, 49536)
        }
    }

    /// 定位返回**实际落点**，且落点必然是帧的整数倍（MP3 只能按帧定位）
    @TestCase
    func seekReturnsFrameAlignedPosition() {
        if (gsSkipIfNoFixtures("seekReturnsFrameAlignedPosition")) {
            return
        }

        try (f = AudioFile.open("testdata/mp3/mp3_cbr_128k.mp3")) {
            // 500ms 目标：MP3 只能按帧定位，落点必然是
            // 帧序号 × 1152 / 44100 秒 —— 即 522ms（20 帧）附近。
            // 取 ±30ms 的宽松窗口：既验"不跑偏"，又不去钉一个会随分块策略
            // 微调而漂移的精确毫秒值。
            let actual = f.seekTo(500)
            @Assert(actual >= 470 && actual <= 530)

            // 向前回退也必须成立（内部走"重开 + 复位解码器"路径）
            @Expect(f.seekTo(0), 0)
        }
    }

    /// 标签：readTags 与 metadata() 走同一实现，两者结果一致
    @TestCase
    func tagsAreReadable() {
        if (gsSkipIfNoFixtures("tagsAreReadable")) {
            return
        }

        let path = "testdata/mp3/mp3_id3v23.mp3"
        let viaReadTags = AudioFile.readTags(path)
        @Expect(viaReadTags.title.getOrThrow(), "MP3 Title")
        @Expect(viaReadTags.artist.getOrThrow(), "MP3 Artist")

        // metadata() 要求容器可解码 —— MP3 现在满足这一点
        try (f = AudioFile.open(path)) {
            let viaMetadata = f.metadata()
            @Expect(viaMetadata.title.getOrThrow(), "MP3 Title")
        }
    }

    /// 自包含负向：合法同步字 + 其后全是垃圾（无任何连续合法帧）必须被拒绝
    ///
    /// 这条**不依赖素材**，因此在制品包内也照常执行。它钉住的是：
    /// 单个 0xFF 0xFB 同步字不足为凭 —— 必须有连续帧校验，
    /// 否则一段垃圾会被"解出"成噪声音频，静默污染下游。
    @TestCase
    func garbageStreamIsRejected() {
        let out = Array<UInt8>(2100, repeat: 0)
        // "ID3" 标记 → 探测器判为 mp3（supported = true）
        out[0] = 0x49 // I
        out[1] = 0x44 // D
        out[2] = 0x33 // 3
        out[3] = 0x03 // 版本 2.3
        out[4] = 0x00
        out[5] = 0x00 // flags

        // synchsafe 长度 = 0（无标签体）
        out[6] = 0x00
        out[7] = 0x00
        out[8] = 0x00
        out[9] = 0x00
        // 一个合法帧头（MPEG1 Layer III / 128kbps / 44100 / 立体声）
        out[10] = 0xFF
        out[11] = 0xFB
        out[12] = 0x90
        out[13] = 0x00
        // 其后为递增字节，不含任何合法后续帧
        var i: Int64 = 14
        while (i < out.size) {
            out[i] = UInt8(i & 0xFF)
            i += 1
        }

        let path = testTmpPath("a4cj_mp3_garbage_stream.mp3")
        File.writeTo(path, out)
        try {
            // 打开阶段就必须拒绝（而不是给出一段"解出来的"垃圾音频）
            @AssertThrows[CorruptedFileException](AudioFile.open(path))
        } finally {
            remove(path)
        }
    }
}
