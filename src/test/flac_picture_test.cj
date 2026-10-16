package audio4cj.test

import audio4cj.meta.Tag
import audio4cj.meta.base64Decode
import audio4cj.meta.parseFlacMetadata
import audio4cj.meta.parseFlacPictureBlock
import audio4cj.meta.parseVorbisComment
import std.collection.ArrayList

/* ============================================================================
 * FLAC PICTURE 块 / Vorbis `METADATA_BLOCK_PICTURE` / base64 测试
 *
 * 自包含：全部在内存中构造字节后直接调用解析函数，不依赖任何素材文件
 *   （故可随制品包分发，见 cjpm.toml 的 include 白名单）。
 *
 * 覆盖两条封面载体的**同一份**实现：
 *   ① FLAC 元数据块类型 6（PICTURE）；
 *   ② Vorbis comment 的 `METADATA_BLOCK_PICTURE`（base64 后的同结构）。
 * ========================================================================== */

private let PIC_B64_ALPHABET: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

private func picAppendU32BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 24) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func picAppendU32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

private func picConcat(parts: Array<Array<UInt8>>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (p in parts) {
        for (b in p) {
            out.add(b)
        }
    }
    out.toArray()
}

/// 8 字节 PNG 文件签名（真实图片魔数，用于验证 MIME 嗅探回退）
private func picPngSignature(): Array<UInt8> {
    [0x89u8, 0x50u8, 0x4Eu8, 0x47u8, 0x0Du8, 0x0Au8, 0x1Au8, 0x0Au8]
}

/// 构造一个 PICTURE 块**块体**（不含块头）。
private func picBuildPictureBody(picType: Int64, mime: String, desc: String, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    picAppendU32BE(out, picType)
    let mb = mime.toArray()
    picAppendU32BE(out, mb.size)
    for (b in mb) {
        out.add(b)
    }
    let db = desc.toArray()
    picAppendU32BE(out, db.size)
    for (b in db) {
        out.add(b)
    }
    picAppendU32BE(out, 1) // 宽
    picAppendU32BE(out, 1) // 高
    picAppendU32BE(out, 24) // 色深
    picAppendU32BE(out, 0) // 调色板色数
    picAppendU32BE(out, payload.size)
    for (b in payload) {
        out.add(b)
    }
    out.toArray()
}

/// 把块体包成 FLAC 元数据块（4 字节块头：最后块标志 + 类型 + 3 字节大端长度）。
private func picWrapFlacBlock(blockType: Int64, body: Array<UInt8>, isLast: Bool): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(UInt8((if (isLast) {
        0x80
    } else {
        0
    }) | (blockType & 0x7F)))
    out.add(UInt8((body.size >> 16) & 0xFF))
    out.add(UInt8((body.size >> 8) & 0xFF))
    out.add(UInt8(body.size & 0xFF))
    for (b in body) {
        out.add(b)
    }
    out.toArray()
}

/// 构造 FLAC 流：标识 + STREAMINFO(34 字节全零) + 若干块。
private func picBuildFlacStream(tail: Array<Array<UInt8>>): Array<UInt8> {
    var parts = ArrayList<Array<UInt8>>()
    parts.add("fLaC".toArray())
    parts.add(picWrapFlacBlock(0, Array<UInt8>(34, repeat: 0), false))
    for (t in tail) {
        parts.add(t)
    }
    picConcat(parts.toArray())
}

/// 构造 Vorbis comment 块体（小端）。
private func picBuildVorbisComment(entries: Array<String>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    let vendor = "pic-test".toArray()
    picAppendU32LE(out, vendor.size)
    for (b in vendor) {
        out.add(b)
    }
    picAppendU32LE(out, entries.size)
    for (e in entries) {
        let eb = e.toArray()
        picAppendU32LE(out, eb.size)
        for (b in eb) {
            out.add(b)
        }
    }
    out.toArray()
}

