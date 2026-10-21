package audio4cj.meta

import std.collection.*

/* ============================================================================
 * FLAC PICTURE 块（元数据块类型 6）+ base64 解码 —— 封面专项
 *
 * 结构（长度与数值字段均为 **4 字节大端**）：
 *
 *   [4] 图片类型（0=Other，3=Cover(front)，其余见 FLAC 规范 §8）
 *   [4] MIME 长度 n
 *   [n] MIME（ASCII；约定 "-->" 表示数据段是 URL 而非图片）
 *   [4] 描述长度 m
 *   [m] 描述（UTF-8）
 *   [4] 宽   [4] 高   [4] 色深   [4] 调色板色数
 *   [4] 图片数据长度 d
 *   [d] 图片数据
 *
 * **两处入口共用本文件**（结构完全相同，只是载体不同）：
 *   ① FLAC 文件的元数据块链（类型 6，见 flac.cj）；
 *   ② Vorbis comment 的 `METADATA_BLOCK_PICTURE` 条目——它是同一结构的
 *      **base64 编码**（见 vorbis_comment.cj）。Ogg 容器里没有 PICTURE 块，
 *      封面只能走这条路。
 *
 * 容错：长度越界、描述/数据段截断、图片数据为空、MIME 为 "-->" 一律返回
 *   `None`，由调用方当作"没有封面"处理——不抛异常。理由与 tags 其余路径一致：
 *   标签来自不可信输入，读标签失败不该影响解码。
 * ========================================================================== */

/// 一个 PICTURE 块的解析结果（只保留对外有用的三项）。
///
/// 类型本身是 `protected`（模块内可见，不对外暴露）；成员标 `public` 只为让
/// 同模块的测试包能读——两者叠加后的实际可见范围仍限于本模块。
protected struct FlacPicture {
    public var picType: Int64 = 0
    public var mime: String = ""
    public var data: Array<UInt8> = Array<UInt8>(0, repeat: 0)
}

/// 解析一个 PICTURE 块体（**不含**块头/长度前缀）。
///
/// - `body`：块体字节，长度即块体长度
/// - 返回：`Some(FlacPicture)`，结构非法时为 `None`
protected func parseFlacPictureBlock(body: Array<UInt8>): ?FlacPicture {
    let n = Int64(body.size)
    if (n < 8) {
        return None
    }

    var at: Int64 = 0
    let picType = Int64(readUInt32BE(body, at))
    at += 4

    let mimeLen = Int64(readUInt32BE(body, at))
    at += 4
    if (mimeLen < 0 || at + mimeLen > n) {
        return None
    }
    let mime = decodeLatin1(safeSlice(body, at, mimeLen))
    at += mimeLen

    if (at + 4 > n) {
        return None
    }
    let descLen = Int64(readUInt32BE(body, at))
    at += 4
    // 跳过描述 + 宽/高/色深/色数（16 字节）
    if (descLen < 0 || at + descLen + 16 + 4 > n) {
        return None
    }
    at += descLen + 16

    let dataLen = Int64(readUInt32BE(body, at))
    at += 4
    if (dataLen <= 0 || at + dataLen > n) {
        return None
    }

    // 规范约定：MIME 为 "-->" 时数据段是 URL 文本，不是图片本体
    if (mime == "-->") {
        return None
    }

    var pic = FlacPicture()
    pic.picType = picType
    pic.mime = if (mime.size > 0) {
        mime
    } else {
        // MIME 缺失的畸形块：退回魔数嗅探，仍认不出则留空字符串
        sniffImageMime(body, at) ?? ""
    }
    pic.data = safeSlice(body, at, dataLen)
    Some(pic)
}

/// 按魔数嗅探图片 MIME（识别不出返回 `None`）。
///
/// 供所有**没有自带 MIME 声明**的封面路径共用的唯一一份实现：APEv2 的
/// `Cover Art (Front)`（apev2.cj）、FLAC PICTURE 块、Vorbis
/// `METADATA_BLOCK_PICTURE`。（ID3v2 的 APIC 帧自带 MIME 字段，不走这里；
/// MP4 的 `covr` 用原子类型判别 JPEG/PNG。）
protected func sniffImageMime(data: Array<UInt8>, from: Int64): ?String {
    if (from < 0 || from + 4 > Int64(data.size)) {
        return None
    }
    // JPEG：FF D8
    if (data[from] == 0xFFu8 && data[from + 1] == 0xD8u8) {
        return Some("image/jpeg")
    }
    // PNG：89 50 4E 47
    if (data[from] == 0x89u8 && data[from + 1] == 0x50u8 && data[from + 2] == 0x4Eu8 && data[from + 3] == 0x47u8) {
        return Some("image/png")
    }
    // GIF：47 49 46
    if (data[from] == 0x47u8 && data[from + 1] == 0x49u8 && data[from + 2] == 0x46u8) {
        return Some("image/gif")
    }
    // BMP：42 4D
    if (data[from] == 0x42u8 && data[from + 1] == 0x4Du8) {
        return Some("image/bmp")
    }
    None
}

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

