package audio4cj.meta

import audio4cj.pcm.readUInt32LE

/* ============================================================================
 * Vorbis comment 解析 —— 开发文档 §10 M3
 *
 * 结构（**全部小端**）：
 *
 *   [4] vendor 字符串长度
 *   [n] vendor 字符串（UTF-8，通常为编码器标识）
 *   [4] 注释条目数
 *   重复「条目数」次：
 *     [4] 条目长度
 *     [m] 条目内容（UTF-8，形如 "KEY=value"）
 *
 * 用途：FLAC 的 VORBIS_COMMENT 元数据块（M4 接入）与 OGG 的 comment header。
 *   本文件只做**纯解析**，输入为块内容字节，**不含** FLAC / OGG 的容器头部，
 *   因此可在 M3 独立完成并直接用内存构造的数据测试。
 *
 * 规范要点：
 *   - 字段名**不区分大小写**，本实现统一按大写匹配；
 *   - 字段值为 UTF-8；条目内除第一个 '=' 外，'=' 属于值的一部分；
 *   - 条目顺序不保证，同名条目可重复（本实现为后者覆盖前者）。
 *
 * 未覆盖：`METADATA_BLOCK_PICTURE`（FLAC 的 base64 封面）留待 M4 —— 它需要
 *   base64 解码与 PICTURE 块结构解析，属封面专项工作。
 * ========================================================================== */

/// Vorbis comment 条目数的处理上限（防畸形数据造成长循环）。
private let MAX_VORBIS_COMMENTS: Int64 = 4096

/// 解析 Vorbis comment 块。
///
/// - `block`：Vorbis comment 块的内容字节（不含容器头部）
/// - 返回：解析出的 `Tag`；结构非法时返回**空 Tag**（无标签不是错误）
///
/// 已映射字段见 `applyVorbisEntry`，其余条目进 `extra`（键为**大写**字段名）。
protected func parseVorbisComment(block: Array<UInt8>): Tag {
    let tag = Tag()
    if (block.size < 8) {
        return tag
    }

    // ---- 跳过 vendor 字符串 ----
    let vendorLen = Int64(readUInt32LE(block, 0))
    if (vendorLen < 0) {
        return tag
    }
    var offset = 4 + vendorLen
    if (offset + 4 > block.size) {
        return tag
    }

    // ---- 条目数 ----
    let count = Int64(readUInt32LE(block, offset))
    offset += 4
    if (count <= 0) {
        return tag
    }

    // ---- 逐条解析 ----
    var i: Int64 = 0
    while (i < count && offset + 4 <= block.size) {
        if (i > MAX_VORBIS_COMMENTS) {
            break
        }

        let len = Int64(readUInt32LE(block, offset))
        offset += 4
        if (len < 0 || offset + len > block.size) {
            break
        }

        let entry = decodeUtf8Safe(safeSlice(block, offset, len))
        offset += len

        applyVorbisEntry(tag, entry)
        i += 1
    }

    tag
}

/// 把单条 `"KEY=value"` 条目映射到 `tag`。
private func applyVorbisEntry(tag: Tag, entry: String): Unit {
    let s = entry.trimAscii()
    if (s.isEmpty()) {
        return
    }

    // 只在**第一个** '=' 处拆分：值本身可能含 '='
    let kv = match (s.indexOf("=")) {
        case Some(idx) => (s[0..idx].trimAscii().toAsciiUpper(), s[idx + 1..].trimAscii())
        case None => ("", "")
    }
    let key = kv[0]
    let value = kv[1]
    if (key.isEmpty() || value.isEmpty()) {
        return
    }

    if (key == "TITLE") {
        tag.title = value
    } else if (key == "ARTIST") {
        tag.artist = value
    } else if (key == "ALBUM") {
        tag.album = value
    } else if (key == "ALBUMARTIST" || key == "ALBUM ARTIST") {
        tag.albumArtist = value
    } else if (key == "DATE" || key == "YEAR") {
        tag.year = value
    } else if (key == "GENRE") {
        tag.genre = value
    } else if (key == "TRACKNUMBER" || key == "TRACK") {
        let (cur, total) = parseNumberPair(value)
        tag.track = cur
        tag.trackTotal = total
    } else if (key == "DISCNUMBER" || key == "DISC") {
        let (cur, _) = parseNumberPair(value)
        tag.disc = cur
    } else if (key == "COMMENT" || key == "DESCRIPTION") {
        tag.comment = value
    } else if (key == "COMPOSER") {
        tag.composer = value
    } else if (key == "METADATA_BLOCK_PICTURE") {
        // 封面：base64 编码的 FLAC PICTURE 块。解析它需要 base64 解码与
        // PICTURE 块结构支持，尚未实现（见文件头"未覆盖"）。
        //
        // 此处**显式跳过**而不是放进 extra：一张普通封面 base64 之后可达
        // 数十至数百 KB，塞进 extra 会让 Tag 体量失控；而它对使用者也没有
        // 任何可用的文本语义。宁可留空，也不要塞一个巨型不可用字符串。
        ()
    } else {
        // 冷门字段（ENCODER / PERFORMER / COPYRIGHT / …）进 extra 兜底
        tag.putExtra(key, value)
    }
}
