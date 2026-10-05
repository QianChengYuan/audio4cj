package audio4cj.meta

import std.fs.*
import std.io.*

/* ============================================================================
 * 文件级标签读取 —— meta 层中**唯一执行 I/O 的文件**
 *
 * 【为什么在这里破例做 I/O】
 *   本层其余文件一律保持「纯解析」：只接收字节数组、输出 Tag，不碰文件，
 *   以便用内存构造的数据做自包含测试。但「从文件里把标签读出来」本身就是
 *   元数据职责，且这份逻辑被三个调用方共同需要：
 *     facade.AudioFile.readTags —— 无需解码即可读标签的入口
 *     format.Mp3FormatReader.metadata
 *     format.FlacFormatReader.metadata
 *   而 format 不能依赖 facade（会形成循环），故必须位于两者都能依赖的位置。
 *   把 I/O 集中在这一个文件，是权衡后的有意识例外。
 *
 * 依赖方向：本文件依赖 meta 的纯解析器（parseId3v2 / parseId3v1 /
 *   parseFlacMetadata / mergeTags），后者仍保持零 I/O。
 * ========================================================================== */

/// FLAC 元数据块扫描窗口（256 KB）。
///
/// VORBIS_COMMENT 块按规范紧随 STREAMINFO 之后，读取文件头部一段即可覆盖；
/// 即使其间夹杂较大的 PADDING 块，256 KB 也足够。超出窗口视为无标签。
protected let FLAC_SCAN_LIMIT: Int64 = 256 * 1024

/// 读取文件头部的 ID3v2 标签。
///
/// 先读 10 字节标签头取得 synchsafe 长度，再**只读取该长度的字节** ——
/// 不会把整个音频文件读入内存。长度来自文件内容（不可信），
/// 因此按 `ID3V2_MAX_TAG_SIZE` 截断。
protected func readId3v2FromFile(path: String): Tag {
    var result = Tag()

    try (f = File(path, Read)) {
        let header = Array<UInt8>(10, repeat: 0)
        let gotHeader = f.read(header)

        if (gotHeader >= 10) {
            match (id3v2TotalSize(header)) {
                case Some(total) =>
                    if (total > 10) {
                        var limit = total
                        if (limit > ID3V2_MAX_TAG_SIZE) {
                            limit = ID3V2_MAX_TAG_SIZE
                        }
                        let bytes = Array<UInt8>(limit, repeat: 0)
                        f.seek(SeekPosition.Begin(0))
                        let got = f.read(bytes)
                        if (got >= 10) {
                            result = parseId3v2(safeSlice(bytes, 0, got))
                        }
                    }
                case None => ()
            }
        }
    }

    result
}

/// 读取文件**末尾 128 字节**的 ID3v1 标签。
protected func readId3v1FromFile(path: String): Tag {
    var result = Tag()

    try (f = File(path, Read)) {
        // 用 Seekable.length 取文件长度，避免把整个文件读入内存
        if (f.length >= ID3V1_SIZE) {
            f.seek(SeekPosition.End(-ID3V1_SIZE))
            let tail = Array<UInt8>(ID3V1_SIZE, repeat: 0)
            let got = f.read(tail)
            if (got >= ID3V1_SIZE) {
                result = parseId3v1(tail)
            }
        }
    }

    result
}

/// MP3 标签：ID3v2（文件头）优先，其空字段由 ID3v1（文件尾）逐字段回填。
protected func readMp3TagsFromFile(path: String): Tag {
    mergeTags(readId3v2FromFile(path), readId3v1FromFile(path))
}

/// FLAC 标签：读取文件头部窗口内的元数据块链，取 `VORBIS_COMMENT` 块。
protected func readFlacTagsFromFile(path: String): Tag {
    var result = Tag()

    try (f = File(path, Read)) {
        let head = Array<UInt8>(FLAC_SCAN_LIMIT, repeat: 0)
        let got = f.read(head)
        if (got > 0) {
            result = parseFlacMetadata(safeSlice(head, 0, got))
        }
    }

    result
}

