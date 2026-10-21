package audio4cj.meta

import audio4cj.pcm.readUInt32LE
import std.collection.*

/* ============================================================================
 * Vorbis comment 序列化 —— `parseVorbisComment` 的逆变换（纯函数，零 I/O）
 *
 * 结构（**全部小端**，见 vorbis_comment.cj 的头注释）：
 *
 *   [4] vendor 字符串长度
 *   [n] vendor 字符串（UTF-8）
 *   [4] 注释条目数
 *   重复「条目数」次：
 *     [4] 条目长度
 *     [m] 条目内容（UTF-8，"KEY=value"）
 *
 * 写入策略（与 id3v2_write 同一安全子集原则）：
 *   - 只写**有值**的标准字段；`extra` 兜底字段不回写（键名体系歧义，宁可丢弃）
 *   - 键名用大写规范形（TITLE/ARTIST/...），值原样 UTF-8
 *   - 键的选取与读侧映射（applyVorbisEntry）严格对偶，保证写读 roundtrip
 *   - 封面走 **METADATA_BLOCK_PICTURE** 条目（base64 的 PICTURE 块体）——
 *     这是 Vorbis comment 唯一的封面载体（FLAC 文件另有独立 PICTURE 块，
 *     由块链写入器负责，两处不重复写同一封面）
 * ========================================================================== */

/// 写入端统一的 vendor 串（读侧会原样跳过它，内容无语义约束）。
private let VORBIS_VENDOR: String = "audio4cj"

/// 追加一个小端 32 位整数。
private func putU32LE(out: ArrayList<UInt8>, v: UInt32): Unit {
    out.add(UInt8(v & 0xFFu32))
    out.add(UInt8((v >> 8) & 0xFFu32))
    out.add(UInt8((v >> 16) & 0xFFu32))
    out.add(UInt8((v >> 24) & 0xFFu32))
}

/// `KEY=value` 条目的序列化字节（4 字节小端长度 + UTF-8 内容）。
private func vorbisEntry(key: String, value: String): Array<UInt8> {
    let text = "${key}=${value}"
    let body = text.toArray()
    let out = ArrayList<UInt8>()
    putU32LE(out, UInt32(body.size))
    for (b in body) {
        out.add(b)
    }
    out.toArray()
}

/// 追加一个非空文本条目（值缺失或空串时不产生条目）。
private func addEntryIfPresent(out: ArrayList<UInt8>, key: String, v: ?String): Unit {
    if (let Some(value) <- v) {
        if (!value.isEmpty()) {
            for (b in vorbisEntry(key, value)) {
                out.add(b)
            }
        }
    }
}

/// 把统一 `Tag` 序列化为完整的 Vorbis comment 块体（vendor + 条目列表）。
protected func serializeVorbisComment(tag: Tag): Array<UInt8> {
    let body = ArrayList<UInt8>()

    // ---- vendor ----
    let vendor = VORBIS_VENDOR.toArray()
    putU32LE(body, UInt32(vendor.size))
    for (b in vendor) {
        body.add(b)
    }

    // ---- 条目 ----
    let entries = ArrayList<UInt8>()
    addEntryIfPresent(entries, "TITLE", tag.title)
    addEntryIfPresent(entries, "ARTIST", tag.artist)
    addEntryIfPresent(entries, "ALBUM", tag.album)
    addEntryIfPresent(entries, "ALBUMARTIST", tag.albumArtist)
    addEntryIfPresent(entries, "DATE", tag.year)
    addEntryIfPresent(entries, "GENRE", tag.genre)
    addEntryIfPresent(entries, "COMPOSER", tag.composer)
    // 读侧 TRACKNUMBER 走 parseNumberPair，"n/total" 形式能同时还原 cur/total
    if (tag.track.isSome() || tag.trackTotal.isSome()) {
        let t = numberPairText(tag.track, tag.trackTotal)
        if (!t.isEmpty()) {
            for (b in vorbisEntry("TRACKNUMBER", t)) {
                entries.add(b)
            }
        }
    }
    // DISCNUMBER 与 DISCTOTAL 是两个独立键（读侧分别映射 disc / discTotal）
    if (tag.disc.isSome()) {
        for (b in vorbisEntry("DISCNUMBER", numberPairText(tag.disc, None))) {
            entries.add(b)
        }
    }
    if (tag.discTotal.isSome()) {
        for (b in vorbisEntry("DISCTOTAL", numberPairText(tag.discTotal, None))) {
            entries.add(b)
        }
    }
    addEntryIfPresent(entries, "COMMENT", tag.comment)
    addEntryIfPresent(entries, "LYRICS", tag.lyrics)

    // 封面：base64 的 PICTURE 块体进 METADATA_BLOCK_PICTURE
    if (let Some(art) <- tag.coverArt) {
        if (art.size > 0) {
            let mime = match (tag.coverMime) {
                case Some(m) => m
                case None => "image/jpeg"
            }
            let pic = serializeFlacPictureBlock(FLAC_PICTURE_TYPE_FRONT, mime, art)
            for (b in vorbisEntry("METADATA_BLOCK_PICTURE", base64Encode(pic))) {
                entries.add(b)
            }
        }
    }

    // ---- 条目数 + 条目体 ----
    // 条目数是**条目个数**（不是字节数）：顺链跳过每条定长头 + 变长体来数
    putU32LE(body, UInt32(countVorbisEntries(entries.toArray())))
    for (b in entries) {
        body.add(b)
    }
    body.toArray()
}

/// 数条目：条目结构定长头 + 变长体，顺链数到末尾。
private func countVorbisEntries(entries: Array<UInt8>): Int64 {
    var count: Int64 = 0
    var offset: Int64 = 0
    while (offset + 4 <= entries.size) {
        let len = Int64(readUInt32LE(entries, offset))
        offset += 4 + len
        if (offset > entries.size) {
            break
        }
        count += 1
    }
    count
}
