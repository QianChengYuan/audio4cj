package audio4cj.test

import audio4cj.meta.parseId3v2
import audio4cj.meta.id3v2TotalSize
import std.collection.ArrayList

/* ============================================================================
 * ID3v2.2 / 2.3 / 2.4 解析测试 —— 开发文档 §10 M3
 *
 * 自包含：在内存中按规范构造标签与帧字节，直接调用解析函数。
 * 覆盖三个版本的帧格式差异、四种文本编码、封面、注释与非同步化。
 * ========================================================================== */
private func id3v2AppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func id3v2AppendUInt32BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 24) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func id3v2AppendUInt24BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

/// synchsafe 编码：每字节仅低 7 位有效，大端。
private func id3v2AppendSynchsafe(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 21) & 0x7F))
    out.add(UInt8((v >> 14) & 0x7F))
    out.add(UInt8((v >> 7) & 0x7F))
    out.add(UInt8(v & 0x7F))
}

/// 文本帧体：编码标识字节 + 文本。
private func id3v2TextBody(enc: UInt8, text: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(enc)
    for (b in text.toArray()) {
        out.add(b)
    }
    out.toArray()
}

/// v2.3 帧：ID(4) + 长度(4 大端) + 标志(2) + 数据。
private func id3v2Frame23(id: String, data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    id3v2AppendAscii(out, id)
    id3v2AppendUInt32BE(out, data.size)
    out.add(0u8)
    out.add(0u8)
    for (b in data) {
        out.add(b)
    }
    out.toArray()
}

/// v2.4 帧：长度字段改用 synchsafe。
private func id3v2Frame24(id: String, data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    id3v2AppendAscii(out, id)
    id3v2AppendSynchsafe(out, data.size)
    out.add(0u8)
    out.add(0u8)
    for (b in data) {
        out.add(b)
    }
    out.toArray()
}

/// v2.2 帧：ID(3) + 长度(3 大端) + 数据（无标志字段）。
private func id3v2Frame22(id: String, data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    id3v2AppendAscii(out, id)
    id3v2AppendUInt24BE(out, data.size)
    for (b in data) {
        out.add(b)
    }
    out.toArray()
}

/// 组装完整标签：10 字节标签头 + 若干帧。
private func id3v2Build(major: Int64, flags: Int64, frames: Array<Array<UInt8>>): Array<UInt8> {
    let body = ArrayList<UInt8>()
    for (f in frames) {
        for (b in f) {
            body.add(b)
        }
    }
    id3v2BuildRaw(major, flags, body.toArray())
}

