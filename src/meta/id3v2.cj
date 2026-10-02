package audio4cj.meta

import std.collection.*

/* ============================================================================
 * ID3v2.2 / 2.3 / 2.4 解析 —— 开发文档 §10 M3
 *
 * 结构总览：
 *
 *   [10 字节标签头]  "ID3" + 主版本 + 次版本 + 标志 + synchsafe 长度
 *   [扩展头]         可选（标志 bit6）
 *   [帧序列]         每帧 = 帧 ID + 长度 + 标志 + 数据
 *   [页脚]           仅 v2.4（标志 bit4），10 字节，"3DI" 开头
 *
 * 三个版本的关键差异：
 *
 *   项目          v2.2                v2.3                v2.4
 *   -----------   -----------------  ------------------  -------------------
 *   帧 ID 长度    3 字节              4 字节              4 字节
 *   帧长度字段    3 字节普通整数      4 字节普通整数      **4 字节 synchsafe**
 *   帧标志        无                  2 字节              2 字节
 *   帧头总长      6 字节              10 字节             10 字节
 *   扩展头长度    —                   4 字节（不含自身）   synchsafe（含自身）
 *   去同步化      标签级              标签级              帧级
 *
 * 文本编码标识（文本帧首字节）：0=ISO-8859-1, 1=UTF-16(BOM), 2=UTF-16BE, 3=UTF-8
 *
 * 设计：本文件**不做任何 I/O**，只接收调用方读入的标签字节。
 *
 * 健壮性：标签来自不可信输入，因此
 *   - 所有切片走 safeSlice（越界收敛，不抛异常）；
 *   - 帧循环设迭代上限（MAX_ID3V2_FRAMES），防畸形数据造成长循环；
 *   - 单个帧解析失败只跳过该帧，不影响其余字段；
 *   - 文本解码失败退回 Latin-1，绝不中断整个标签读取。
 * ========================================================================== */

/// ID3v2 标签的最大可接受字节数（16 MB）。
///
/// 标签长度字段来自文件内容，属不可信输入；设置上限可避免畸形文件
/// 诱导调用方分配巨量内存。超出该值的标签只解析头部、不做帧遍历。
protected let ID3V2_MAX_TAG_SIZE: Int64 = 16 * 1024 * 1024

/// 帧遍历的迭代上限（防畸形数据造成长循环）。
private let MAX_ID3V2_FRAMES: Int64 = 4096

/// 标签头长度。
private let ID3V2_HEADER_SIZE: Int64 = 10

/// 标志位：去同步化（v2.3 及更早为标签级）。
private let ID3V2_FLAG_UNSYNC: UInt8 = 0x80
/// 标志位：存在扩展头。
private let ID3V2_FLAG_EXTENDED: UInt8 = 0x40
/// 标志位：存在页脚（仅 v2.4）。
private let ID3V2_FLAG_FOOTER: UInt8 = 0x10

/// 帧标志位（v2.4）：帧数据被去同步化。
private let ID3V2_FRAME_FLAG_UNSYNC: UInt8 = 0x02

// ---------------------------------------------------------------------------
// 标签长度计算
// ---------------------------------------------------------------------------

/// 由 ID3v2 的 10 字节标签头计算**标签总长度**（含头部与可能的页脚）。
///
/// 返回 `None` 表示头部非法（长度不足、"ID3" 标识缺失、或主版本不在 2–4 范围）。
///
/// 调用方据此决定读取多少字节，避免把整个音频文件读入内存。
protected func id3v2TotalSize(header: Array<UInt8>): ?Int64 {
    if (header.size < ID3V2_HEADER_SIZE) {
        return None
    }
    if (!matchAsciiAt(header, 0, "ID3")) {
        return None
    }
    let major = Int64(header[3])
    if (major < 2 || major > 4) {
        return None
    }

    let flags = header[5]
    var total = ID3V2_HEADER_SIZE + readSynchsafe32(header, 6)

    // v2.4 的页脚不计入长度字段，但占据实际字节
    if (major == 4 && ((flags & ID3V2_FLAG_FOOTER) != 0u8)) {
        total += ID3V2_HEADER_SIZE
    }

    if (total < 0) {
        return None
    }
    Some(total)
}

// ---------------------------------------------------------------------------
// 主解析入口
// ---------------------------------------------------------------------------

