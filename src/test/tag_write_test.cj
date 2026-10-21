package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import audio4cj.meta.Tag
import std.collection.ArrayList
import std.fs.*

/* ============================================================================
 * 标签写入回归 —— MP3 / ID3v2.3 安全子集（v0.2.0）
 *
 * 核心断言口径：
 *   1. **写读往返**：writeTags 后 readTags 的标准字段与写入值一致
 *      （中文/emoji 覆盖 UTF-16 编码路径，数字对覆盖 TRCK/TPOS 合成）；
 *   2. **音频帧逐位不动**：写入前后，文件中「首个 MPEG 帧同步字起」的
 *      尾部字节必须完全一致；旧 ID3v2 被替换而非叠加（文件长度 = 新标签 + 原尾部）；
 *   3. **幂等替换**：连续写两次不产生双标签；
 *   4. **异常路径**：非 MP3 容器抛 FormatNotSupportedException；写失败不破坏原文件；
 *   5. **尾部标签保留**：文件原有的 ID3v1 / APEv2 不受写入影响。
 * ========================================================================== */

/// 取文件中「首个 MPEG 帧同步（0xFF Ex）」起的全部字节。
///
/// 写入器不改音频帧，故写入前后这一段必须逐位一致 —— 这是安全子集
/// 契约的核心断言。注意必须**先剥 ID3v2 标签再找帧同步**：标签体里的
/// UTF-16 BOM（0xFF 0xFE）恰好满足 0xFFEx 判据，从文件头盲扫会误判
/// （实测 TIT2 "第一次" 的 BOM 落在偏移 21）。
private func wtAudioBytes(path: String): Array<UInt8> {
    var out = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        // 剥掉头部 ID3v2（若有）
        var start: Int64 = 0
        if (got >= 10 && buf[0] == 0x49u8 && buf[1] == 0x44u8 && buf[2] == 0x33u8) {
            let body = ((Int64(buf[6]) & 0x7F) << 21) | ((Int64(buf[7]) & 0x7F) << 14) | ((Int64(buf[8]) & 0x7F) << 7) |
                (Int64(buf[9]) & 0x7F)
            start = body + 10
            if (start > got) {
                start = 0
            }
        }
        var sync: Int64 = -1
        var i = start
        while (i + 1 < got) {
            if (buf[i] == 0xFFu8 && (buf[i + 1] & 0xE0u8) == 0xE0u8) {
                sync = i
                break
            }
            i += 1
        }
        if (sync >= 0) {
            out = buf[sync..got]
        }
    }
    out
}

/// MP3 专用临时素材落点（与 review_fix_test 的 rfWrite 同一目录约定）。
private func wtWrite(name: String, bytes: Array<UInt8>): String {
    let path = testTmpPath(name)
    File.writeTo(path, bytes)
    path
}

@Test
class TagWriteTest {
    /// 往返：全部标准字段写入 → 回读一致（含中文与 emoji）。
    @TestCase
    func writeReadRoundtripAllFields() {
        let path = wtWrite("a4cj_tw_roundtrip.mp3", readWholeOf("testdata/mp3/mp3_cbr_128k.mp3"))

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
    }

    /// 音频帧逐位不动 + 旧 ID3v2 被替换（而非叠加）。
    @TestCase
    func audioBytesUntouchedAndOldTagReplaced() {
        let src = readWholeOf("testdata/mp3/mp3_cbr_128k.mp3")
        let path = wtWrite("a4cj_tw_replace.mp3", src)

        let t1 = Tag()
        t1.title = "第一次"
        AudioFile.writeTags(path, t1)

        let after1 = readWholeOf(path)
        let audio = wtAudioBytes(path)
        @Assert(audio.size > 0)
        // cbr_128k 自带 44 字节 ID3v2.4（剥掉）+ 无标签主体：写入后 = 新标签 + 原音频主体
        @Assert(after1.size == src.size - 44 + bigTagLen(after1))

        let t2 = Tag()
        t2.title = "第二次"
        t2.artist = "艺术家2"
        AudioFile.writeTags(path, t2)

        // 音频字节逐位一致
        let audio2 = wtAudioBytes(path)
        @Expect(audio2.size, audio.size)
        var i: Int64 = 0
        while (i < audio.size) {
            @Expect(audio2[i], audio[i])
            i += 1
        }
        // 第二次写入后回读只有第二次的值（旧标签被替换）
        let back = AudioFile.readTags(path)
        @Expect(back.title.getOrThrow(), "第二次")
        @Expect(back.artist.getOrThrow(), "艺术家2")
    }