/// 用给定的原始 body 组装标签（用于非同步化等特殊构造）。
private func id3v2BuildRaw(major: Int64, flags: Int64, body: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    id3v2AppendAscii(out, "ID3")
    out.add(UInt8(major))
    out.add(0u8)
    out.add(UInt8(flags))
    id3v2AppendSynchsafe(out, body.size)
    for (b in body) {
        out.add(b)
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class Id3v2Test {
    /// v2.3：4 字符帧 ID + 普通大端长度字段
    @TestCase
    func parsesV23StandardFrames() {
        let tag = parseId3v2(
            id3v2Build(
                3,
                0,
                [
                    id3v2Frame23("TIT2", id3v2TextBody(0, "Song")),
                    id3v2Frame23("TPE1", id3v2TextBody(0, "Artist")),
                    id3v2Frame23("TALB", id3v2TextBody(0, "Album")),
                    id3v2Frame23("TYER", id3v2TextBody(0, "1999")),
                    id3v2Frame23("TRCK", id3v2TextBody(0, "5/10"))
                ]
            )
        )

        @Assert(tag.title.getOrThrow() == "Song")
        @Assert(tag.artist.getOrThrow() == "Artist")
        @Assert(tag.album.getOrThrow() == "Album")
        @Assert(tag.year.getOrThrow() == "1999")
        @Assert(tag.track.getOrThrow() == 5)
        @Assert(tag.trackTotal.getOrThrow() == 10)
    }

    /// v2.4：帧长度字段是 synchsafe（与 v2.3 的普通整数不同）
    @TestCase
    func parsesV24SynchsafeFrameSize() {
        let tag = parseId3v2(
            id3v2Build(
                4,
                0,
                [
                    id3v2Frame24("TIT2", id3v2TextBody(3, "Utf8Title")),
                    id3v2Frame24("TDRC", id3v2TextBody(3, "2020-01-02"))
                ]
            )
        )

        @Assert(tag.title.getOrThrow() == "Utf8Title")
        @Assert(tag.year.getOrThrow() == "2020-01-02")
    }

    /// v2.2：3 字符帧 ID 需映射为规范 ID
    @TestCase
    func parsesV22ThreeCharFrameIds() {
        let tag = parseId3v2(
            id3v2Build(
                2,
                0,
                [
                    id3v2Frame22("TT2", id3v2TextBody(0, "OldTitle")),
                    id3v2Frame22("TP1", id3v2TextBody(0, "OldArtist")),
                    id3v2Frame22("TRK", id3v2TextBody(0, "2"))
                ]
            )
        )

        @Assert(tag.title.getOrThrow() == "OldTitle")
        @Assert(tag.artist.getOrThrow() == "OldArtist")
        @Assert(tag.track.getOrThrow() == 2)
    }

    /// 编码 1：UTF-16 带 BOM（FF FE 表示小端）
    @TestCase
    func parsesUtf16WithBom() {
        let body: Array<UInt8> = [1u8, 0xFFu8, 0xFEu8, 0x48u8, 0x00u8, 0x69u8, 0x00u8]
        let tag = parseId3v2(id3v2Build(3, 0, [id3v2Frame23("TIT2", body)]))

        @Assert(tag.title.getOrThrow() == "Hi")
    }

    /// 编码 2：UTF-16BE 无 BOM
    @TestCase
    func parsesUtf16BeWithoutBom() {
        let body: Array<UInt8> = [2u8, 0x00u8, 0x48u8, 0x00u8, 0x69u8]
        let tag = parseId3v2(id3v2Build(3, 0, [id3v2Frame23("TIT2", body)]))

        @Assert(tag.title.getOrThrow() == "Hi")
    }

    /// 编码 3：UTF-8（非 ASCII）
    @TestCase
    func parsesUtf8WithNonAscii() {
        let tag = parseId3v2(id3v2Build(4, 0, [id3v2Frame24("TIT2", id3v2TextBody(3, "中文标题"))]))

        @Assert(tag.title.getOrThrow() == "中文标题")
    }

    /// COMM：编码 + 语言(3) + 描述(NUL 终止) + 正文
    @TestCase
    func parsesCommentFrame() {
        let out = ArrayList<UInt8>()
        out.add(0u8) // enc = Latin-1
        id3v2AppendAscii(out, "eng") // 语言
        out.add(0u8) // 空描述的终止符
        id3v2AppendAscii(out, "hello")

        let tag = parseId3v2(id3v2Build(3, 0, [id3v2Frame23("COMM", out.toArray())]))
        @Assert(tag.comment.getOrThrow() == "hello")
    }

    /// APIC：编码 + MIME(NUL 终止) + 图片类型(1) + 描述(NUL 终止) + 图片数据
    @TestCase
    func parsesPictureFrame() {
        let out = ArrayList<UInt8>()
        out.add(0u8) // enc = Latin-1
        id3v2AppendAscii(out, "image/jpeg")
        out.add(0u8) // MIME 终止符
        out.add(3u8) // 图片类型：封面
        out.add(0u8) // 空描述的终止符
        out.add(0xFFu8) // 伪 JPEG 数据
        out.add(0xD8u8)
        out.add(0xFFu8)

        let tag = parseId3v2(id3v2Build(3, 0, [id3v2Frame23("APIC", out.toArray())]))

        @Assert(tag.coverMime.getOrThrow() == "image/jpeg")
        @Assert(tag.coverArt.getOrThrow().size == 3)
    }

    /// TXXX 进 extra，键为 "TXXX:<描述>"
    @TestCase
    func txxxGoesToExtraWithKey() {
        let out = ArrayList<UInt8>()
        out.add(0u8)
        id3v2AppendAscii(out, "MOOD")
        out.add(0u8)
        id3v2AppendAscii(out, "calm")

        let tag = parseId3v2(id3v2Build(3, 0, [id3v2Frame23("TXXX", out.toArray())]))
        @Assert(tag.getExtra("TXXX:MOOD").getOrThrow() == "calm")
    }

    /// 未映射的文本帧进 extra，键为帧 ID
    @TestCase
    func unmappedTextFramesGoToExtra() {
        let tag = parseId3v2(id3v2Build(3, 0, [id3v2Frame23("TPUB", id3v2TextBody(0, "Label X"))]))

        @Assert(tag.getExtra("TPUB").getOrThrow() == "Label X")
    }

    /// 标签级非同步化：0xFF 00 应还原为 0xFF
    @TestCase
    func deUnsynchronisesV23Tag() {
        // 帧数据为 [enc=0, 0xFF]（Latin-1 的 'ÿ'）；
        // 写入器在 0xFF 后插入 0x00，故磁盘上为 [0x00, 0xFF, 0x00]，
        // 而帧长度字段仍记录还原后的长度 2。
        let out = ArrayList<UInt8>()
        id3v2AppendAscii(out, "TIT2")
        id3v2AppendUInt32BE(out, 2)
        out.add(0u8)
        out.add(0u8)
        out.add(0u8) // enc = Latin-1
        out.add(0xFFu8)
        out.add(0x00u8) // 被插入的同步字节

        let tag = parseId3v2(id3v2BuildRaw(3, 0x80, out.toArray()))
        @Assert(tag.title.getOrThrow() == "ÿ")
    }

    /// 头部非法 → 空 Tag（不抛异常）
    @TestCase
    func invalidHeaderReturnsEmptyTag() {
        let junk: Array<UInt8> = [0x00u8, 0x01u8, 0x02u8, 0x03u8]
        @Assert(parseId3v2(junk).hasNoStandardFields())

        // "ID3" 前缀但版本号非法（5）
        let out = ArrayList<UInt8>()
        id3v2AppendAscii(out, "ID3")
        out.add(5u8)
        out.add(0u8)
        out.add(0u8)
        id3v2AppendSynchsafe(out, 0)
        @Assert(parseId3v2(out.toArray()).hasNoStandardFields())
    }

    /// id3v2TotalSize 与标签实际字节数一致
    @TestCase
    func totalSizeMatchesActualLength() {
        let tagBytes = id3v2Build(3, 0, [id3v2Frame23("TIT2", id3v2TextBody(0, "X"))])
        @Assert(id3v2TotalSize(tagBytes).getOrThrow() == tagBytes.size)
    }
}
