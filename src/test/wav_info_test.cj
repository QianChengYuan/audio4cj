package audio4cj.test

import audio4cj.meta.parseWavInfo
import std.collection.ArrayList

/* ============================================================================
 * WAV LIST/INFO 解析测试 —— 开发文档 §10 M3（补 M2 遗留占位）
 *
 * 自包含：在内存中构造 INFO 子块序列后直接调用解析函数。
 * ========================================================================== */
private func wavInfoAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func wavInfoAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

/// 构造 INFO 子块序列。
///
/// 每个子块按 RIFF 规则写入：ID(4) + 长度(4 小端) + 数据 + NUL 终止符，
/// 长度为奇数时补 1 字节填充。
private func buildInfoBlock(entries: Array<(String, String)>, withPrefix: Bool): Array<UInt8> {
    let out = ArrayList<UInt8>()

    if (withPrefix) {
        wavInfoAppendAscii(out, "INFO")
    }

    for ((id, value) in entries) {
        wavInfoAppendAscii(out, id)

        let vb = value.toArray()
        let size = vb.size + 1 // 含 NUL 终止符
        wavInfoAppendUInt32LE(out, size)

        for (b in vb) {
            out.add(b)
        }
        out.add(0u8) // NUL 终止符

        if (size % 2 == 1) {
            out.add(0u8) // 奇数长度补 1 字节
        }
    }

    out.toArray()
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class WavInfoTest {
    /// 标准 INFO 字段映射
    @TestCase
    func parsesStandardFields() {
        let block = buildInfoBlock(
            [
                ("INAM", "Title"),
                ("IART", "Artist"),
                ("IPRD", "Album"),
                ("ICRD", "2018"),
                ("IGNR", "Blues"),
                ("ICMT", "note"),
                ("ITRK", "4")
            ],
            true
        )

        let tag = parseWavInfo(block)

        @Assert(tag.title.getOrThrow() == "Title")
        @Assert(tag.artist.getOrThrow() == "Artist")
        @Assert(tag.album.getOrThrow() == "Album")
        @Assert(tag.year.getOrThrow() == "2018")
        @Assert(tag.genre.getOrThrow() == "Blues")
        @Assert(tag.comment.getOrThrow() == "note")
        @Assert(tag.track.getOrThrow() == 4)
    }

    /// 奇数长度子块后有 1 字节填充，解析必须正确对齐到下一子块
    @TestCase
    func handlesOddSizePadding() {
        // "AB" → 数据含 NUL 共 3 字节（奇）→ 后跟 1 字节填充
        let block = buildInfoBlock([("INAM", "AB"), ("IART", "CD")], true)
        let tag = parseWavInfo(block)

        @Assert(tag.title.getOrThrow() == "AB")
        @Assert(tag.artist.getOrThrow() == "CD")
    }

    /// 未识别子块进 extra，键为 4 字符子块 ID
    @TestCase
    func unknownIdsGoToExtra() {
        let block = buildInfoBlock([("ISFT", "Lavf58"), ("IENG", "Bob")], true)
        let tag = parseWavInfo(block)

        @Assert(tag.getExtra("ISFT").getOrThrow() == "Lavf58")
        @Assert(tag.getExtra("IENG").getOrThrow() == "Bob")
    }

    /// 不带 "INFO" 标识的块体也能解析（容错）
    @TestCase
    func worksWithoutInfoPrefix() {
        let block = buildInfoBlock([("INAM", "NoPrefix")], false)
        let tag = parseWavInfo(block)

        @Assert(tag.title.getOrThrow() == "NoPrefix")
    }

    /// 长度字段越界 → 安全停止，不抛异常、不越界读取
    @TestCase
    func truncatedStopsSafely() {
        let block = buildInfoBlock([("INAM", "VeryLongValueHere")], true)
        let truncated = block[0..12] // 切在子块数据之前

        let tag = parseWavInfo(truncated)
        @Assert(tag.title.isNone())
    }

    /// 非法数据 → 空 Tag
    @TestCase
    func junkDataReturnsEmptyTag() {
        let junk = Array<UInt8>(64, repeat: 0xFFu8)
        let tag = parseWavInfo(junk)

        @Assert(tag.hasNoStandardFields())
    }
}
