package audio4cj.test

import audio4cj.meta.parseVorbisComment
import std.collection.ArrayList

/* ============================================================================
 * Vorbis comment 解析测试 —— 开发文档 §10 M3
 *
 * 自包含：在内存中构造块字节后直接调用解析函数。
 * 该解析器同时服务于 FLAC 的 VORBIS_COMMENT 块（M4）与 OGG。
 * ========================================================================== */
private func vorbisAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

/// 构造 Vorbis comment 块：vendor + 条目数 + 各条目。
private func buildVorbisComment(vendor: String, entries: Array<String>): Array<UInt8> {
    let out = ArrayList<UInt8>()

    let vb = vendor.toArray()
    vorbisAppendUInt32LE(out, vb.size)
    for (b in vb) {
        out.add(b)
    }

    vorbisAppendUInt32LE(out, entries.size)
    for (e in entries) {
        let eb = e.toArray()
        vorbisAppendUInt32LE(out, eb.size)
        for (b in eb) {
            out.add(b)
        }
    }

    out.toArray()
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class VorbisCommentTest {
    /// 标准字段映射
    @TestCase
    func parsesStandardFields() {
        let block = buildVorbisComment(
            "ref",
            [
                "TITLE=Song",
                "ARTIST=Someone",
                "ALBUM=Record",
                "DATE=2011-05-06",
                "GENRE=Jazz",
                "COMPOSER=Composer X"
            ]
        )
        let tag = parseVorbisComment(block)

        @Assert(tag.title.getOrThrow() == "Song")
        @Assert(tag.artist.getOrThrow() == "Someone")
        @Assert(tag.album.getOrThrow() == "Record")
        @Assert(tag.year.getOrThrow() == "2011-05-06")
        @Assert(tag.genre.getOrThrow() == "Jazz")
        @Assert(tag.composer.getOrThrow() == "Composer X")
    }

    /// 字段名大小写不敏感（规范要求）
    @TestCase
    func keyMatchingIsCaseInsensitive() {
        let block = buildVorbisComment("ref", ["title=lowercase", "Artist=Mixed"])
        let tag = parseVorbisComment(block)

        @Assert(tag.title.getOrThrow() == "lowercase")
        @Assert(tag.artist.getOrThrow() == "Mixed")
    }

    /// 值中允许出现 '='（只按第一个 '=' 拆分）
    @TestCase
    func valueMayContainEquals() {
        let block = buildVorbisComment("ref", ["COMMENT=a=b=c"])
        let tag = parseVorbisComment(block)

        @Assert(tag.comment.getOrThrow() == "a=b=c")
    }

    /// 冷门字段进 extra，键为大写字段名
    @TestCase
    func unknownKeysGoToExtra() {
        let block = buildVorbisComment("ref", ["ENCODER=Lavf", "PERFORMER=Some Band"])
        let tag = parseVorbisComment(block)

        @Assert(tag.extra["ENCODER"] == "Lavf")
        @Assert(tag.getExtra("PERFORMER").getOrThrow() == "Some Band")
        @Assert(tag.title.isNone())
    }

    /// TRACKNUMBER 的 "n/m" 形式被拆分为 track 与 trackTotal
    @TestCase
    func trackNumberPairIsSplit() {
        let block = buildVorbisComment("ref", ["TRACKNUMBER=3/12"])
        let tag = parseVorbisComment(block)

        @Assert(tag.track.getOrThrow() == 3)
        @Assert(tag.trackTotal.getOrThrow() == 12)
    }

    /// 声明长度超出实际数据 → 安全退出，返回已解析部分或空 Tag
    @TestCase
    func truncatedDataDoesNotThrow() {
        let block = buildVorbisComment("ref", ["TITLE=Song"])
        // 只给前半段（截断 vendor 段中部）
        let truncated = block[0..6]

        let tag = parseVorbisComment(truncated)
        @Assert(tag.hasNoStandardFields())
    }

    /// 完全非法数据 → 空 Tag
    @TestCase
    func junkDataReturnsEmptyTag() {
        let junk = Array<UInt8>(64, repeat: 0xFFu8)
        let tag = parseVorbisComment(junk)

        @Assert(tag.hasNoStandardFields())
    }
}
