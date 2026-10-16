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
 * 封面：`METADATA_BLOCK_PICTURE` 是 base64 编码的 FLAC PICTURE 块，已支持
 *   （解码与结构解析在 picture.cj，与 FLAC 元数据块类型 6 共用同一份实现）。
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
    } else if (key == "DISCTOTAL" || key == "TOTALDISCS") {
        let (cur, _) = parseNumberPair(value)
        tag.discTotal = cur
    } else if (key == "COMMENT" || key == "DESCRIPTION") {
        tag.comment = value
    } else if (key == "LYRICS" || key == "UNSYNCEDLYRICS") {
        tag.lyrics = value
    } else if (key == "COMPOSER") {
        tag.composer = value
    } else if (key == "METADATA_BLOCK_PICTURE") {
        // 封面：base64 编码的 FLAC PICTURE 块。解码与结构解析都在 picture.cj，
        // 与 FLAC 文件里真正的 PICTURE 块（元数据块类型 6）共用同一份实现。
        //
        // 解析失败（非法 base64、结构越界、MIME 为 "-->"）时静默跳过。
        // 注意**不能**把原值放进 extra：一张普通封面 base64 之后可达数十至
        // 数百 KB，塞进 extra 会让 Tag 体量失控；它对使用者也没有可用的文本语义。
        applyPictureEntry(tag, value)
    } else {
        // 冷门字段（ENCODER / PERFORMER / COPYRIGHT / …）进 extra 兜底
        tag.putExtra(key, value)
    }
}

/// 处理 `METADATA_BLOCK_PICTURE` 条目：base64 解码 → 解析 PICTURE 块 → 填封面。
///
/// 同一块内出现多条时**先到者胜**（与其余字段"后者覆盖前者"不同：封面是
/// 大对象，取第一条可解析的即可，避免后续条目反复覆盖造成无谓开销）。
private func applyPictureEntry(tag: Tag, value: String): Unit {
    if (tag.coverArt.isSome()) {
        return
    }
    if (let Some(raw) <- base64Decode(value)) {
        if (let Some(pic) <- parseFlacPictureBlock(raw)) {
            tag.coverArt = Some(pic.data)
            if (pic.mime.size > 0) {
                tag.coverMime = Some(pic.mime)
            }
        }
    }
}
