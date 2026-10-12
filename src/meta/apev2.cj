package audio4cj.meta

import std.collection.ArrayList
import std.fs.*
import std.io.*

/* ============================================================================
 * APEv2 标签解析（v0.1.6）
 *
 * 【为什么需要】国内大量 MP3 由 foobar2000 转出，带 APEv2 标签（常见于文件尾、
 *   ID3v1 之前）。APEv2 的 value 一律 UTF-8，且 `readTags` 宣称"不要求解码
 *   能力"——它正是补齐 APEv2 的合适入口。
 *
 * 【结构】tag = header(32) + items + footer(32)；header/footer 前 8 字节均为
 *   "APETAGEX" magic，footer 的 size 字段 = header+items+footer 的总字节数
 *   （header 存在时）。每个 item：valueSize(4LE) + flags(4LE) + key(ASCII,
 *   NUL 结尾) + value；flags 低 2 位 00 = UTF-8 文本，其余类型跳过。
 *
 * 【查找策略】从文件尾读一个窗口（1 MB，可覆盖带封面的 APE），自后向前找
 *   合法 footer（magic + size/itemCount 合理性校验），跳过文件尾的 ID3v1。
 *   找不到返回空 Tag，不抛异常（与 parseId3v1 等纯解析器约定一致）。
 * ========================================================================== */
private let APE_MAGIC_SIZE: Int64 = 8
private let APE_FOOTER_SIZE: Int64 = 32
private let APE_SCAN_LIMIT: Int64 = 1024 * 1024

/// 解析 APEv2 tag 数据（自 header 起的完整字节），失败返回空 Tag。
protected func parseApev2(data: Array<UInt8>): Tag {
    let tag = Tag()
    // header：magic(8) + version(4) + size(4) + itemCount(4) + flags(4) + reserved(8)
    if (data.size < APE_FOOTER_SIZE) {
        return tag
    }
    let itemCount = readU32LeAt(data, 12)
    let flags = readU32LeAt(data, 16)
    // flags bit31 = header 存在；本函数入参即自 header 起，故 items 从 32 开始
    let hasHeader = (flags & 0x80000000) != 0
    if (!hasHeader) {
        return tag // 无 header 形式少见，暂不支持（避免误读）
    }
    if (itemCount <= 0 || itemCount > 10000) {
        return tag
    }
    var off: Int64 = 32
    var remaining = itemCount
    while (remaining > 0 && off + 8 <= data.size) {
        let valueSize = readU32LeAt(data, off)
        let itemFlags = readU32LeAt(data, off + 4)
        if (valueSize < 0 || valueSize > data.size) {
            return tag // 结构越界：视为损坏，返回已解析部分
        }
        // key：ASCII，NUL 结尾
        var keyEnd = off + 8
        while (keyEnd < data.size && data[keyEnd] != 0) {
            keyEnd += 1
        }
        if (keyEnd >= data.size) {
            return tag
        }
        let key = asciiUpper(utf8SliceToAscii(data, off + 8, keyEnd))
        let valueStart = keyEnd + 1
        let valueEnd = valueStart + valueSize
        if (valueEnd > data.size) {
            return tag
        }
        let kind = itemFlags & 3
        if (kind == 0 && valueSize > 0) {
            applyApeItem(tag, key, safeSlice(data, valueStart, valueEnd))
        }
        off = valueEnd
        remaining -= 1
    }
    tag
}

/// APE item 应用：标准键映射到 Tag 字段，其余进 extra（键 "APE:<KEY>"）。
private func applyApeItem(tag: Tag, key: String, value: Array<UInt8>): Unit {
    let text = utf8OrEmpty(value).trimAscii()
    match (key) {
        case "TITLE" => tag.title = nonEmpty(text)
        case "ARTIST" => tag.artist = nonEmpty(text)
        case "ALBUM" => tag.album = nonEmpty(text)
        case "ALBUM ARTIST" | "ALBUMARTIST" => tag.albumArtist = nonEmpty(text)
        case "YEAR" | "DATE" => tag.year = nonEmpty(text)
        case "GENRE" => tag.genre = nonEmpty(text)
        case "COMMENT" => tag.comment = nonEmpty(text)
        case "COMPOSER" => tag.composer = nonEmpty(text)
        case "LYRICS" => tag.lyrics = nonEmpty(text)
        case "TRACK" =>
            let (cur, total) = parseNumberPair(text)
            tag.track = cur
            tag.trackTotal = total
        case "DISC" | "DISCNUMBER" =>
            let (cur, total) = parseNumberPair(text)
            tag.disc = cur
            tag.discTotal = total
        case "COVER ART (FRONT)" =>
            // value = "文件名\0" + 图片原始数据
            var i: Int64 = 0
            while (i < Int64(value.size) && value[i] != 0) {
                i += 1
            }
            if (i + 1 < Int64(value.size)) {
                tag.coverArt = safeSlice(value, i + 1, Int64(value.size))
                tag.coverMime = sniffImageMime(value, i + 1)
            }
        case _ => tag.putExtra("APE:${key}", text)
    }
}

