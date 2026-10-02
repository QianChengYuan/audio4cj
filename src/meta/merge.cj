package audio4cj.meta

/* ============================================================================
 * 多标签体系合并 —— 开发文档 §10 M3
 *
 * 同一文件可能同时存在多套标签，最常见的是 MP3 既有 ID3v2（文件头）又有
 * ID3v1（文件尾 128 字节）。
 *
 * 合并规则：**逐字段回填**
 *   - 主体系（primary）的非空字段优先；
 *   - 主体系为 None 的字段，用备用体系（fallback）补齐。
 *
 * 为什么不整体二选一：实践中常见 ID3v2 只写了标题，而 ID3v1 反而带着
 * 完整的艺术家与专辑 —— 整体择一会白丢信息，逐字段回填才能拿到最大信息量。
 *
 * 两侧都没有的字段保持 None（符合"None 只表示该字段不存在"的契约）。
 * ========================================================================== */

/// 合并两个标签：`primary` 优先，为空时用 `fallback` 补齐。
///
/// 返回**新的 `Tag` 实例**，不修改任一入参。
/// `extra` 的合并同样遵循 primary 优先（同键时 primary 的值胜出）。
protected func mergeTags(primary: Tag, fallback: Tag): Tag {
    let out = Tag()

    out.title = primary.title ?? fallback.title
    out.artist = primary.artist ?? fallback.artist
    out.album = primary.album ?? fallback.album
    out.albumArtist = primary.albumArtist ?? fallback.albumArtist
    out.year = primary.year ?? fallback.year
    out.genre = primary.genre ?? fallback.genre
    out.track = primary.track ?? fallback.track
    out.trackTotal = primary.trackTotal ?? fallback.trackTotal
    out.disc = primary.disc ?? fallback.disc
    out.comment = primary.comment ?? fallback.comment
    out.composer = primary.composer ?? fallback.composer
    out.coverArt = primary.coverArt ?? fallback.coverArt
    out.coverMime = primary.coverMime ?? fallback.coverMime

    // extra：先铺 fallback，再用 primary 覆盖同键
    for ((k, v) in fallback.extra) {
        out.extra[k] = v
    }
    for ((k, v) in primary.extra) {
        out.extra[k] = v
    }

    out
}
