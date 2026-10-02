package audio4cj.meta

import audio4cj.pcm.readUInt32LE

/* ============================================================================
 * WAV LIST/INFO 子块解析 —— 开发文档 §10 M3（补 M2 遗留占位）
 *
 * 结构：
 *
 *   LIST 块体 = "INFO"(4 字节标识) + 若干子块
 *   子块      = ID(4) + size(4, 小端) + 数据(size 字节) + 填充(size 为奇数时补 1 字节)
 *
 * 用途：WAV 文件的常见标签载体（RIFF INFO 标签集），
 *   与 `fmt` / `data` chunk 并列存在于 RIFF 结构中。
 *
 * 编码：RIFF INFO **无标准编码规定**。实践中以 ASCII / Latin-1 为主，
 *   少数写入器使用 UTF-8。本实现采用**容错策略**：先校验 UTF-8，
 *   失败则退回 Latin-1（见 `decodeUtf8Safe`），不会因编码问题丢弃字段。
 *
 * 输入约定：`listBody` 为 **LIST chunk 的块体**（即 chunk 头 8 字节之后的部分），
 *   可含也可不含开头的 "INFO" 标识 —— 本函数自动识别并跳过。
 * ========================================================================== */

/// INFO 子块的处理上限（防畸形数据造成长循环）。
private let MAX_WAV_INFO_SUBCHUNKS: Int64 = 4096

/// 解析 RIFF `LIST/INFO` 块体。
///
/// - `listBody`：LIST chunk 的块体（"INFO" 标识之后的部分，或含该标识）
/// - 返回：解析出的 `Tag`；结构非法时返回**空 Tag**（无标签不是错误）
///
/// 已映射字段见 `applyInfoField`，其余子块进 `extra`（键为原始 4 字符子块 ID，
/// 如 `"ISFT"`（编码软件）、`"IENG"`（工程师））。
protected func parseWavInfo(listBody: Array<UInt8>): Tag {
    let tag = Tag()

    var offset: Int64 = 0
    // LIST 的类型标识为 "INFO" 时才按 INFO 子块解析
    if (matchAsciiAt(listBody, 0, "INFO")) {
        offset = 4
    }

    var guard: Int64 = 0
    while (offset + 8 <= listBody.size) {
        guard += 1
        if (guard > MAX_WAV_INFO_SUBCHUNKS) {
            break
        }

        let id = decodeLatin1(safeSlice(listBody, offset, 4))
        let size = Int64(readUInt32LE(listBody, offset + 4))
        let bodyStart = offset + 8

        if (size < 0 || bodyStart + size > listBody.size) {
            break
        }

        if (size > 0) {
            let value = decodeInfoText(safeSlice(listBody, bodyStart, size))
            if (!value.isEmpty()) {
                applyInfoField(tag, id, value)
            }
        }

        // 奇数长度后有 1 字节填充（与 RIFF chunk 规则一致）
        offset = bodyStart + size + (size % 2)
    }

    tag
}

/// 解码 INFO 子块文本：去 NUL 终止与尾部空白填充后，按容错策略解码。
private func decodeInfoText(data: Array<UInt8>): String {
    let body = trimTrailingPadding(truncateAtNulByte(data))
    decodeUtf8Safe(body)
}

/// 把单个 INFO 子块映射到 `tag`。
///
/// 子块 ID 依据 RIFF INFO 标签集的通行用法；
/// 同一语义存在多个 ID 时（如专辑的 `IPRD` / `IALB`）一并接受。
private func applyInfoField(tag: Tag, id: String, value: String): Unit {
    if (id == "INAM") {
        tag.title = value
    } else if (id == "IART") {
        tag.artist = value
    } else if (id == "IPRD" || id == "IALB") {
        tag.album = value
    } else if (id == "ICRD") {
        tag.year = value
    } else if (id == "IGNR") {
        tag.genre = value
    } else if (id == "ICMT") {
        tag.comment = value
    } else if (id == "ITRK" || id == "IPRT") {
        let (cur, total) = parseNumberPair(value)
        tag.track = cur
        tag.trackTotal = total
    } else if (id == "IMUS") {
        tag.composer = value
    } else {
        // ISFT / IENG / ICOP / IKEY / ISBJ / … 一律进 extra 兜底
        tag.putExtra(id, value)
    }
}