/// 解析 ID3v2.2 / 2.3 / 2.4 标签。
///
/// - `tagBytes`：从 "ID3" 标识开始的标签字节（至少 10 字节）
/// - 返回：解析出的 `Tag`；头部非法时返回**空 Tag**（无标签不是错误）
///
/// 已映射的字段见 `applyFrame`；未映射的文本帧进 `extra`（键为规范帧 ID），
/// `TXXX` 进 `extra`（键为 `"TXXX:<描述>"`）。
protected func parseId3v2(tagBytes: Array<UInt8>): Tag {
    let tag = Tag()

    if (tagBytes.size < ID3V2_HEADER_SIZE) {
        return tag
    }
    if (!matchAsciiAt(tagBytes, 0, "ID3")) {
        return tag
    }

    let major = Int64(tagBytes[3])
    if (major < 2 || major > 4) {
        return tag
    }

    let flags = tagBytes[5]
    let declaredSize = readSynchsafe32(tagBytes, 6)
    if (declaredSize <= 0) {
        return tag
    }

    // 正文（不含 10 字节头部与可能的页脚）
    var body = safeSlice(tagBytes, ID3V2_HEADER_SIZE, declaredSize)

    // ---- 标签级去同步化（v2.3 及更早）----
    if (major <= 3 && ((flags & ID3V2_FLAG_UNSYNC) != 0u8)) {
        body = deUnsynchronise(body)
    }

    // ---- 跳过扩展头 ----
    var start: Int64 = 0
    if ((flags & ID3V2_FLAG_EXTENDED) != 0u8) {
        start = extendedHeaderSize(body, major)
    }

    parseFrames(body, start, major, tag)
    tag
}

/// 计算扩展头的总长度（即正文中从何处开始是帧序列）。
private func extendedHeaderSize(body: Array<UInt8>, major: Int64): Int64 {
    if (body.size < 4) {
        return body.size
    }

    var size: Int64 = 0
    if (major == 3) {
        // v2.3：4 字节普通大端长度，**不含自身**
        size = 4 + Int64(readUInt32BE(body, 0))
    } else if (major == 4) {
        // v2.4：synchsafe 长度，**含自身**
        size = readSynchsafe32(body, 0)
    } else {
        return 0
    }

    if (size < 0 || size > body.size) {
        return body.size
    }
    size
}

// ---------------------------------------------------------------------------
// 帧遍历
// ---------------------------------------------------------------------------

/// 遍历帧序列并逐帧应用到 `tag`。
private func parseFrames(body: Array<UInt8>, start: Int64, major: Int64, tag: Tag): Unit {
    let idLen: Int64 = if (major == 2) {
        3
    } else {
        4
    }
    let headLen: Int64 = if (major == 2) {
        6
    } else {
        10
    }

    var offset = start
    var guard: Int64 = 0

    while (offset + headLen <= body.size) {
        guard += 1
        if (guard > MAX_ID3V2_FRAMES) {
            break
        }

        // 填充区（0x00）或非法起始字节即结束
        if (body[offset] == 0u8) {
            break
        }

        let frameId = decodeLatin1(safeSlice(body, offset, idLen))
        if (frameId.size != idLen) {
            break
        }

        // ---- 帧长度：三个版本编码方式不同 ----
        let size = if (major == 2) {
            Int64(readUInt24BE(body, offset + 3))
        } else if (major == 3) {
            Int64(readUInt32BE(body, offset + 4))
        } else {
            readSynchsafe32(body, offset + 4)
        }

        var frameFlags: UInt8 = 0u8
        if (major >= 3) {
            frameFlags = body[offset + 9]
        }

        let dataStart = offset + headLen
        if (size <= 0 || dataStart + size > body.size) {
            // 长度越界：无法继续信任后续帧边界
            break
        }

        var data = safeSlice(body, dataStart, size)

        // ---- 帧级去同步化（仅 v2.4）----
        if (major == 4 && ((frameFlags & ID3V2_FRAME_FLAG_UNSYNC) != 0u8)) {
            data = deUnsynchronise(data)
        }

        applyFrame(tag, major, frameId, data)
        offset = dataStart + size
    }
}

// ---------------------------------------------------------------------------
// 单帧应用
// ---------------------------------------------------------------------------

