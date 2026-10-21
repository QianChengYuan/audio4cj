package audio4cj.meta

import std.collection.*

/* ============================================================================
 * ID3v2.3 写入 —— 标签写入「安全子集」的第一步（v0.2.0）
 *
 * 安全子集的定义（与审查结论一致）：
 *   - **不改音频帧**：写入 = 剥掉旧 ID3v2（若有）+ 新标签前置 + 其余字节原样保留；
 *   - 只输出 **ID3v2.3**（兼容性最好的版本；v2.4 的 synchsafe 帧长与部分新帧
 *     在老播放器上有兼容风险，v2.2 已过时）；
 *   - 文本统一 **UTF-16 with BOM**（编码 1）：v2.3 官方推荐 Latin-1 或 UTF-16，
 *     UTF-8（编码 3）是 v2.4 才引入的。UTF-16 覆盖全部 Unicode，无 GBK 歧义。
 *
 * 布局（解析侧 id3v2.cj 的镜像）：
 *
 *   [10 字节标签头]  "ID3" + 0x03 0x00 + 标志(0) + synchsafe 长度
 *   [帧序列]         每帧 = 帧 ID(4) + 长度(4, 普通大端) + 标志(2, 恒 0) + 数据
 *
 * 帧数据不做去同步化（unsynchronisation）：本写入器不经过 MPEG 帧同步环境，
 * 标签自身不内嵌 0xFF 帧同步歧义（APIC 的图片字节可能含 0xFF，但按规范
 * 去同步化是可选的，主流写入器均未启用且解析器均能容忍）。
 *
 * 设计：本文件**不做任何文件 I/O**，只接收/返回字节数组 —— I/O 集中在
 * file_tags.cj（读取）与 facade 层（写入分派）。
 * ========================================================================== */

/// ID3v2.3 写入时文本帧使用的编码标识：1 = UTF-16（带 BOM）。
private let ID3V23_TEXT_ENC_UTF16: UInt8 = 1u8

/// 单个帧 ID 的最大长度（规范为 4 字符）。
private let ID3V23_FRAME_ID_LEN: Int64 = 4

// ---------------------------------------------------------------------------
// 编码辅助
// ---------------------------------------------------------------------------

/// 把字符串编码为 UTF-16LE 字节（不带 BOM）。仓颉 String 内部即 UTF-16 单元，
/// 经 Rune 码点统一转出，代理对自然成对。
private func utf16LeBytes(s: String): ArrayList<UInt8> {
    let out = ArrayList<UInt8>()
    for (r in s.runes()) {
        let u = UInt32(r)
        if (u < 0x10000u32) {
            out.add(UInt8(u & 0xFFu32))
            out.add(UInt8((u >> 8) & 0xFFu32))
        } else {
            // 增补平面：拆成高/低代理
            let v = u - 0x10000u32
            let hi = 0xD800u32 + (v >> 10)
            let lo = 0xDC00u32 + (v & 0x3FFu32)
            out.add(UInt8(hi & 0xFFu32))
            out.add(UInt8((hi >> 8) & 0xFFu32))
            out.add(UInt8(lo & 0xFFu32))
            out.add(UInt8((lo >> 8) & 0xFFu32))
        }
    }
    out
}

/// UTF-16LE 字节 + BOM（0xFF 0xFE）+ 双 NUL 终止（文本帧/描述字段的完整载体）。
private func utf16Terminated(s: String): ArrayList<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(0xFFu8)
    out.add(0xFEu8)
    for (b in utf16LeBytes(s)) {
        out.add(b)
    }
    out.add(0u8)
    out.add(0u8)
    out
}

/// Latin-1 兼容的 ASCII 字节（仅用于 MIME 等恒 ASCII 的字段）。
private func asciiBytes(s: String): ArrayList<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in s.toArray()) {
        out.add(b)
    }
    out
}

// ---------------------------------------------------------------------------
// 帧 / 标签序列化
// ---------------------------------------------------------------------------

/// 追加一个大端 32 位整数。
private func putU32BE(out: ArrayList<UInt8>, v: UInt32): Unit {
    out.add(UInt8((v >> 24) & 0xFFu32))
    out.add(UInt8((v >> 16) & 0xFFu32))
    out.add(UInt8((v >> 8) & 0xFFu32))
    out.add(UInt8(v & 0xFFu32))
}

/// 追加 synchsafe 32 位整数（每字节只放 7 位；标签头长度字段专用）。
private func putSynchsafe32(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 21) & 0x7F))
    out.add(UInt8((v >> 14) & 0x7F))
    out.add(UInt8((v >> 7) & 0x7F))
    out.add(UInt8(v & 0x7F))
}

/// 组装一个 ID3v2.3 帧：帧 ID + 普通大端长度 + 2 字节全零标志 + 数据。
private func buildFrame(frameId: String, data: ArrayList<UInt8>): ArrayList<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in asciiBytes(frameId)) {
        out.add(b)
    }
    putU32BE(out, UInt32(data.size))
    out.add(0u8) // 标志高字节
    out.add(0u8) // 标志低字节
    for (b in data) {
        out.add(b)
    }
    out
}

/// 组装文本帧：编码字节(1) + UTF-16(BOM) 文本 + 终止符。
private func textFrame(frameId: String, value: String): ArrayList<UInt8> {
    let data = ArrayList<UInt8>()
    data.add(ID3V23_TEXT_ENC_UTF16)
    for (b in utf16Terminated(value)) {
        data.add(b)
    }
    buildFrame(frameId, data)
}

