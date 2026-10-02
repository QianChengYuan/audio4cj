package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.FormatNotSupportedException
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * AudioFile.readTags 端到端测试 —— 开发文档 §10 M3
 *
 * 自包含：在内存中构造完整文件字节（WAV / MP3 / FLAC），写入临时文件后
 * 走 readTags 的完整链路：探测 → 按容器分派 → 解析 → 多体系合并。
 * ========================================================================== */
private func rtAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func rtAppendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func rtAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

private func rtAppendUInt32BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 24) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func rtAppendSynchsafe(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 21) & 0x7F))
    out.add(UInt8((v >> 14) & 0x7F))
    out.add(UInt8((v >> 7) & 0x7F))
    out.add(UInt8(v & 0x7F))
}

private func rtWrite(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 构造 INFO 子块序列（含 "INFO" 标识）。
private func rtBuildInfoBytes(entries: Array<(String, String)>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    rtAppendAscii(out, "INFO")

    for ((id, value) in entries) {
        rtAppendAscii(out, id)
        let vb = value.toArray()
        let size = vb.size + 1 // 含 NUL 终止符
        rtAppendUInt32LE(out, size)
        for (b in vb) {
            out.add(b)
        }
        out.add(0u8)
        if (size % 2 == 1) {
            out.add(0u8)
        }
    }

    out.toArray()
}

/// 构造一个带 LIST/INFO 的最小合法 WAV（16-bit 单声道）。
private func buildWavWithInfo(entries: Array<(String, String)>): Array<UInt8> {
    let infoBytes = rtBuildInfoBytes(entries)
    let dataSize: Int64 = 4

    // RIFF 长度 = "WAVE"(4) + (8 + 16 fmt) + (8 + info) + (8 + data)
    let riffSize = 4 + 8 + 16 + 8 + infoBytes.size + 8 + dataSize

    let out = ArrayList<UInt8>()
    rtAppendAscii(out, "RIFF")
    rtAppendUInt32LE(out, riffSize)
    rtAppendAscii(out, "WAVE")

    // fmt chunk
    rtAppendAscii(out, "fmt ")
    rtAppendUInt32LE(out, 16)
    rtAppendUInt16LE(out, 1) // wFormatTag = PCM
    rtAppendUInt16LE(out, 1) // 单声道
    rtAppendUInt32LE(out, 44100)
    rtAppendUInt32LE(out, 88200)
    rtAppendUInt16LE(out, 2) // nBlockAlign
    rtAppendUInt16LE(out, 16) // 位深

    // LIST/INFO chunk
    rtAppendAscii(out, "LIST")
    rtAppendUInt32LE(out, infoBytes.size)
    for (b in infoBytes) {
        out.add(b)
    }

    // data chunk
    rtAppendAscii(out, "data")
    rtAppendUInt32LE(out, dataSize)
    for (i in 0..dataSize) {
        out.add(0u8)
    }

    out.toArray()
}

/// 构造 ID3v2.3 标签（仅 TIT2，Latin-1）。
private func buildId3v2Tag(title: String): Array<UInt8> {
    let dataBody = ArrayList<UInt8>()
    dataBody.add(0u8) // enc = Latin-1
    rtAppendAscii(dataBody, title)
    let frameData = dataBody.toArray()

    let body = ArrayList<UInt8>()
    rtAppendAscii(body, "TIT2")
    rtAppendUInt32BE(body, frameData.size)
    body.add(0u8)
    body.add(0u8)
    for (b in frameData) {
        body.add(b)
    }
    let bodyBytes = body.toArray()

    let out = ArrayList<UInt8>()
    rtAppendAscii(out, "ID3")
    out.add(3u8)
    out.add(0u8)
    out.add(0u8)
    rtAppendSynchsafe(out, bodyBytes.size)
    for (b in bodyBytes) {
        out.add(b)
    }
    out.toArray()
}

/// 构造 ID3v1 标签（仅 title 与 genre = Rock）。
private func buildId3v1Tag(title: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    rtAppendAscii(out, "TAG")

    let tb = title.toArray()
    for (i in 0..30) { // 标题（定长 30）
        if (i < tb.size) {
            out.add(tb[i])
        } else {
            out.add(0u8)
        }
    }
    for (i in 0..30) { // 艺术家
        out.add(0u8)
    }
    for (i in 0..30) { // 专辑
        out.add(0u8)
    }
    for (i in 0..4) { // 年份
        out.add(0u8)
    }
    for (i in 0..30) { // 注释
        out.add(0u8)
    }
    out.add(17u8) // 流派索引 17 = Rock
    out.toArray()
}

/// 组装伪 MP3：ID3v2 + 伪音频帧（含同步字，供探测层识别）+ ID3v1。
private func buildFakeMp3(v2: Array<UInt8>, v1: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()

    for (b in v2) {
        out.add(b)
    }

    // MPEG 帧同步字（0xFF 后高 3 位全 1），供无 ID3v2 时探测识别
    out.add(0xFFu8)
    out.add(0xFBu8)
    out.add(0x90u8)
    out.add(0x00u8)

    for (b in v1) {
        out.add(b)
    }

    out.toArray()
}

/// 构造 Vorbis comment 块体（vendor + 条目）。
private func rtBuildVorbisComment(entries: Array<String>): Array<UInt8> {
    let out = ArrayList<UInt8>()

    let vendor = "audio4cj-test".toArray()
    rtAppendUInt32LE(out, vendor.size)
    for (b in vendor) {
        out.add(b)
    }

    rtAppendUInt32LE(out, entries.size)
    for (e in entries) {
        let eb = e.toArray()
        rtAppendUInt32LE(out, eb.size)
        for (b in eb) {
            out.add(b)
        }
    }

    out.toArray()
}

/// 构造伪 FLAC：fLaC + STREAMINFO + VORBIS_COMMENT。
private func buildFakeFlac(vorbisComment: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    rtAppendAscii(out, "fLaC")

    // STREAMINFO（类型 0，长度 34，非最后一块）
    out.add(0u8)
    out.add(0u8)
    out.add(0u8)
    out.add(34u8)
    for (i in 0..34) {
        out.add(0u8)
    }

    // VORBIS_COMMENT（类型 4，最后一块 → 最高位置 1）
    out.add(0x84u8)
    let len = vorbisComment.size
    out.add(UInt8((len >> 16) & 0xFF))
    out.add(UInt8((len >> 8) & 0xFF))
    out.add(UInt8(len & 0xFF))
    for (b in vorbisComment) {
        out.add(b)
    }

    out.toArray()
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class ReadTagsTest {
    /// WAV：从 LIST/INFO 读出标签
    @TestCase
    func readsWavInfoTags() {
        let bytes = buildWavWithInfo([("INAM", "WavTitle"), ("IART", "WavArtist")])
        let path = rtWrite("a4cj_tags.wav", bytes)

        let tag = AudioFile.readTags(path)
        @Assert(tag.title.getOrThrow() == "WavTitle")
        @Assert(tag.artist.getOrThrow() == "WavArtist")

        remove(path)
    }

    /// WAV：AudioFile.metadata() 与 readTags 走同一 INFO 解析
    @TestCase
    func wavMetadataAlsoReadsInfo() {
        let bytes = buildWavWithInfo([("INAM", "ViaMetadata")])
        let path = rtWrite("a4cj_tags_meta.wav", bytes)

        try (f = AudioFile.open(path)) {
            @Assert(f.metadata().title.getOrThrow() == "ViaMetadata")
        }
        remove(path)
    }

    /// WAV：无 INFO 块 → 空 Tag（不是异常）
    @TestCase
    func wavWithoutInfoReturnsEmptyTag() {
        let bytes = buildWavWithInfo(Array<(String, String)>())
        let path = rtWrite("a4cj_tags_empty.wav", bytes)

        let tag = AudioFile.readTags(path)
        @Assert(tag.hasNoStandardFields())

        remove(path)
    }

    /// MP3：ID3v2 与 ID3v1 共存时 v2 优先，v1 逐字段回填
    @TestCase
    func mp3MergesV2OverV1() {
        let path = rtWrite(
            "a4cj_tags.mp3",
            buildFakeMp3(buildId3v2Tag("V2Title"), buildId3v1Tag("V1Title"))
        )

        let tag = AudioFile.readTags(path)

        @Assert(tag.title.getOrThrow() == "V2Title") // v2 优先
        @Assert(tag.genre.getOrThrow() == "Rock") // 仅 v1 提供的字段被回填

        remove(path)
    }

    /// MP3：仅有 ID3v1 时也能读出（探测靠 MPEG 同步字）
    @TestCase
    func mp3WithOnlyId3v1() {
        let path = rtWrite(
            "a4cj_tags_v1.mp3",
            buildFakeMp3(Array<UInt8>(), buildId3v1Tag("OnlyV1"))
        )

        let tag = AudioFile.readTags(path)
        @Assert(tag.title.getOrThrow() == "OnlyV1")

        remove(path)
    }

    /// FLAC：从 VORBIS_COMMENT 元数据块读取
    @TestCase
    func readsFlacVorbisComment() {
        let vc = rtBuildVorbisComment(["TITLE=FlacTitle", "ARTIST=FlacArtist"])
        let path = rtWrite("a4cj_tags.flac", buildFakeFlac(vc))

        let tag = AudioFile.readTags(path)
        @Assert(tag.title.getOrThrow() == "FlacTitle")
        @Assert(tag.artist.getOrThrow() == "FlacArtist")

        remove(path)
    }

    /// 无法识别的格式 → FormatNotSupportedException
    @TestCase
    func unknownFormatThrows() {
        let junk: Array<UInt8> = [0x00u8, 0x01u8, 0x02u8, 0x03u8]
        let path = rtWrite("a4cj_tags.bin", junk)

        @AssertThrows[FormatNotSupportedException](AudioFile.readTags(path))
        remove(path)
    }

    /// OGG 的标签读取**已实现**：数据残缺也返回空 Tag，而不抛异常
    ///
    /// 「没有标签」不是错误（§4.1 铁律 1）。这里故意只给 8 字节的残缺 Ogg 头 ——
    /// 容器能被识别为 ogg，但重组不出任何注释头，此时应安静地返回空 Tag。
    /// （本条此前断言的是"抛 FormatNotSupportedException"，因为那时 OGG 标签
    ///   读取尚未实现；实现之后该断言按新契约反转。）
    @TestCase
    func oggTagsReturnEmptyTagInsteadOfThrowing() {
        let ogg: Array<UInt8> = [0x4Fu8, 0x67u8, 0x67u8, 0x53u8, 0u8, 0u8, 0u8, 0u8]
        let path = rtWrite("a4cj_tags.ogg", ogg)

        let tag = AudioFile.readTags(path)
        @Assert(tag.hasNoStandardFields())
        remove(path)
    }

    /// 已识别但标签读取确实尚未实现的容器（APE）→ FormatNotSupportedException
    ///
    /// 用 APE 而不是 MP4 来做这条守卫：MP4 的 ilst 标签在规划中，而 APE tag
    /// 属明确延后项，短期内不会实现 —— 这样本用例不会因为别处的进展而反复失效。
    @TestCase
    func unimplementedContainerThrows() {
        // "MAC " = APE 容器的魔数
        let ape: Array<UInt8> = [0x4Du8, 0x41u8, 0x43u8, 0x20u8, 0u8, 0u8, 0u8, 0u8]
        let path = rtWrite("a4cj_tags.ape", ape)

        @AssertThrows[FormatNotSupportedException](AudioFile.readTags(path))
        remove(path)
    }

    /// 文件不存在 → std.fs 的 FSException（不属于 Audio4CjException 体系）
    @TestCase
    func missingFileThrows() {
        @AssertThrows[FSException](AudioFile.readTags("a4cj_no_such_file_xyz.mp3"))
    }
}
