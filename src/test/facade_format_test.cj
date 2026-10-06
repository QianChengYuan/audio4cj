package audio4cj.test

import audio4cj.core.FormatNotSupportedException
import audio4cj.facade.AudioFile
import audio4cj.probe.detectFile

/* ============================================================================
 * 门面的格式查询接口（format / tracks）
 *
 * 本组用例的价值**不在**"探测本身准不准"—— 那由 probe_matrix_test 覆盖。
 * 它的价值在**公开路径**上的契约：
 *   ① 探测结果确实能被使用者拿到（此前它只用于分支选实现，随后即被丢弃）；
 *   ② container 与 codec 分开可读，程序化判断才可靠；
 *   ③ 关闭文件后仍可读 —— 这是"open 时快照"这一设计要保证的事。
 * ========================================================================== */
@Test
class FacadeFormatTest {
    /// 各容器的 format() 取值。
    @TestCase
    func reportsContainerAndCodec(): Unit {
        if (gsSkipIfNoFixtures("reportsContainerAndCodec")) {
            return
        }

        ffCheck("testdata/wav/wav_s16_44100_stereo.wav", "wav", "", "wav")
        ffCheck("testdata/flac/flac_s16_44100_stereo.flac", "flac", "", "flac")
        ffCheck("testdata/mp3/mp3_cbr_128k.mp3", "mp3", "", "mp3")

        // Ogg 族才有子编码 —— 容器与编码必须能分开读，
        // 这样"凡是 Ogg 走某分支"这类判断才不必去切字符串。
        ffCheck("testdata/ogg/ogg_flac.oga", "ogg", "flac", "ogg/flac")
        ffCheck("testdata/ogg/ogg_flac_tagged.oga", "ogg", "flac", "ogg/flac")
    }

    /// 轨道信息：当前所有受支持容器均为单轨。
    @TestCase
    func reportsTracks(): Unit {
        if (gsSkipIfNoFixtures("reportsTracks")) {
            return
        }

        try (f = AudioFile.open("testdata/flac/flac_s16_44100_stereo.flac")) {
            let tracks = f.tracks()
            @Expect(tracks.size, 1)
            @Expect(tracks[0].index, 0)
            @Expect(tracks[0].codecId, "flac")
            @Expect(tracks[0].sampleRate, 44100)
            @Expect(tracks[0].channels, 2)
        }
    }

    /// 关键契约：`format()` / `tracks()` 是 open 时的**快照**，关闭后仍可读。
    ///
    /// 一旦哪天被改成"每次向 reader 现查"，这条用例会立刻变红 —— 那正是它存在的意义。
    @TestCase
    func formatSurvivesClose(): Unit {
        if (gsSkipIfNoFixtures("formatSurvivesClose")) {
            return
        }

        let f = AudioFile.open("testdata/flac/flac_tagged.flac")
        let before = f.format().codecId

        f.close()
        @Expect(f.isClosed(), true)

        @Expect(f.format().codecId, before)
        @Expect(f.format().container, "flac")
        @Expect(f.tracks().size, 1)
    }

    /// 与上一条对照：**数据方法**在关闭后必须失效。
    /// 说明"关闭后仍可读"是有边界的 —— 仅限格式这类已固化的元信息。
    @TestCase
    func dataMethodsFailAfterClose(): Unit {
        if (gsSkipIfNoFixtures("dataMethodsFailAfterClose")) {
            return
        }

        let f = AudioFile.open("testdata/wav/wav_s16_44100_stereo.wav")
        f.close()

        var message = ""
        try {
            f.info()
            @Fail("关闭后调用 info() 应当抛出异常")
        } catch (e: Exception) {
            message = e.message
        }
        @Expect(message.contains("关闭"), true)
    }

    /// 不受支持的容器：**识别得出**，但拿不到 FormatInfo ——
    /// 此时异常信息里会写明编码级标识（这正是探测能力在失败路径上的体现）。
    @TestCase
    func unsupportedFormatStillThrowsWithCodec(): Unit {
        if (gsSkipIfNoFixtures("unsupportedFormatStillThrowsWithCodec")) {
            return
        }

        var message = ""
        try {
            AudioFile.open("testdata/ogg/ogg_vorbis_q4.ogg")
            @Fail("Ogg/Vorbis 尚无解码实现，应当抛异常")
        } catch (e: Exception) {
            message = e.message
        }
        @Expect(message.contains("vorbis"), true)
    }

    /// 【MP3 的契约：能识别、**可解码**、标签也可读】
    ///
    /// 这条钉住 MP3 **回到解码范围**这件事：它有纯仓颉解码内核（format/mp3_decode.cj），
    /// probe 的 supported 为 true，`open()` 能真正解出 PCM。若有人把 supported 改回 false、
    /// 或误删 readTags 的 mp3 分支，这里会立刻变红 —— 能力变化若只写在文档里，迟早漂移。
    ///
    /// 它同时钉住一处**最容易做错**的地方：不可解码 ≠ 认不出来（对照上一条 Vorbis 用例：
    /// Vorbis 是"识别得出、但不支持"，MP3 则是三者齐备）。
    @TestCase
    func mp3IsIdentifiableDecodableAndTagReadable(): Unit {
        if (gsSkipIfNoFixtures("mp3IsIdentifiableDecodableAndTagReadable")) {
            return
        }

        let path = "testdata/mp3/mp3_id3v23.mp3"

        // 1) 被识别为 mp3（而不是 unknown），且没有子编码
        let probe = detectFile(path)
        @Expect(probe.container, "mp3")
        @Expect(probe.codec, "")

        // 2) 可解码
        @Expect(probe.supported, true)

        // 3) 公开路径上：open 成功，且能解出非空 PCM
        try (f = AudioFile.open(path)) {
            let info = f.info()
            @Expect(info.sampleRate, 44100)
            @Expect(info.channels, 2)
            // 有损格式无源位深，32 表示"输出为 float32"
            @Expect(info.bitDepth, 32)
            @Assert(info.totalFrames > 0)

            let buf = f.readAll()
            @Assert(buf.samples.size > 0)
            @Assert(buf.frameCount > 0)
        }

        // 4) 标签读取不受影响（ID3v2 优先，字段完整）
        let tag = AudioFile.readTags(path)
        @Expect(tag.hasNoStandardFields(), false)
        @Expect(tag.title.getOrThrow(), "MP3 Title")
        @Expect(tag.artist.getOrThrow(), "MP3 Artist")
    }
}

/// 打开素材并核对 format() 的三个关键字段；mimeType 只断言非空
/// （它的具体取值属探测表细节，由 probe_matrix_test 负责）。
private func ffCheck(path: String, container: String, codec: String, codecId: String): Unit {
    try (f = AudioFile.open(path)) {
        let info = f.format()
        @Expect(info.container, container)
        @Expect(info.codec, codec)
        @Expect(info.codecId, codecId)
        @Expect(info.mimeType.size > 0, true)
    }
}