/// 把单个帧的数据映射到 `tag` 的对应字段。
///
/// 多值语义：同名字段**后者覆盖前者**（标签中同一字段出现多次属异常，
/// 取最后一个是可预期的确定行为）。
private func applyFrame(tag: Tag, major: Int64, frameId: String, data: Array<UInt8>): Unit {
    if (data.size == 0) {
        return
    }

    let id = normalizeFrameId(frameId, major)

    // ---- 封面（APIC / PIC）----
    if (id == "APIC") {
        parsePictureFrame(tag, data, major)
        return
    }

    // ---- 注释（COMM / COM）----
    if (id == "COMM") {
        parseCommentFrame(tag, data)
        return
    }

    // ---- 用户自定义文本（TXXX / TXX）----
    if (id == "TXXX") {
        parseTxxxFrame(tag, data)
        return
    }

    // ---- 标准文本帧：T 开头且长度为 4 ----
    if (id.size != 4 || !id.startsWith("T")) {
        return
    }

    let value = decodeTextFrame(data)
    if (value.isEmpty()) {
        return
    }

    if (id == "TIT2") {
        tag.title = value
    } else if (id == "TPE1") {
        tag.artist = value
    } else if (id == "TALB") {
        tag.album = value
    } else if (id == "TPE2") {
        tag.albumArtist = value
    } else if (id == "TDRC" || id == "TYER") {
        tag.year = value
    } else if (id == "TCON") {
        tag.genre = normalizeGenre(value)
    } else if (id == "TRCK") {
        let (cur, total) = parseNumberPair(value)
        tag.track = cur
        tag.trackTotal = total
    } else if (id == "TPOS") {
        let (cur, _) = parseNumberPair(value)
        tag.disc = cur
    } else if (id == "TCOM") {
        tag.composer = value
    } else {
        // 其余文本帧（TCOP / TPUB / TENC / …）进 extra 兜底
        tag.putExtra(id, value)
    }
}

// ---------------------------------------------------------------------------
// 各类帧的解析
// ---------------------------------------------------------------------------

/// 解析文本帧体：首字节为编码标识，其余为文本。
private func decodeTextFrame(data: Array<UInt8>): String {
    let enc = data[0]
    let body = safeSlice(data, 1, data.size - 1)
    decodeText(body, enc)
}

/// 解析 `COMM`：编码(1) + 语言(3) + 短描述(按编码终止) + 正文。
private func parseCommentFrame(tag: Tag, data: Array<UInt8>): Unit {
    if (data.size < 4) {
        return
    }
    let enc = data[0]
    let textStart = skipTerminatedText(data, 4, enc)
    if (textStart >= data.size) {
        return
    }
    let text = decodeText(safeSlice(data, textStart, data.size - textStart), enc)
    if (!text.isEmpty()) {
        tag.comment = text
    }
}

/// 解析 `TXXX`：编码(1) + 描述(按编码终止) + 值。结果写入 `extra`，键为 `"TXXX:<描述>"`。
private func parseTxxxFrame(tag: Tag, data: Array<UInt8>): Unit {
    if (data.size < 2) {
        return
    }
    let enc = data[0]
    let (desc, valueStart) = readTerminatedText(data, 1, enc)
    if (valueStart >= data.size) {
        return
    }
    let value = decodeText(safeSlice(data, valueStart, data.size - valueStart), enc)
    if (value.isEmpty()) {
        return
    }
    let key = if (desc.isEmpty()) {
        "TXXX"
    } else {
        "TXXX:" + desc
    }
    tag.putExtra(key, value)
}

/// 解析封面帧。
///
/// v2.3/2.4（`APIC`）：编码(1) + MIME(NUL 终止, Latin-1) + 图片类型(1) + 描述(按编码终止) + 图片数据
/// v2.2（`PIC`）：  编码(1) + 图片格式(3, 如 "JPG") + 图片类型(1) + 描述(按编码终止) + 图片数据
private func parsePictureFrame(tag: Tag, data: Array<UInt8>, major: Int64): Unit {
    if (data.size < 4) {
        return
    }

    let enc = data[0]
    var offset: Int64 = 1
    var mime = ""

    if (major == 2) {
        let fmt = decodeLatin1(safeSlice(data, offset, 3)).trimAscii().toAsciiUpper()
        offset += 3
        if (fmt == "JPG" || fmt == "JPEG") {
            mime = "image/jpeg"
        } else if (fmt == "PNG") {
            mime = "image/png"
        } else if (fmt == "GIF") {
            mime = "image/gif"
        } else if (!fmt.isEmpty()) {
            mime = "image/" + fmt.toAsciiLower()
        }
    } else {
        let mimeBytes = readUntilNul(data, offset)
        mime = decodeLatin1(mimeBytes)
        offset += mimeBytes.size + 1
    }

    // 图片类型（1 字节，0x03 = 封面，此处不区分）
    if (offset >= data.size) {
        return
    }
    offset += 1

    // 描述（按编码终止）
    offset = skipTerminatedText(data, offset, enc)
    if (offset >= data.size) {
        return
    }

    let art = safeSlice(data, offset, data.size - offset)
    if (art.size > 0) {
        tag.coverArt = art
        if (!mime.isEmpty()) {
            tag.coverMime = mime
        }
    }
}

// ---------------------------------------------------------------------------
// 字段值规范化
// ---------------------------------------------------------------------------

