package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.FormatNotSupportedException
import audio4cj.meta.parseOggTags
import audio4cj.meta.safeSlice
import std.collection.ArrayList

/* ============================================================================
 * OGG 标签读取测试 —— 覆盖 src/meta/ogg_page.cj 的页重组
 *
 * 【为什么需要自包含构造 Ogg 页，而不只用真实素材】
 *   真实素材能验证"链路通"，但**验证不了边界**：真实文件的注释头几乎总是
 *   恰好落在单个页面里，跨页续传、多逻辑流混排、段表撒谎这些情形根本不会出现。
 *   而它们恰恰是 Ogg 解析最容易写错的地方 —— 本项目的既有教训是：
 *   只测真实素材的解析器，一遇到畸形输入就暴露。
 *   因此这里用仓颉手工构造页面，把每种边界都钉死。
 *
 * 【页面布局速查】（详见 ogg_page.cj 文件头）
 *   0..3 "OggS" | 4 版本 | 5 页头类型 | 6..13 granule | 14..17 serial
 *   18..21 页序号 | 22..25 CRC | 26 段数 | 27.. 段表 | 之后页体
 *   页体长度 = 段表各值之和；段表值 255 表示 packet 未结束（可跨页续传）。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// Ogg 页构造辅助
// ---------------------------------------------------------------------------

/// 追加 4 字节小端整数。
private func ogAppendU32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

/// 构造一个 Ogg 页：页头 + 段表 + 页体。
///
/// - `lacing` 为段表各值。**调用方须保证其和等于 body.size**、且每个值 ≤ 255
///   —— 这里不做校验，因为测试要能构造畸形数据。
/// - CRC 字段留 0：本实现不校验 CRC（标签读取不需要，且校验 CRC 是解码侧的事）。
private func ogPage(
    serial: Int64,
    seq: Int64,
    headerType: UInt8,
    lacing: Array<Int64>,
    body: Array<UInt8>
): Array<UInt8> {
    let out = ArrayList<UInt8>()

    for (b in "OggS".toArray()) {
        out.add(b)
    }
    out.add(0u8) // 结构版本
    out.add(headerType) // 页头类型：0x01 续传 / 0x02 BOS / 0x04 EOS
    for (i in 0..8) {
        out.add(0u8) // granule position
    }
    ogAppendU32LE(out, serial)
    ogAppendU32LE(out, seq)
    for (i in 0..4) {
        out.add(0u8) // CRC（不校验）
    }
    out.add(UInt8(lacing.size)) // 第 26 字节：段数
    for (v in lacing) {
        out.add(UInt8(v)) // 段表
    }
    for (b in body) {
        out.add(b) // 页体
    }

    out.toArray()
}

/// 构造一段 Vorbis comment 数据（**不含**任何子编码 magic）。
private func ogVorbisComment(vendor: String, entries: Array<String>): Array<UInt8> {
    let out = ArrayList<UInt8>()

    let vb = vendor.toArray()
    ogAppendU32LE(out, vb.size)
    for (b in vb) {
        out.add(b)
    }

    ogAppendU32LE(out, entries.size)
    for (e in entries) {
        let eb = e.toArray()
        ogAppendU32LE(out, eb.size)
        for (b in eb) {
            out.add(b)
        }
    }

    out.toArray()
}

/// Vorbis 的识别头（30 字节）：0x01 + "vorbis" + 23 字节内容。
/// 内容本身不参与标签判定，但长度要与真实识别头一致，避免掩盖长度相关的错误。
private func ogVorbisIdent(): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(0x01u8)
    for (b in "vorbis".toArray()) {
        out.add(b)
    }
    for (i in 0..23) {
        out.add(0u8)
    }
    out.toArray()
}

/// Opus 的识别头（19 字节）："OpusHead" + 11 字节内容。
private func ogOpusIdent(): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in "OpusHead".toArray()) {
        out.add(b)
    }
    for (i in 0..11) {
        out.add(0u8)
    }
    out.toArray()
}

/// Vorbis 的注释头 packet：0x03 + "vorbis" + comment 数据。
private func ogVorbisCommentPacket(comment: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(0x03u8)
    for (b in "vorbis".toArray()) {
        out.add(b)
    }
    for (b in comment) {
        out.add(b)
    }
    out.toArray()
}

/// Opus 的注释头 packet："OpusTags" + comment 数据（结构与 Vorbis 同构）。
private func ogOpusTagsPacket(comment: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in "OpusTags".toArray()) {
        out.add(b)
    }
    for (b in comment) {
        out.add(b)
    }
    out.toArray()
}

/// 构造一条逻辑流：[识别头页(BOS), 注释头页]。
///
/// `splitComment` 为 true 时把注释头 packet 拆到两页里（第二页带 0x01 续传标志），
/// 用于验证跨页续传 —— 此时 packet 长度必须 > 255。
private func ogTwoPageStream(
    serial: Int64,
    ident: Array<UInt8>,
    commentPacket: Array<UInt8>,
    splitComment: Bool
): Array<UInt8> {
    let out = ArrayList<UInt8>()

    for (b in ogPage(serial, 0, 0x02u8, [ident.size], ident)) {
        out.add(b)
    }

    if (!splitComment) {
        for (b in ogPage(serial, 1, 0x00u8, [commentPacket.size], commentPacket)) {
            out.add(b)
        }
        return out.toArray()
    }

    // 跨页：第一页只放前 255 字节（段表值为 255 ⇒ packet 未结束）
    let head = safeSlice(commentPacket, 0, 255)
    for (b in ogPage(serial, 1, 0x00u8, [255], head)) {
        out.add(b)
    }
    // 第二页放剩余部分，并带续传标志
    let tail = safeSlice(commentPacket, 255, commentPacket.size - 255)
    for (b in ogPage(serial, 2, 0x01u8, [tail.size], tail)) {
        out.add(b)
    }

    out.toArray()
}

/// 一段足够长的 vendor 字符串，用于把注释头 packet 撑过 255 字节以便跨页。
private func ogLongVendor(): String {
    let out = ArrayList<UInt8>()
    for (i in 0..300) {
        out.add(0x41u8) // 'A'
    }
    String.fromUtf8(out.toArray())
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class OggTagsTest {
    /// 单页内的 Vorbis 注释头
    @TestCase
    func vorbisCommentInSinglePage() {
        let comment = ogVorbisComment(
            "vendor",
            ["TITLE=标题甲", "ARTIST=艺术家甲", "ALBUM=专辑甲", "TRACKNUMBER=3/12"]
        )
        let data = ogTwoPageStream(1, ogVorbisIdent(), ogVorbisCommentPacket(comment), false)

        let tag = parseOggTags(data)
        @Assert(tag.title.getOrThrow() == "标题甲")
        @Assert(tag.artist.getOrThrow() == "艺术家甲")
        @Assert(tag.album.getOrThrow() == "专辑甲")
        // 音轨号要拆成当前值与总数
        @Assert(tag.track.getOrThrow() == 3)
        @Assert(tag.trackTotal.getOrThrow() == 12)
    }

    /// **跨页续传**：注释头被拆到两页，第二页带 0x01 续传标志
    ///
    /// 这是本模块最容易写错的地方。若忽略续传（只看单页），注释头会被静默
    /// 截断 —— 表现为"标签只读到一半"，而且小标签的文件完全测不出来。
    @TestCase
    func vorbisCommentAcrossPages() {
        let comment = ogVorbisComment(
            ogLongVendor(),
            ["TITLE=跨页标题", "ARTIST=跨页艺术家"]
        )
        let packet = ogVorbisCommentPacket(comment)

        // 前提：这个 packet 确实超过一页能容纳的 255 字节
        @Assert(packet.size > 255)

        let data = ogTwoPageStream(1, ogVorbisIdent(), packet, true)

        let tag = parseOggTags(data)
        @Assert(tag.title.getOrThrow() == "跨页标题")
        @Assert(tag.artist.getOrThrow() == "跨页艺术家")
    }

    /// Opus 的注释头 magic 是 "OpusTags"，但结构同构于 Vorbis comment
    @TestCase
    func opusTagsAreRead() {
        let comment = ogVorbisComment("vendor", ["TITLE=Opus 标题", "GENRE=Test"])
        let data = ogTwoPageStream(1, ogOpusIdent(), ogOpusTagsPacket(comment), false)

        let tag = parseOggTags(data)
        @Assert(tag.title.getOrThrow() == "Opus 标题")
        @Assert(tag.genre.getOrThrow() == "Test")
    }

    /// 畸形输入一律返回空 Tag 且不崩溃
    ///
    /// 标签数据来自不可信输入，这里覆盖四类畸形：段表撒谎、页头独占、
    /// 完全不是 Ogg、首个页缺少 BOS 标志。
    @TestCase
    func malformedPagesAreSafe() {
        // (a) 段表声称 1 段、值为 255（packet 未结束），但页体一个字节都没有
        let lyingSegment = ogPage(1, 0, 0x02u8, [255], Array<UInt8>())
        @Assert(parseOggTags(lyingSegment).hasNoStandardFields())

        // (b) 只有 27 字节页头，连段表都没有
        let headerOnly = safeSlice(ogPage(1, 0, 0x02u8, [1], [0u8]), 0, 27)
        @Assert(parseOggTags(headerOnly).hasNoStandardFields())

        // (c) 空输入与非 Ogg 数据
        @Assert(parseOggTags(Array<UInt8>()).hasNoStandardFields())
        @Assert(parseOggTags([0x00, 0x01, 0x02, 0x03]).hasNoStandardFields())

        // (d) 首个页不是 BOS：不是规范的 Ogg 流，应放弃而不是硬解
        let comment = ogVorbisComment("v", ["TITLE=不该被读出"])
        let noBos = ArrayList<UInt8>()
        for (b in ogPage(1, 0, 0x00u8, [ogVorbisIdent().size], ogVorbisIdent())) {
            noBos.add(b)
        }
        for (b in ogPage(1, 1, 0x00u8, [ogVorbisCommentPacket(comment).size], ogVorbisCommentPacket(comment))) {
            noBos.add(b)
        }
        @Assert(parseOggTags(noBos.toArray()).hasNoStandardFields())
    }

    /// 多个逻辑流混排：只取首个 BOS 流，绝不把两条流的 packet 拼起来
    ///
    /// Ogg 允许一个文件里复用多条逻辑流（音视频复用即为典型）。
    /// 不按 serial 隔离的话，两条流的包会被错误地拼接成垃圾。
    @TestCase
    func multipleLogicalStreamsDoNotMix() {
        let c1 = ogVorbisComment("s1", ["TITLE=流一"])
        let c2 = ogVorbisComment("s2", ["TITLE=流二"])

        // 交错排列：流一页0、流二页0、流一页1、流二页1
        let out = ArrayList<UInt8>()
        for (b in ogPage(1, 0, 0x02u8, [ogVorbisIdent().size], ogVorbisIdent())) {
            out.add(b)
        }
        for (b in ogPage(2, 0, 0x02u8, [ogVorbisIdent().size], ogVorbisIdent())) {
            out.add(b)
        }
        for (b in ogPage(1, 1, 0x00u8, [ogVorbisCommentPacket(c1).size], ogVorbisCommentPacket(c1))) {
            out.add(b)
        }
        for (b in ogPage(2, 1, 0x00u8, [ogVorbisCommentPacket(c2).size], ogVorbisCommentPacket(c2))) {
            out.add(b)
        }

        let tag = parseOggTags(out.toArray())
        // 取首个 BOS 流（serial=1）的标签
        @Assert(tag.title.getOrThrow() == "流一")
    }

    /// 真实素材：带标签的 Vorbis / Opus / FLAC-in-Ogg 都能读出标签
    ///
    /// FLAC-in-Ogg 这条尤其关键：它的标签**不在首个 packet** 里，而是散在后续
    /// packet 承载的 FLAC 元数据块链中，因此它同时验证了「Ogg 页重组」与
    /// 「FLAC 块链复原」两段逻辑。
    @TestCase
    func realTaggedFixtures() {
        if (gsSkipIfNoFixtures("realTaggedFixtures")) {
            return
        }

        let root = "testdata/ogg"

        let v = AudioFile.readTags("${root}/ogg_vorbis_tagged.ogg")
        @Assert(v.title.getOrThrow() == "OGG Vorbis 标题")
        @Assert(v.artist.getOrThrow() == "元宝")
        @Assert(v.album.getOrThrow() == "Test Fixtures")
        @Assert(v.track.getOrThrow() == 5)

        let o = AudioFile.readTags("${root}/ogg_opus_tagged.opus")
        @Assert(o.title.getOrThrow() == "OGG Opus 标题")
        @Assert(o.artist.getOrThrow() == "元宝")

        let f = AudioFile.readTags("${root}/ogg_flac_tagged.oga")
        @Assert(f.title.getOrThrow() == "Ogg FLAC 标题")
        @Assert(f.artist.getOrThrow() == "元宝")
        @Assert(f.album.getOrThrow() == "Test Fixtures")
        @Assert(f.track.getOrThrow() == 7)
    }

    /// 关键契约：读标签**不要求容器可解码**
    ///
    /// Ogg/Vorbis 至今没有解码实现（supported = false），但它的标签必须读得出来
    /// —— 这正是 readTags 独立于 open 存在的理由。本用例先确认"确实解不了码"，
    /// 再确认"标签读得出来"，两条一起才构成完整的契约验证。
    @TestCase
    func readTagsWorksWithoutDecoder() {
        if (gsSkipIfNoFixtures("readTagsWorksWithoutDecoder")) {
            return
        }

        let path = "testdata/ogg/ogg_vorbis_tagged.ogg"

        // 前提：该文件当前确实不能解码
        var openFailed = false
        try {
            let f = AudioFile.open(path)
            f.close()
        } catch (e: FormatNotSupportedException) {
            openFailed = true
        }
        @Assert(openFailed)

        // 但标签可以读
        let tag = AudioFile.readTags(path)
        @Assert(tag.title.getOrThrow() == "OGG Vorbis 标题")
    }

    /// Speex 的注释机制与 Vorbis comment 不同 —— 如实返回空 Tag（不是错误）
    ///
    /// 本实现只认 Vorbis 的 0x03"vorbis" 与 Opus 的 "OpusTags" 两种注释头 magic。
    /// Speex 的注释头不带这两种 magic，故不解析。这是**已知限制**而非缺陷：
    /// 与其用"猜"的方式去解析，不如明确地返回空 Tag。
    @TestCase
    func speexCommentIsNotCovered() {
        if (gsSkipIfNoFixtures("speexCommentIsNotCovered")) {
            return
        }

        let tag = AudioFile.readTags("testdata/ogg/ogg_speex_16000.spx")
        @Assert(tag.hasNoStandardFields())
    }
}
