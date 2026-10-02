package audio4cj.test

import audio4cj.meta.parseId3v1
import std.collection.ArrayList

/* ============================================================================
 * ID3v1 / ID3v1.1 解析测试 —— 开发文档 §10 M3
 *
 * 自包含：在内存中构造标签字节后直接调用解析函数，
 * 不依赖任何外部音频素材。
 *
 * 注意：本包（audio4cj.test）内所有测试文件共享顶层命名空间，
 * 因此辅助函数统一加 id3v1 前缀，避免与其他测试文件冲突。
 * ========================================================================== */
private func id3v1AppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

/// 追加定长字段：不足补 NUL，超出截断。
private func id3v1AppendField(out: ArrayList<UInt8>, s: String, len: Int64): Unit {
    let bytes = s.toArray()
    for (i in 0..len) {
        if (i < bytes.size) {
            out.add(bytes[i])
        } else {
            out.add(0u8)
        }
    }
}

/// 构造标准 ID3v1 尾部（128 字节）。
private func buildId3v1(
    title: String,
    artist: String,
    album: String,
    year: String,
    comment: String,
    genreIndex: Int64
): Array<UInt8> {
    let out = ArrayList<UInt8>()
    id3v1AppendAscii(out, "TAG")
    id3v1AppendField(out, title, 30)
    id3v1AppendField(out, artist, 30)
    id3v1AppendField(out, album, 30)
    id3v1AppendField(out, year, 4)
    id3v1AppendField(out, comment, 30)
    out.add(UInt8(genreIndex))
    out.toArray()
}

/// 构造 ID3v1.1 尾部：注释缩短为 28 字节，后跟 0x00 标记与音轨号。
private func buildId3v11(track: Int64): Array<UInt8> {
    let out = ArrayList<UInt8>()
    id3v1AppendAscii(out, "TAG")
    id3v1AppendField(out, "T", 30)
    id3v1AppendField(out, "A", 30)
    id3v1AppendField(out, "L", 30)
    id3v1AppendField(out, "2020", 4)
    id3v1AppendField(out, "note", 28)
    out.add(0u8)
    out.add(UInt8(track))
    out.add(0u8) // genre 索引 0 = Blues
    out.toArray()
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class Id3v1Test {
    /// 全部标准字段都能从固定偏移解出
    @TestCase
    func parsesBasicFields() {
        let tail = buildId3v1("Title A", "Artist B", "Album C", "2004", "a comment", 17)
        let tag = parseId3v1(tail)

        @Assert(tag.title.getOrThrow() == "Title A")
        @Assert(tag.artist.getOrThrow() == "Artist B")
        @Assert(tag.album.getOrThrow() == "Album C")
        @Assert(tag.year.getOrThrow() == "2004")
        @Assert(tag.comment.getOrThrow() == "a comment")
        @Assert(tag.genre.getOrThrow() == "Rock") // 流派表索引 17
        @Assert(tag.track.isNone()) // 标准 v1 无音轨号
    }

    /// ID3v1.1：注释第 28 字节为 0 时，第 29 字节是音轨号
    @TestCase
    func parsesId3v11TrackNumber() {
        let tag = parseId3v1(buildId3v11(7))

        @Assert(tag.track.getOrThrow() == 7)
        @Assert(tag.comment.getOrThrow() == "note")
        @Assert(tag.title.getOrThrow() == "T")
    }

    /// 无 "TAG" 标识 → 空 Tag（且不抛异常）
    @TestCase
    func missingTagMarkerReturnsEmptyTag() {
        let junk = Array<UInt8>(128, repeat: 0x41u8) // 全 'A'
        let tag = parseId3v1(junk)

        @Assert(tag.hasNoStandardFields())
        @Assert(tag.extra.size == 0)
    }

    /// 长度不足 128 字节 → 空 Tag，不越界访问
    @TestCase
    func shortInputReturnsEmptyTag() {
        let short: Array<UInt8> = [0x54u8, 0x41u8, 0x47u8] // "TAG"
        let tag = parseId3v1(short)

        @Assert(tag.hasNoStandardFields())
    }

    /// 部分写入器用空格填充，应被一并去除
    @TestCase
    func trimsTrailingSpacePadding() {
        let out = ArrayList<UInt8>()
        id3v1AppendAscii(out, "TAG")
        id3v1AppendAscii(out, "X")
        for (i in 0..29) {
            out.add(0x20u8) // 29 个空格
        }
        id3v1AppendField(out, "", 30) // artist
        id3v1AppendField(out, "", 30) // album
        id3v1AppendField(out, "", 4) // year
        id3v1AppendField(out, "", 30) // comment
        out.add(0u8) // genre

        let tag = parseId3v1(out.toArray())

        @Assert(tag.title.getOrThrow() == "X")
        @Assert(tag.artist.isNone()) // 空字段视为「不存在」
    }

    /// 流派索引超出表范围 → 保持 None，不抛异常
    @TestCase
    func outOfRangeGenreLeavesNone() {
        let tail = buildId3v1("T", "A", "L", "2000", "c", 200)
        let tag = parseId3v1(tail)

        @Assert(tag.genre.isNone())
        @Assert(tag.title.getOrThrow() == "T")
    }
}
