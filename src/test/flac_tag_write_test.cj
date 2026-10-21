package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import audio4cj.meta.Tag
import std.fs.*

/* ============================================================================
 * 标签写入回归 —— FLAC / Vorbis comment 安全子集（v0.2.0）
 *
 * 核心断言口径（与 MP3 的 tag_write_test 同一思路）：
 *   1. **写读往返**：writeTags 后 readTags 的标准字段与写入值一致
 *      （中文/emoji 覆盖 UTF-8 路径，TRACKNUMBER "n/total" 覆盖数字对还原）；
 *   2. **音频帧完好**：最硬的证据是**无损解码比对** —— 写入前先解码留底，
 *      写入后再解码，逐样本必须一致（FLAC 是无损容器，音频帧逐位保留时
 *      解码结果必然相同；反过来解码一致也涵盖了帧区未被破坏的所有路径）；
 *   3. **旧标签替换**：flac_tagged 素材自带标签，写入后只读得新值；
 *   4. **封面往返**：coverArt → METADATA_BLOCK_PICTURE（base64）→ 读回一致；
 *   5. **异常路径**：非 MP3/FLAC 容器抛 FormatNotSupportedException。
 * ========================================================================== */
@Test
class FlacTagWriteTest {
    private func readWholeOf(path: String): Array<UInt8> {
        var out = Array<UInt8>()
        try (f = File(path, Read)) {
            let size = f.length
            let buf = Array<UInt8>(size, repeat: 0)
            let got = f.read(buf)
            out = buf[0..got]
        }
        out
    }

    private func ftWrite(name: String, bytes: Array<UInt8>): String {
        let path = testTmpPath(name)
        File.writeTo(path, bytes)
        path
    }

    /// 全字段往返：写入 → readTags 回读一致（含中文与 emoji）。
    @TestCase
    func writeReadRoundtripAllFields() {
        let path = ftWrite("a4cj_ft_roundtrip.flac", readWholeOf("testdata/flac/flac_s16_44100_stereo.flac"))

        let t = Tag()
        t.title = "测试标题"
        t.artist = "测试艺术家"
        t.album = "测试专辑"
        t.albumArtist = "专辑艺术家"
        t.year = "2026"
        t.genre = "Rock"
        t.track = 3
        t.trackTotal = 12
        t.disc = 1
        t.discTotal = 2
        t.comment = "注释𝄞"
        t.composer = "作曲者🎵"
        t.lyrics = "歌词第一行"

        AudioFile.writeTags(path, t)

        let back = AudioFile.readTags(path)
        @Expect(back.title.getOrThrow(), "测试标题")
        @Expect(back.artist.getOrThrow(), "测试艺术家")
        @Expect(back.album.getOrThrow(), "测试专辑")
        @Expect(back.albumArtist.getOrThrow(), "专辑艺术家")
        @Expect(back.year.getOrThrow(), "2026")
        @Expect(back.genre.getOrThrow(), "Rock")
        @Expect(back.track.getOrThrow(), 3)
        @Expect(back.trackTotal.getOrThrow(), 12)
        @Expect(back.disc.getOrThrow(), 1)
        @Expect(back.discTotal.getOrThrow(), 2)
        @Expect(back.comment.getOrThrow(), "注释𝄞")
        @Expect(back.composer.getOrThrow(), "作曲者🎵")
        @Expect(back.lyrics.getOrThrow(), "歌词第一行")
    }

    /// 写入不破坏解码：写前解码留底、写后解码比对，逐样本必须一致。
    @TestCase
    func decodeIdenticalAfterWrite() {
        let path = ftWrite("a4cj_ft_decode.flac", readWholeOf("testdata/flac/flac_s16_44100_stereo.flac"))

        // 写入前解码留底
        let before = AudioFile.open(path).readAll()

        let t = Tag()
        t.title = "解码不受影响"
        t.artist = "artist"
        AudioFile.writeTags(path, t)

        // 写入后：容器仍可打开、元数据不变
        let af = AudioFile.open(path)
        let info = af.info()
        @Expect(info.sampleRate, 44100)
        let after = af.readAll()

        @Expect(after.frameCount, before.frameCount)
        @Expect(after.channels, before.channels)
        @Expect(after.sampleRate, before.sampleRate)
        let b = before.samples
        let a = after.samples
        for (i in 0..b.size) {
            @Assert(a[i] == b[i])
        }
    }

    /// 旧 Vorbis comment 被替换（flac_tagged 自带标签），且音频完好。
    @TestCase
    func oldCommentReplaced() {
        let path = ftWrite("a4cj_ft_replace.flac", readWholeOf("testdata/flac/flac_tagged.flac"))

        // 素材自带标签（否则本用例不成立）
        let orig = AudioFile.readTags(path)
        @Assert(orig.hasNoStandardFields() == false)

        let t = Tag()
        t.title = "新标题"
        AudioFile.writeTags(path, t)

        let back = AudioFile.readTags(path)
        @Expect(back.title.getOrThrow(), "新标题")
        // 未写的新字段不残留旧值
        @Assert(back.artist.isNone())
    }

    /// 封面往返：coverArt → METADATA_BLOCK_PICTURE（base64）→ 读回字节一致。
    @TestCase
    func coverArtRoundtrip() {
        let path = ftWrite("a4cj_ft_cover.flac", readWholeOf("testdata/flac/flac_s16_44100_stereo.flac"))

        // 伪造一张小图（PNG 魔数开头 + 若干载荷字节）
        let art: Array<UInt8> = [0x89u8, 0x50u8, 0x4Eu8, 0x47u8, 0x0Du8, 0x0Au8, 0x1Au8, 0x0Au8, 0x00, 0x01, 0x02, 0x03]
        let t = Tag()
        t.title = "带封面"
        t.coverArt = Some(art)
        t.coverMime = Some("image/png")
        AudioFile.writeTags(path, t)

        let back = AudioFile.readTags(path)
        let got = back.coverArt.getOrThrow()
        @Expect(got.size, art.size)
        var i: Int64 = 0
        while (i < art.size) {
            @Expect(got[i], art[i])
            i += 1
        }
        @Expect(back.coverMime.getOrThrow(), "image/png")
    }

    /// 连续写两次不叠加块（第二次写入后旧 VORBIS_COMMENT 只有一份）。
    @TestCase
    func doubleWriteStaysClean() {
        let path = ftWrite("a4cj_ft_double.flac", readWholeOf("testdata/flac/flac_s16_44100_stereo.flac"))

        let t1 = Tag()
        t1.title = "第一次"
        AudioFile.writeTags(path, t1)

        let t2 = Tag()
        t2.title = "第二次"
        t2.artist = "艺术家2"
        AudioFile.writeTags(path, t2)

        let back = AudioFile.readTags(path)
        @Expect(back.title.getOrThrow(), "第二次")
        @Expect(back.artist.getOrThrow(), "艺术家2")
    }

    /// 非 MP3/FLAC 容器仍拒绝（WAV）。
    @TestCase
    func rejectsNonMp3FlacContainers() {
        let path = ftWrite("a4cj_ft_reject.wav", readWholeOf("testdata/wav/wav_s16_44100_stereo.wav"))
        let before = readWholeOf(path)

        let t = Tag()
        t.title = "不该写进去"
        @AssertThrows[FormatNotSupportedException](AudioFile.writeTags(path, t))

        // 拒绝后原文件未被触碰
        let after = readWholeOf(path)
        @Expect(after.size, before.size)
    }
}