/// 把 v2.2 的 3 字符帧 ID 映射为 4 字符规范 ID（v2.3/2.4 无需映射）。
private func normalizeFrameId(id: String, major: Int64): String {
    if (major != 2) {
        return id
    }
    match (id) {
        case "TT2" => "TIT2"
        case "TT1" => "TIT1"
        case "TT3" => "TIT3"
        case "TP1" => "TPE1"
        case "TP2" => "TPE2"
        case "TAL" => "TALB"
        case "TYE" => "TYER"
        case "TCO" => "TCON"
        case "TRK" => "TRCK"
        case "TPA" => "TPOS"
        case "TCM" => "TCOM"
        case "TCR" => "TCOP"
        case "TPB" => "TPUB"
        case "TEN" => "TENC"
        case "TLA" => "TLAN"
        case "TLE" => "TLEN"
        case "TBP" => "TBPM"
        case "TSS" => "TSSE"
        case "TXT" => "TEXT"
        case "TXX" => "TXXX"
        case "COM" => "COMM"
        case "PIC" => "APIC"
        case _ => id
    }
}

/// 规范化流派值。
///
/// ID3v2 的 `TCON` 有三种历史写法，此处统一为流派名：
///   `"(17)"`  → 查 v1 流派表第 17 项
///   `"17"`    → 同上（纯数字亦视为索引）
///   `"Rock"`  → 原样返回
private func normalizeGenre(raw: String): String {
    let v = raw.trimAscii()
    if (v.isEmpty()) {
        return v
    }

    // "(17)" 形式
    if (v.startsWith("(")) {
        if (let Some(close) <- v.indexOf(")")) {
            let inner = v[1..close]
            if (let Some(idx) <- tryParseNonNegativeInt(inner)) {
                if (idx < ID3V1_GENRES.size) {
                    return ID3V1_GENRES[idx]
                }
            }
        }
    }

    // 纯数字形式
    if (let Some(idx) <- tryParseNonNegativeInt(v)) {
        if (idx < ID3V1_GENRES.size) {
            return ID3V1_GENRES[idx]
        }
    }

    v
}

// ---------------------------------------------------------------------------
// 字节辅助
// ---------------------------------------------------------------------------

/// 读取 3 字节大端无符号整数（v2.2 的帧长度字段）。
private func readUInt24BE(data: Array<UInt8>, offset: Int64): UInt32 {
    (UInt32(data[offset]) << 16) | (UInt32(data[offset + 1]) << 8) | UInt32(data[offset + 2])
}

/// 去除 ID3v2 的**非同步化**：把插入的 `0xFF 00` 还原为 `0xFF`。
///
/// 写入器为避开与 MPEG 帧同步字（0xFF Ex）冲突，会在 0xFF 后插入 0x00。
private func deUnsynchronise(data: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < data.size) {
        out.add(data[i])
        if (data[i] == 0xFFu8 && i + 1 < data.size && data[i + 1] == 0x00u8) {
            i += 2 // 跳过被插入的 0x00
        } else {
            i += 1
        }
    }
    out.toArray()
}

/// 从 `start` 起读取到第一个 `0x00` 为止的字节（**不含** NUL）。
private func readUntilNul(data: Array<UInt8>, start: Int64): Array<UInt8> {
    var end = start
    while (end < data.size && data[end] != 0u8) {
        end += 1
    }
    safeSlice(data, start, end - start)
}

/// 跳过一段「按编码终止」的文本，返回终止符**之后**的位置。
///
/// UTF-16 用双字节 0x0000 终止，单字节编码用 0x00 终止。
private func skipTerminatedText(data: Array<UInt8>, start: Int64, enc: UInt8): Int64 {
    var i = start
    if (enc == 1u8 || enc == 2u8) {
        while (i + 1 < data.size) {
            if (data[i] == 0u8 && data[i + 1] == 0u8) {
                return i + 2
            }
            i += 2
        }
        return data.size
    }
    while (i < data.size) {
        if (data[i] == 0u8) {
            return i + 1
        }
        i += 1
    }
    data.size
}

/// 读取一段「按编码终止」的文本，返回 `(文本, 终止符之后的位置)`。
private func readTerminatedText(data: Array<UInt8>, start: Int64, enc: UInt8): (String, Int64) {
    let isWide = (enc == 1u8 || enc == 2u8)
    var end = start

    if (isWide) {
        while (end + 1 < data.size) {
            if (data[end] == 0u8 && data[end + 1] == 0u8) {
                break
            }
            end += 2
        }
    } else {
        while (end < data.size && data[end] != 0u8) {
            end += 1
        }
    }

    let text = decodeText(safeSlice(data, start, end - start), enc)
    let next = if (isWide) {
        end + 2
    } else {
        end + 1
    }
    (text, next)
}