/// base64 编码（测试自备：与被测解码器**相互独立**，避免用被测实现自证）。
private func picBase64Encode(bytes: Array<UInt8>): String {
    let alpha = PIC_B64_ALPHABET.toArray()
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i + 3 <= bytes.size) {
        let n = (Int64(bytes[i]) << 16) | (Int64(bytes[i + 1]) << 8) | Int64(bytes[i + 2])
        out.add(alpha[(n >> 18) & 63])
        out.add(alpha[(n >> 12) & 63])
        out.add(alpha[(n >> 6) & 63])
        out.add(alpha[n & 63])
        i += 3
    }
    let rem = bytes.size - i
    if (rem == 1) {
        let n = Int64(bytes[i]) << 16
        out.add(alpha[(n >> 18) & 63])
        out.add(alpha[(n >> 12) & 63])
        out.add(0x3Du8)
        out.add(0x3Du8)
    } else if (rem == 2) {
        let n = (Int64(bytes[i]) << 16) | (Int64(bytes[i + 1]) << 8)
        out.add(alpha[(n >> 18) & 63])
        out.add(alpha[(n >> 12) & 63])
        out.add(alpha[(n >> 6) & 63])
        out.add(0x3Du8)
    }
    String.fromUtf8(out.toArray())
}

// ---------------------------------------------------------------------------
// PICTURE 块体解析
// ---------------------------------------------------------------------------

@Test
class FlacPictureBlockTest {
    /// 最小可用块：类型 + MIME + 空描述 + 几何字段 + 数据
    @TestCase
    func parsesWellFormedBlock() {
        let payload = picPngSignature()
        let body = picBuildPictureBody(3, "image/png", "", payload)
        let pic = parseFlacPictureBlock(body).getOrThrow()

        @Assert(pic.picType == 3)
        @Assert(pic.mime == "image/png")
        @Assert(pic.data.size == payload.size)
        @Assert(pic.data[0] == 0x89u8)
        @Assert(pic.data[7] == 0x0Au8)
    }

    /// 描述与几何字段（宽/高/色深/色数）必须被正确跳过
    @TestCase
    func skipsDescriptionAndGeometry() {
        let payload = picPngSignature()
        let body = picBuildPictureBody(0, "image/jpeg", "front cover art", payload)
        let pic = parseFlacPictureBlock(body).getOrThrow()

        @Assert(pic.picType == 0)
        @Assert(pic.mime == "image/jpeg")
        @Assert(pic.data.size == payload.size)
        @Assert(pic.data[1] == 0x50u8)
    }

    /// 图片类型 3 = front cover 应被原样读出（供多块择优使用）
    @TestCase
    func readsFrontCoverType() {
        let body = picBuildPictureBody(3, "image/png", "front", picPngSignature())
        @Assert(parseFlacPictureBlock(body).getOrThrow().picType == 3)
    }

    /// MIME 为空时退回魔数嗅探
    @TestCase
    func emptyMimeFallsBackToMagic() {
        let body = picBuildPictureBody(3, "", "", picPngSignature())
        @Assert(parseFlacPictureBlock(body).getOrThrow().mime == "image/png")
    }

    /// 约定 "-->" 表示数据段是 URL 而非图片 → 视为无封面
    @TestCase
    func urlPseudoMimeIsRejected() {
        let body = picBuildPictureBody(3, "-->", "", "http://x/y.png".toArray())
        @Assert(parseFlacPictureBlock(body).isNone())
    }

    /// 图片数据长度为 0 → 无封面
    @TestCase
    func zeroLengthImageIsRejected() {
        let body = picBuildPictureBody(3, "image/png", "", Array<UInt8>())
        @Assert(parseFlacPictureBlock(body).isNone())
    }

    /// 任意位置截断都不得抛异常（标签是不可信输入）
    @TestCase
    func truncatedBlockNeverThrows() {
        let body = picBuildPictureBody(3, "image/png", "d", picPngSignature())
        var cut: Int64 = 0
        while (cut < Int64(body.size)) {
            let partial = body[0..cut]
            @Assert(parseFlacPictureBlock(partial).isNone())
            cut += 1
        }
    }

