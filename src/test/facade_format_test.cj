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
        ffCheck("testdata/wav/wav_s16_44100_stereo.wav", "wav", "", "wav")
        ffCheck("testdata/flac/flac_s16_44100_stereo.flac", "flac", "", "flac")
        // 这里曾有 ffCheck("testdata/mp3/mp3_cbr_128k.mp3", "mp3", ...)。
        // MP3 解码已移出本版本范围，它不再能走 open() —— 相关契约由本文件
        // 下方 mp3IsIdentifiableAndTagReadableButNotDecodable 单独钉住。

        // Ogg 族才有子编码 —— 容器与编码必须能分开读，
        // 这样"凡是 Ogg 走某分支"这类判断才不必去切字符串。
        ffCheck("testdata/ogg/ogg_flac.oga", "ogg", "flac", "ogg/flac")
        ffCheck("testdata/ogg/ogg_flac_tagged.oga", "ogg", "flac", "ogg/flac")
    }

    /// 轨道信息：当前所有受支持容器均为单轨。
    @TestCase
    func reportsTracks(): Unit {
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
        var message = ""
        try {
            AudioFile.open("testdata/ogg/ogg_vorbis_q4.ogg")
            @Fail("Ogg/Vorbis 尚无解码实现，应当抛异常")
        } catch (e: Exception) {
            message = e.message
        }
        @Expect(message.contains("vorbis"), true)
    }

    /// 【MP3 的契约：能识别、标签可读，但不能解码】
    ///
    /// 这条是本次取舍（MP3 解码移出范围）的**钉子**：以后若有人把探测层的
    /// supported 改回 true，或误删 readTags 的 mp3 分支，这里会立刻变红 ——
    /// "移出能力"这件事若只写在文档里，迟早会漂移。
    ///
    /// 它同时钉住一处**最容易做错**的地方：不可解码 ≠ 认不出来。
    /// 谁要是图省事把 mp3 从探测层整个删掉，本用例的前几条断言会失败。
    /// 与上一条用例的区别也正在这里：Vorbis 是"识别得出、但不支持"，
    /// MP3 是"识别得出、**标签还完全可用**"，两者不是一回事。
    @TestCase
    func mp3IsIdentifiableAndTagReadableButNotDecodable(): Unit {
        let path = "testdata/mp3/mp3_id3v23.mp3"

        // 1) 仍被识别为 mp3（而不是 unknown），且没有子编码
        let probe = detectFile(path)
        @Expect(probe.container, "mp3")
        @Expect(probe.codec, "")

        // 2) 但不再可解码
        @Expect(probe.supported, false)

        // 3) 公开路径上：open 必须抛"不支持"，且信息要能让人知道下一步怎么办
        var message = ""
        try {
            let f = AudioFile.open(path)
            f.close()
            @Fail("MP3 已移出解码范围，open 应当抛异常")
        } catch (e: FormatNotSupportedException) {
            message = e.toString()
        }
        @Expect(message.contains("mp3"), true)
        // 提示里必须点明"标签仍可读" —— 否则使用者会以为整个 MP3 都用不了
        @Expect(message.contains("readTags"), true)

        // 4) 标签读取完全不受影响。这部分是本条用例最实在的收获：
        //    它是**第一个**读真实 ffmpeg 产出 MP3 的标签用例
        //    （read_tags_test 用的是手工构造的字节，压边界；两者互补）。
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
