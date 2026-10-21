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
 *   4 = **VORBIS_COMMENT**（标签载体）  5 = CUESHEET   6 = **PICTURE**（封面）
 *
 * 本实现关心类型 4（标签）与类型 6（封面）；其余块只按长度跳过。
 *
 * 输入约定：`data` 为**文件开头的一段字节**（从 "fLaC" 开始）。
 *   VORBIS_COMMENT / PICTURE 按规范应出现在 STREAMINFO 之后、音频帧之前，
 *   因此取文件头部足够长度即可覆盖；若在给定范围内未找到，
 *   返回空 Tag（而不是报错 —— 该文件可能只是没有标签）。
 *
 * 封面优先级：Vorbis comment 的 `METADATA_BLOCK_PICTURE`（注释头在块链里通常
 *   在前，且是用户显式嵌入的那一份）优先，PICTURE 块只**补空**；同一文件有
 *   多个 PICTURE 块时，front cover（图片类型 3）优先于其他类型，
 *   同类型则先到者胜。两条载体都走 `parseFlacPictureBlock`（picture.cj）。
 * ========================================================================== */

/// FLAC 元数据块链的遍历上限（防畸形数据造成长循环）。
private let MAX_FLAC_BLOCKS: Int64 = 1024

/// 封面优先选择的图片类型：FLAC 规范里 3 = Cover (front)。
protected let FLAC_PICTURE_TYPE_FRONT: Int64 = 3

/// 解析 FLAC 元数据块链，提取标签与封面。
///
/// - `data`：文件开头从 "fLaC" 开始的字节
/// - 返回：`VORBIS_COMMENT` 块解析出的 `Tag`（含 `PICTURE` 块补入的封面）；
///   两块皆无或结构非法时返回**空 Tag**
protected func parseFlacMetadata(data: Array<UInt8>): Tag {
    var tag = Tag()
    if (data.size < 4) {
        return tag
    }
    if (!matchAsciiAt(data, 0, "fLaC")) {
        return tag
    }

    var sawVorbisComment = false
    var bestPicture: ?FlacPicture = None
    var bestIsFront = false

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

        // 类型 4 = VORBIS_COMMENT（只认第一块）
        if (blockType == 4 && !sawVorbisComment) {
            sawVorbisComment = true
            tag = parseVorbisComment(safeSlice(data, bodyStart, len))
        } else if (blockType == 6) {
            // 多块时优先 front cover，同类型先到者胜
            if (let Some(pic) <- parseFlacPictureBlock(safeSlice(data, bodyStart, len))) {
                let isFront = pic.picType == FLAC_PICTURE_TYPE_FRONT
                if (bestPicture.isNone() || (isFront && !bestIsFront)) {
                    bestPicture = Some(pic)
                    bestIsFront = isFront
                }
            }
        }

        if (isLast) {
            break
        }
        offset = bodyStart + len
    }

    // PICTURE 块只为空封面兜底：注释头里的 METADATA_BLOCK_PICTURE 优先
    if (tag.coverArt.isNone()) {
        if (let Some(pic) <- bestPicture) {
            tag.coverArt = Some(pic.data)
            if (pic.mime.size > 0) {
                tag.coverMime = Some(pic.mime)
            }
        }
    }

    tag
}
