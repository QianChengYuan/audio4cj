package audio4cj.meta

/* ============================================================================
 * FLAC 元数据块链解析 —— 开发文档 §10 M3（Vorbis comment 的容器接入）
 *
 * 结构：
 *
 *   "fLaC"(4)                  流标识
 *   元数据块序列（至少一个）：
 *     块头(4) = [1 字节：最高位 = 是否最后一块，低 7 位 = 块类型]
 *               [3 字节：块体长度，大端]
 *     块体(长度)
 *
 * 块类型：
 *   0 = STREAMINFO（必有，且必须是第一块）
 *   1 = PADDING       2 = APPLICATION   3 = SEEKTABLE
 *   4 = **VORBIS_COMMENT**（标签载体）  5 = CUESHEET   6 = PICTURE
 *
 * 本实现只关心类型 4（标签）与类型 6（封面，见下）。
 *
 * 输入约定：`data` 为**文件开头的一段字节**（从 "fLaC" 开始）。
 *   VORBIS_COMMENT 块按规范应出现在 STREAMINFO 之后、音频帧之前，
 *   因此取文件头部足够长度即可覆盖；若在给定范围内未找到，
 *   返回空 Tag（而不是报错 —— 该文件可能只是没有标签）。
 *
 * 未覆盖：PICTURE 块（类型 6）。它的结构与 ID3v2 的 APIC 不同
 *   （MIME 与描述均为 4 字节大端长度前缀），留待 M4 与 FLAC 解码一并实现。
 * ========================================================================== */

/// FLAC 元数据块链的遍历上限（防畸形数据造成长循环）。
private let MAX_FLAC_BLOCKS: Int64 = 1024

/// 解析 FLAC 元数据块链，提取标签。
///
/// - `data`：文件开头从 "fLaC" 开始的字节
/// - 返回：从 `VORBIS_COMMENT` 块解析出的 `Tag`；无该块或结构非法时返回**空 Tag**
protected func parseFlacMetadata(data: Array<UInt8>): Tag {
    if (data.size < 4) {
        return Tag()
    }
    if (!matchAsciiAt(data, 0, "fLaC")) {
        return Tag()
    }

    var offset: Int64 = 4
    var guard: Int64 = 0

    while (offset + 4 <= data.size) {
        guard += 1
        if (guard > MAX_FLAC_BLOCKS) {
            break
        }

        let head = data[offset]
        let isLast = (head & 0x80u8) != 0u8
        let blockType = Int64(head & 0x7Fu8)

        // 块头长度字段为 3 字节大端
        let len = (Int64(data[offset + 1]) << 16) | (Int64(data[offset + 2]) << 8) | Int64(data[offset + 3])

        let bodyStart = offset + 4
        if (len < 0 || bodyStart + len > data.size) {
            // 块体超出已读取范围：可能是读取窗口太小，也可能是文件损坏
            break
        }

        // 类型 4 = VORBIS_COMMENT
        if (blockType == 4) {
            return parseVorbisComment(safeSlice(data, bodyStart, len))
        }

        if (isLast) {
            break
        }
        offset = bodyStart + len
    }

    Tag()
}