/// 单字符的 base64 值；非法字符返回 -1。
private func base64Value(c: UInt8): Int64 {
    if (c >= 0x41u8 && c <= 0x5Au8) {
        return Int64(c - 0x41u8) // A-Z → 0..25
    }
    if (c >= 0x61u8 && c <= 0x7Au8) {
        return Int64(c - 0x61u8) + 26 // a-z → 26..51
    }
    if (c >= 0x30u8 && c <= 0x39u8) {
        return Int64(c - 0x30u8) + 52 // 0-9 → 52..61
    }
    if (c == 0x2Bu8) {
        return 62 // '+'
    }
    if (c == 0x2Fu8) {
        return 63 // '/'
    }
    -1
}

/// base64 解码（标准字母表，容忍换行/空格/制表，`=` 补位按约定忽略）。
///
/// 为什么手写：base64 在仓颉 std 里**没有**（在扩展标准库 stdx 才有），
/// 而本库坚持**零外部依赖**（连 C 运行时都已移除，见 `docs/README.md`）。
///
/// 容错：出现非法字符、或尾组只凑出 6 位（不可能由合法输入产生）时返回 `None`，
/// 由调用方当作"没有封面"；**不抛异常**。
protected func base64Decode(text: String): ?Array<UInt8> {
    let out = ArrayList<UInt8>()
    var acc: Int64 = 0
    var bits: Int64 = 0

    for (c in text.toArray()) {
        // '=' 补位：位置与个数不再校验，尾组残位检查已足够挡住畸形输入
        if (c == 0x3Du8) {
            continue
        }
        if (c == 0x0Au8 || c == 0x0Du8 || c == 0x20u8 || c == 0x09u8) {
            continue
        }
        let v = base64Value(c)
        if (v < 0) {
            return None
        }
        acc = (acc << 6) | v
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.add(UInt8((acc >> bits) & 0xFF))
            // 丢弃已输出的高位，避免 acc 无限增长后溢出
            acc = acc & ((1 << bits) - 1)
        }
    }

    if (bits == 6) {
        return None
    }
    out.toArray()
}

/// base64 编码（标准字母表 + `=` 补位，与 `base64Decode` 互逆）。
///
/// 为什么手写：同 `base64Decode` —— std 无 base64，本库坚持零外部依赖。
/// 用途：把封面写入 Vorbis comment 的 `METADATA_BLOCK_PICTURE` 条目时编码
/// PICTURE 块体。输出不分 行（Ogg/FLAC 生态的通行做法，读侧也容忍换行但
/// 写侧统一不产生）。
protected func base64Encode(data: Array<UInt8>): String {
    let table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let chars = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i + 3 <= data.size) {
        let n = (Int64(data[i]) << 16) | (Int64(data[i + 1]) << 8) | Int64(data[i + 2])
        chars.add(UInt8(table.toArray()[(n >> 18) & 0x3F]))
        chars.add(UInt8(table.toArray()[(n >> 12) & 0x3F]))
        chars.add(UInt8(table.toArray()[(n >> 6) & 0x3F]))
        chars.add(UInt8(table.toArray()[n & 0x3F]))
        i += 3
    }
    let rest = data.size - i
    if (rest == 1) {
        let n = Int64(data[i]) << 16
        chars.add(UInt8(table.toArray()[(n >> 18) & 0x3F]))
        chars.add(UInt8(table.toArray()[(n >> 12) & 0x3F]))
        chars.add(UInt8(0x3D)) // '='
        chars.add(UInt8(0x3D))
    } else if (rest == 2) {
        let n = (Int64(data[i]) << 16) | (Int64(data[i + 1]) << 8)
        chars.add(UInt8(table.toArray()[(n >> 18) & 0x3F]))
        chars.add(UInt8(table.toArray()[(n >> 12) & 0x3F]))
        chars.add(UInt8(table.toArray()[(n >> 6) & 0x3F]))
        chars.add(UInt8(0x3D))
    }
    String.fromUtf8(chars.toArray())
}

// ---------------------------------------------------------------------------
// PICTURE 块序列化（parse 的逆变换）—— 标签写入用
// ---------------------------------------------------------------------------

/// 组装一个 FLAC PICTURE 块体（4 字节大端的字段 + 图片数据）。
///
/// 与 `parseFlacPictureBlock` 严格对偶：描述恒空、宽/高/色深/色数填 0
/// （规范允许未知时写 0，读侧不依赖它们），数据为图片原始字节。
protected func serializeFlacPictureBlock(picType: Int64, mime: String, data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    putU32BE(out, UInt32(picType))
    let mimeBytes = mime.toArray()
    putU32BE(out, UInt32(mimeBytes.size))
    for (b in mimeBytes) {
        out.add(b)
    }
    putU32BE(out, 0) // 描述长度（恒空）
    putU32BE(out, 0) // 宽
    putU32BE(out, 0) // 高
    putU32BE(out, 0) // 色深
    putU32BE(out, 0) // 调色板色数
    putU32BE(out, UInt32(data.size))
    for (b in data) {
        out.add(b)
    }
    out.toArray()
}

/// 追加一个大端 32 位整数（与 id3v2_write 的同名逻辑一致，此处独立持有）。
private func putU32BE(out: ArrayList<UInt8>, v: UInt32): Unit {
    out.add(UInt8((v >> 24) & 0xFFu32))
    out.add(UInt8((v >> 16) & 0xFFu32))
    out.add(UInt8((v >> 8) & 0xFFu32))
    out.add(UInt8(v & 0xFFu32))
}