    /// 长度字段越界（数据段声称比实际长）→ 无封面，且不越界读
    @TestCase
    func overlongDataLengthIsRejected() {
        let body = picBuildPictureBody(3, "image/png", "", picPngSignature())
        // 数据长度字段位于块尾 4 + 数据 8 = 12 字节之前，按大端改成 0x0000FFFF
        let n = Int64(body.size)
        @Assert(n >= 12)
        body[n - 12] = 0x00u8
        body[n - 11] = 0x00u8
        body[n - 10] = 0xFFu8
        body[n - 9] = 0xFFu8
        @Assert(parseFlacPictureBlock(body).isNone())
    }
}

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

@Test
class Base64DecodeTest {
    /// RFC 4648 的标准向量
    @TestCase
    func decodesRfcVectors() {
        let a = base64Decode("TWFu").getOrThrow()
        @Assert(a.size == 3)
        @Assert(a[0] == 0x4Du8 && a[1] == 0x61u8 && a[2] == 0x6Eu8)

        let b = base64Decode("TWE=").getOrThrow()
        @Assert(b.size == 2)
        @Assert(b[0] == 0x4Du8 && b[1] == 0x61u8)

        let c = base64Decode("TQ==").getOrThrow()
        @Assert(c.size == 1)
        @Assert(c[0] == 0x4Du8)

        @Assert(base64Decode("").getOrThrow().size == 0)
    }

    /// 换行/空格/制表被忽略（PICTURE 的 base64 常按行折行）
    @TestCase
    func toleratesWhitespace() {
        let a = base64Decode("TWFu\nTWFu").getOrThrow()
        @Assert(a.size == 6)
        @Assert(a[3] == 0x4Du8)

        let b = base64Decode(" TW Fu\t").getOrThrow()
        @Assert(b.size == 3)
    }

    /// 非法字符 → None（不抛异常）
    @TestCase
    func rejectsInvalidCharacter() {
        @Assert(base64Decode("TW*u").isNone())
        @Assert(base64Decode("TWFu$").isNone())
    }

    /// 只凑出 6 位的尾组（合法输入不可能产生）→ None
    @TestCase
    func rejectsDanglingSixBits() {
        @Assert(base64Decode("T").isNone())
    }