    /// 尾部 ID3v1 在写入后依然保留可读。
    @TestCase
    func id3v1TailSurvivesWrite() {
        let path = wtWrite("a4cj_tw_v1tail.mp3", readWholeOf("testdata/mp3/mp3_id3v1.mp3"))

        let before = AudioFile.readTags(path)
        let beforeAlbum = before.album

        let t = Tag()
        t.title = "新标题"
        AudioFile.writeTags(path, t)

        let after = AudioFile.readTags(path)
        @Expect(after.title.getOrThrow(), "新标题")
        // ID3v1 的字段仍从尾部读到（合并语义：ID3v2 优先，但 v1 字段补空）
        @Assert(after.album.isSome() || beforeAlbum.isNone())
    }

    /// 非 MP3/FLAC 容器写入必须抛 FormatNotSupportedException，且原文件不被改动。
    ///
    /// v0.2.0 起 FLAC 已支持写入，这里的"非 MP3"素材改用 WAV（MP4/OGG 同理）。
    @TestCase
    func nonMp3RejectedWithoutMutation() {
        let path = wtWrite("a4cj_tw_reject.wav", readWholeOf("testdata/wav/wav_s16_44100_stereo.wav"))
        let before = readWholeOf(path)

        let t = Tag()
        t.title = "不该写入"
        @AssertThrows[FormatNotSupportedException](AudioFile.writeTags(path, t))

        let after = readWholeOf(path)
        @Expect(after.size, before.size)
        var i: Int64 = 0
        while (i < before.size) {
            @Expect(after[i], before[i])
            i += 1
        }
    }

    /// 封面往返：coverArt + coverMime 写入后读回逐位一致。
    @TestCase
    func coverArtRoundtrip() {
        let path = wtWrite("a4cj_tw_cover.mp3", readWholeOf("testdata/mp3/mp3_cbr_128k.mp3"))

        // 就地构造一张最小 PNG 头的假图（写入器不解析图片内容）
        let art: Array<UInt8> = [0x89u8, 0x50u8, 0x4Eu8, 0x47u8, 0x0Du8, 0x0Au8, 0x1Au8, 0x0Au8, 0x00u8, 0x00u8, 0x00u8,
            0x0Du8, 0x49u8, 0x48u8, 0x44u8, 0x52u8]
        let t = Tag()
        t.coverArt = art
        t.coverMime = "image/png"
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

    /// 写入空 Tag（全部字段 None）：不产生帧，文件仍可读出空 Tag。
    @TestCase
    func emptyTagWriteLeavesReadableFile() {
        let path = wtWrite("a4cj_tw_empty.mp3", readWholeOf("testdata/mp3/mp3_cbr_128k.mp3"))

        AudioFile.writeTags(path, Tag())

        // 文件本身仍可正常打开与解码
        try (f = AudioFile.open(path)) {
            @Assert(f.info().sampleRate > 0)
        }
        let back = AudioFile.readTags(path)
        @Assert(back.title.isNone())
        @Assert(back.artist.isNone())
    }

    /// 歌词（USLT）往返。
    @TestCase
    func lyricsRoundtrip() {
        let path = wtWrite("a4cj_tw_lyrics.mp3", readWholeOf("testdata/mp3/mp3_cbr_128k.mp3"))

        let t = Tag()
        t.lyrics = "第一行\n第二行歌词"
        AudioFile.writeTags(path, t)

        let back = AudioFile.readTags(path)
        @Expect(back.lyrics.getOrThrow(), "第一行\n第二行歌词")
    }

    // -----------------------------------------------------------------
    // 辅助
    // -----------------------------------------------------------------

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

    /// 从写后的文件字节里解析新 ID3v2 标签总长（无标签返回 0）。
    private func bigTagLen(fileBytes: Array<UInt8>): Int64 {
        if (fileBytes.size < 10 || fileBytes[0] != 0x49u8 || fileBytes[1] != 0x44u8 || fileBytes[2] != 0x33u8) {
            return 0
        }
        // synchsafe 32 位长度（注意括号：+10 必须在位或完成后整体相加）
        let body = ((Int64(fileBytes[6]) & 0x7F) << 21) | ((Int64(fileBytes[7]) & 0x7F) << 14) | ((Int64(fileBytes[8]) &
            0x7F) << 7) | (Int64(fileBytes[9]) & 0x7F)
        body + 10
    }
}