/// OGG 标签扫描窗口（256 KB）。
///
/// 注释头紧随首个页面的识别头之后，读取文件头部一段即可覆盖。与 FLAC 采用
/// 同一量级、同一理由：即使注释头之前夹杂较大的块也够用，而超出窗口通常
/// 意味着数据异常（或封面被内嵌成超大块），此时宁可取不到标签也不无限读下去。
protected let OGG_SCAN_LIMIT: Int64 = 256 * 1024

/// OGG 标签：页重组取出注释头，再按子编码分派给 Vorbis comment 或 FLAC 块链解析。
///
/// 注意 OGG 的标签**不在文件固定偏移上**，而是散落在最前几个 Ogg 页面里，
/// 因此必须做页重组（见 ogg_page.cj）。任意子编码认不出、无注释头、
/// 结构非法时都返回**空 Tag**，不抛异常。
protected func readOggTagsFromFile(path: String): Tag {
    var result = Tag()

    try (f = File(path, Read)) {
        let head = Array<UInt8>(OGG_SCAN_LIMIT, repeat: 0)
        let got = f.read(head)
        if (got > 0) {
            result = parseOggTags(safeSlice(head, 0, got))
        }
    }

    result
}

/// MP4 头部扫描窗口（64 KB）。
///
/// `ftyp` 与「做过 faststart 优化」的 `moov` 都位于文件前部，64 KB 足够。
private let MP4_HEAD_LIMIT: Int64 = 64 * 1024

/// MP4 尾部扫描窗口（1 MB）。
///
/// 未做 faststart 的 MP4 会把 `moov` 放在**文件末尾** —— 这是 主流封装工具的默认行为
/// 行为，在下载得到的 MP4 里也相当常见。`moov` 自身可能因数百 KB 的封面而偏大，
/// 故尾部窗口取得比头部大。
private let MP4_TAIL_LIMIT: Int64 = 1024 * 1024

/// MP4 标签：定位 `moov / udta / meta / ilst`，把各原子映射到 `Tag`。
///
/// `moov` 的位置**不固定**，因此这里分两步找：
///
///   1. **头部窗口**：正向走顶层 box 链找 `moov`（做过 faststart 的文件在此命中）；
///   2. 若没找到，再取**尾部窗口**，找「size 恰好使其结束于文件末尾」的 `moov`
///      （未做 faststart 的文件在此命中 —— 主流封装工具的默认行为即是这种布局）。
///
/// 两步都失败即返回空 Tag。这里刻意**不做全文件扫描**：`moov` 是单个 box，
/// 必然整体落在文件头或文件尾，读两个窗口即可覆盖，且开销与文件大小无关。
protected func readMp4TagsFromFile(path: String): Tag {
    var result = Tag()

    try (f = File(path, Read)) {
        let size = f.length

        // ---- 1. 头部窗口 ----
        let headLen = if (size < MP4_HEAD_LIMIT) {
            size
        } else {
            MP4_HEAD_LIMIT
        }
        if (headLen > 0) {
            let head = Array<UInt8>(headLen, repeat: 0)
            let got = f.read(head)
            let win = safeSlice(head, 0, got)
            match (mp4FindMoov(win)) {
                case Some(m) => result = parseMp4Tags(win, m)
                case None => ()
            }
        }

        // ---- 2. 尾部窗口（仅当头部未命中，且文件长于头部窗口）----
        if (result.hasNoStandardFields() && size > MP4_HEAD_LIMIT) {
            let tailLen = if (size < MP4_TAIL_LIMIT) {
                size
            } else {
                MP4_TAIL_LIMIT
            }
            let tail = Array<UInt8>(tailLen, repeat: 0)
            f.seek(SeekPosition.End(-tailLen))
            let got = f.read(tail)
            let win = safeSlice(tail, 0, got)
            match (mp4FindTrailingMoov(win)) {
                case Some(m) => result = parseMp4Tags(win, m)
                case None => ()
            }
        }
    }

    result
}