    /// 与独立实现的编码器互逆（覆盖 0/1/2 字节余数三种情形）
    @TestCase
    func roundTripsAgainstIndependentEncoder() {
        let lens = [1, 2, 3, 4, 5, 6, 7, 8, 33]
        for (len in lens) {
            var src = Array<UInt8>(len, {i => UInt8((i * 7 + 3) & 0xFF)})
            let text = picBase64Encode(src)
            let back = base64Decode(text).getOrThrow()
            @Assert(back.size == src.size)
            for (i in 0..src.size) {
                @Assert(back[i] == src[i])
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 两条载体接入 Tag
// ---------------------------------------------------------------------------

@Test
class FlacCoverIntegrationTest {
    /// FLAC 元数据块链中的 PICTURE 块被读成封面（VORBIS_COMMENT 在它之后）
    @TestCase
    func metadataChainPicksUpPictureBlock() {
        let payload = picPngSignature()
        let stream = picBuildFlacStream(
            [
                picWrapFlacBlock(6, picBuildPictureBody(3, "image/png", "", payload), false),
                picWrapFlacBlock(4, picBuildVorbisComment(["TITLE=Song"]), true)
            ]
        )
        let tag = parseFlacMetadata(stream)

        @Assert(tag.title.getOrThrow() == "Song")
        @Assert(tag.coverMime.getOrThrow() == "image/png")
        @Assert(tag.coverArt.getOrThrow().size == payload.size)
    }

    /// 只有 PICTURE 块、没有 VORBIS_COMMENT 时也要拿到封面
    @TestCase
    func pictureWithoutVorbisComment() {
        let payload = picPngSignature()
        let stream = picBuildFlacStream([picWrapFlacBlock(6, picBuildPictureBody(3, "image/jpeg", "", payload), true)])
        let tag = parseFlacMetadata(stream)

        @Assert(tag.title.isNone())
        @Assert(tag.coverMime.getOrThrow() == "image/jpeg")
        @Assert(tag.coverArt.getOrThrow().size == payload.size)
    }

    /// 多个 PICTURE 块：front cover（类型 3）优先于其他类型
    @TestCase
    func frontCoverWinsAmongBlocks() {
        let other = picPngSignature()
        let front = picPngSignature()
        front[7] = 0x99u8 // 让两份数据可区分
        let stream = picBuildFlacStream(
            [
                picWrapFlacBlock(6, picBuildPictureBody(0, "image/png", "back", other), false),
                picWrapFlacBlock(6, picBuildPictureBody(3, "image/png", "front", front), false),
                picWrapFlacBlock(4, picBuildVorbisComment(["TITLE=X"]), true)
            ]
        )
        let tag = parseFlacMetadata(stream)

        @Assert(tag.coverArt.getOrThrow()[7] == 0x99u8)
    }

    /// 只有一个非 front 的 PICTURE 块时仍然采用它
    @TestCase
    func soleNonFrontCoverIsUsed() {
        let payload = picPngSignature()
        payload[7] = 0x77u8
        let stream = picBuildFlacStream(
            [
                picWrapFlacBlock(6, picBuildPictureBody(0, "image/png", "", payload), false),
                picWrapFlacBlock(4, picBuildVorbisComment(["TITLE=X"]), true)
            ]
        )
        @Assert(parseFlacMetadata(stream).coverArt.getOrThrow()[7] == 0x77u8)
    }

    /// Vorbis comment 的 METADATA_BLOCK_PICTURE 被解码成封面
    @TestCase
    func vorbisPictureEntryIsDecoded() {
        let payload = picPngSignature()
        let block = picBuildPictureBody(3, "image/png", "front", payload)
        let comment = picBuildVorbisComment(["TITLE=Song", "METADATA_BLOCK_PICTURE=" + picBase64Encode(block)])
        let tag = parseVorbisComment(comment)

        @Assert(tag.title.getOrThrow() == "Song")
        @Assert(tag.coverMime.getOrThrow() == "image/png")
        @Assert(tag.coverArt.getOrThrow().size == payload.size)
        // 巨型 base64 不得落进 extra（否则 Tag 体量失控）
        @Assert(!tag.extra.contains("METADATA_BLOCK_PICTURE"))
    }

    /// 注释头与 PICTURE 块并存时，注释头优先（PICTURE 块只补空）
    @TestCase
    func vorbisPictureTakesPrecedenceOverBlock() {
        let fromComment = picPngSignature()
        fromComment[7] = 0xAAu8
        let fromBlock = picPngSignature()
        fromBlock[7] = 0xBBu8

        let commentBody = picBuildVorbisComment(
            ["METADATA_BLOCK_PICTURE=" + picBase64Encode(picBuildPictureBody(3, "image/png", "", fromComment))]
        )
        let stream = picBuildFlacStream(
            [
                picWrapFlacBlock(6, picBuildPictureBody(3, "image/png", "", fromBlock), false),
                picWrapFlacBlock(4, commentBody, true)
            ]
        )
        @Assert(parseFlacMetadata(stream).coverArt.getOrThrow()[7] == 0xAAu8)
    }

    /// 非法 base64 的封面条目被静默跳过（其余字段照常解析）
    @TestCase
    func invalidPictureBase64IsIgnored() {
        let comment = picBuildVorbisComment(["TITLE=Song", "METADATA_BLOCK_PICTURE=!!!not-base64!!!"])
        let tag = parseVorbisComment(comment)

        @Assert(tag.title.getOrThrow() == "Song")
        @Assert(tag.coverArt.isNone())
        @Assert(tag.coverMime.isNone())
    }

    /// 没有封面的 FLAC 流不受影响（回归：既有「有标签、无封面」素材的形态）
    @TestCase
    func streamWithoutPictureHasNoCover() {
        let stream = picBuildFlacStream([picWrapFlacBlock(4, picBuildVorbisComment(["TITLE=Song"]), true)])
        let tag = parseFlacMetadata(stream)

        @Assert(tag.title.getOrThrow() == "Song")
        @Assert(tag.coverArt.isNone())
    }
}