private func nonEmpty(s: String): ?String {
    if (s.isEmpty()) {
        return None
    }
    Some(s)
}

/// UTF-8 字节转 String（非法序列返回空串——APE 的 value 规范即 UTF-8，
/// 非法说明文件损坏，按无值处理即可）
private func utf8OrEmpty(data: Array<UInt8>): String {
    try {
        String.fromUtf8(data)
    } catch (e: Exception) {
        ""
    }
}

/// 按文件头字节嗅探图片 MIME（只认 JPEG/PNG，够覆盖现实场景）
private func sniffImageMime(data: Array<UInt8>, from: Int64): ?String {
    if (from + 3 > Int64(data.size)) {
        return None
    }
    if (data[from] == 0xFF && data[from + 1] == 0xD8) {
        return Some("image/jpeg")
    }
    if (data[from] == 0x89 && data[from + 1] == 0x50 && data[from + 2] == 0x4E && data[from + 3] == 0x47) {
        return Some("image/png")
    }
    None
}

/// key 归一化为大写（APE 的 key 大小写不敏感）
private func asciiUpper(s: String): String {
    let bytes = s.toArray()
    let out = Array<UInt8>(
        Int64(bytes.size),
        {
            i =>
                let c = bytes[i]
                if (c >= 0x61 && c <= 0x7A) {
                    UInt8(UInt32(c) - 32)
                } else {
                    c
                }
        }
    )
    utf8OrEmpty(out)
}

/// 从 [from, to) 的 ASCII 字节构造字符串（key 恒为 ASCII）
private func utf8SliceToAscii(data: Array<UInt8>, from: Int64, to: Int64): String {
    if (from >= to) {
        return ""
    }
    utf8OrEmpty(safeSlice(data, from, to))
}

private func readU32LeAt(data: Array<UInt8>, off: Int64): Int64 {
    if (off + 4 > data.size) {
        return -1
    }
    (Int64(data[off])) | (Int64(data[off + 1]) << 8) | (Int64(data[off + 2]) << 16) | (Int64(data[off + 3]) << 24)
}

/// 从文件尾窗口查找 APEv2 tag 并解析；找不到返回空 Tag。
protected func readApev2FromFile(path: String): Tag {
    var result = Tag()

    try (f = File(path, Read)) {
        let size = f.length
        if (size < APE_FOOTER_SIZE * 2) {
            return result
        }
        let tailLen = if (size < APE_SCAN_LIMIT) {
            size
        } else {
            APE_SCAN_LIMIT
        }
        f.seek(SeekPosition.End(-tailLen))
        let tail = Array<UInt8>(tailLen, repeat: 0)
        let got = f.read(tail)
        if (got < APE_FOOTER_SIZE * 2) {
            return result
        }
        let win = safeSlice(tail, 0, got)
        // 自后向前找合法 footer：magic 匹配 + size 声明的 tag 完整落在窗口内
        var off = Int64(win.size) - APE_MAGIC_SIZE
        while (off >= 0) {
            if (win[off] == 0x41 && win[off + 1] == 0x50 && win[off + 2] == 0x45 && win[off + 3] == 0x54 &&
                win[off + 4] == 0x41 && win[off + 5] == 0x47 && win[off + 6] == 0x45 && win[off + 7] == 0x58) {
                // footer 结构：magic(8)+version(4)+size(4)+count(4)+flags(4)+rsv(8)
                let declared = readU32LeAt(win, off + 12)
                let count = readU32LeAt(win, off + 16)
                if (declared > APE_FOOTER_SIZE * 2 && declared <= off + APE_FOOTER_SIZE && count > 0 && count <= 10000) {
                    let tagStart = off + APE_FOOTER_SIZE - declared
                    if (tagStart >= 0) {
                        result = parseApev2(safeSlice(win, tagStart, off + APE_FOOTER_SIZE))
                        return result
                    }
                }
            }
            off -= 1
        }
    }

    result
}