/// 组装 `COMM`（注释帧）：编码(1) + 语言 "eng"(3) + 空描述(UTF-16 终止) + 文本(UTF-16 终止)。
private func commFrame(value: String): ArrayList<UInt8> {
    let data = ArrayList<UInt8>()
    data.add(ID3V23_TEXT_ENC_UTF16)
    for (b in asciiBytes("eng")) {
        data.add(b)
    }
    for (b in utf16Terminated("")) {
        data.add(b)
    }
    for (b in utf16Terminated(value)) {
        data.add(b)
    }
    buildFrame("COMM", data)
}

/// 组装 `USLT`（歌词帧）：结构与 COMM 同构。
private func usltFrame(value: String): ArrayList<UInt8> {
    let data = ArrayList<UInt8>()
    data.add(ID3V23_TEXT_ENC_UTF16)
    for (b in asciiBytes("eng")) {
        data.add(b)
    }
    for (b in utf16Terminated("")) {
        data.add(b)
    }
    for (b in utf16Terminated(value)) {
        data.add(b)
    }
    buildFrame("USLT", data)
}

/// 组装 `APIC`（封面帧）：编码(1) + MIME(NUL 终止) + 图片类型 0x03(front cover) +
/// 空描述(UTF-16 终止) + 图片原始字节。
private func apicFrame(art: Array<UInt8>, mime: String): ArrayList<UInt8> {
    let data = ArrayList<UInt8>()
    data.add(ID3V23_TEXT_ENC_UTF16)
    for (b in asciiBytes(mime)) {
        data.add(b)
    }
    data.add(0u8) // MIME NUL 终止
    data.add(0x03u8) // front cover
    for (b in utf16Terminated("")) {
        data.add(b)
    }
    for (b in art) {
        data.add(b)
    }
    buildFrame("APIC", data)
}

// ---------------------------------------------------------------------------
// Tag → ID3v2.3 字节
// ---------------------------------------------------------------------------

/// 数字或缺失的占位渲染（`TRCK` / `TPOS` 用 "n" 或 "n/total"）。
private func numberPairText(cur: ?Int64, total: ?Int64): String {
    let c = match (cur) {
        case Some(v) => v.toString()
        case None => return ""
    }
    match (total) {
        case Some(t) => "${c}/${t}"
        case None => c
    }
}

/// 把统一 `Tag` 序列化为完整的 ID3v2.3 标签字节（含 10 字节头部）。
///
/// 只映射**有值**的字段：`None` 字段不产生帧。`extra` 兜底字段**不写入** ——
/// 它承载的是各体系的冷门字段（键格式彼此不同），盲目回写会产生
/// "TPE2"、"TXXX:xxx" 这类键名歧义；写入范围显式限定为标准字段，
/// 不确定的部分宁可丢弃也不写错（安全子集原则）。
protected func serializeId3v23(tag: Tag): Array<UInt8> {
    let frames = ArrayList<UInt8>()

    let textPairs: Array<(String, ?String)> = [
        ("TIT2", tag.title),
        ("TPE1", tag.artist),
        ("TALB", tag.album),
        ("TPE2", tag.albumArtist),
        ("TYER", tag.year),
        ("TCON", tag.genre),
        ("TCOM", tag.composer)
    ]
    for ((id, v) in textPairs) {
        if (let Some(value) <- v) {
            if (!value.isEmpty()) {
                for (b in textFrame(id, value)) {
                    frames.add(b)
                }
            }
        }
    }

    // 数字对：track/disc 任一部分有值即写
    if (tag.track.isSome() || tag.trackTotal.isSome()) {
        let t = numberPairText(tag.track, tag.trackTotal)
        if (!t.isEmpty()) {
            for (b in textFrame("TRCK", t)) {
                frames.add(b)
            }
        }
    }
    if (tag.disc.isSome() || tag.discTotal.isSome()) {
        let d = numberPairText(tag.disc, tag.discTotal)
        if (!d.isEmpty()) {
            for (b in textFrame("TPOS", d)) {
                frames.add(b)
            }
        }
    }

    if (let Some(c) <- tag.comment) {
        if (!c.isEmpty()) {
            for (b in commFrame(c)) {
                frames.add(b)
            }
        }
    }
    if (let Some(l) <- tag.lyrics) {
        if (!l.isEmpty()) {
            for (b in usltFrame(l)) {
                frames.add(b)
            }
        }
    }
    if (let Some(art) <- tag.coverArt) {
        if (art.size > 0) {
            let mime = match (tag.coverMime) {
                case Some(m) => m
                case None => "image/jpeg"
            }
            for (b in apicFrame(art, mime)) {
                frames.add(b)
            }
        }
    }

    // 标签头：长度 = 帧序列总长（synchsafe 编码）
    let out = ArrayList<UInt8>()
    for (b in asciiBytes("ID3")) {
        out.add(b)
    }
    out.add(0x03u8) // 主版本 3
    out.add(0x00u8) // 次版本
    out.add(0x00u8) // 标志：无去同步化 / 无扩展头 / 无页脚
    putSynchsafe32(out, frames.size)
    for (b in frames) {
        out.add(b)
    }
    out.toArray()
}
