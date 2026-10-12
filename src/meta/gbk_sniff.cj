package audio4cj.meta

import std.collection.ArrayList

/* ============================================================================
 * ID3v2 编码嗅探 —— GBK 回退（v0.1.6）
 *
 * 【为什么需要】大量中文 MP3 的 ID3v2.3 文本帧把 GBK 内容错标为编码 0
 *   （ISO-8859-1）。按规范逐字节映射 Latin-1 会得到一片乱码；而内置
 *   CP936 表（gbk_table.cj）后即可正确解码，不引入任何第三方依赖。
 *
 * 【三层判据】全部满足才采用 GBK 解码结果，否则回退 Latin-1：
 *   1. 字节流中存在合法 GBK 双字节序列（首 0x81–0xFE，次 0x40–0xFE 除 0x7F）；
 *   2. 贪心配对：所有 >= 0x80 的字节都能成功配对（不留孤立高位字节）；
 *   3. 解码结果含 CJK 字符——纯 Latin-1 文本即使碰巧全部配对成功，
 *      也几乎不可能解出 CJK，以此把西欧语言的误判挡掉。
 * ========================================================================== */

/// 尝试把字节流按 GBK 解码；判据不满足返回 None（调用方回退 Latin-1）。
protected func tryGbkDecode(data: Array<UInt8>): ?String {
    let n = Int64(data.size)
    if (n < 2) {
        return None
    }
    var hasPair = false
    var i: Int64 = 0
    let out = ArrayList<UInt8>()
    while (i < n) {
        let b = data[i]
        if (b < 0x80) {
            out.add(b)
            i += 1
            continue
        }
        // 高位字节：必须是合法 GBK 双字节首字节，且次字节在合法范围
        if (b < 0x81 || i + 1 >= n) {
            return None
        }
        let t = data[i + 1]
        if (t < 0x40 || t == 0x7F) {
            return None
        }
        let uni = gbkLookup(Int64(b) * 256 + Int64(t))
        if (uni < 0) {
            return None
        }
        hasPair = true
        appendUtf8Bytes(out, UInt32(uni))
        i += 2
    }
    if (!hasPair) {
        return None
    }
    let text = String.fromUtf8(out.toArray())
    // 判据 3：结果需含 CJK
    var hasCjk = false
    for (r in text.runes()) {
        let u = UInt32(r)
        if ((u >= 0x2E80 && u <= 0x9FFF) || (u >= 0xFF00 && u <= 0xFFEF)) {
            hasCjk = true
            break
        }
    }
    if (!hasCjk) {
        return None
    }
    Some(text)
}

/// Unicode 码位 → UTF-8 字节（表内数据不含代理区，均为合法标量值）
protected func appendUtf8Bytes(out: ArrayList<UInt8>, u: UInt32): Unit {
    if (u < 0x80u32) {
        out.add(UInt8(u))
    } else if (u < 0x800u32) {
        out.add(UInt8(0xC0u32 | (u >> 6)))
        out.add(UInt8(0x80u32 | (u & 0x3Fu32)))
    } else if (u < 0x10000u32) {
        out.add(UInt8(0xE0u32 | (u >> 12)))
        out.add(UInt8(0x80u32 | ((u >> 6) & 0x3Fu32)))
        out.add(UInt8(0x80u32 | (u & 0x3Fu32)))
    } else {
        out.add(UInt8(0xF0u32 | (u >> 18)))
        out.add(UInt8(0x80u32 | ((u >> 12) & 0x3Fu32)))
        out.add(UInt8(0x80u32 | ((u >> 6) & 0x3Fu32)))
        out.add(UInt8(0x80u32 | (u & 0x3Fu32)))
    }
}
