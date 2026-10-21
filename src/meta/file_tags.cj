package audio4cj.meta

import std.collection.ArrayList
import std.fs.*
import std.io.*
import audio4cj.core.Audio4CjException

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
 *
 * 标签写入（v0.2.0）：MP3 的「安全子集」写入也集中在本文件 ——
 *   与读取同一条 I/O 集中纪律。写入 = 读全文件 → 剥旧 ID3v2 → 新标签前置
 *   → 原子落盘（先写临时文件再换名）。音频帧与 APEv2 / ID3v1 尾部**原样保留**。
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

/// MP3 标签：ID3v2（文件头）> APEv2（文件尾，v0.1.6 起支持）> ID3v1（文件尾 128 字节），
/// 逐字段回填（primary 优先、fallback 补空）。
protected func readMp3TagsFromFile(path: String): Tag {
    var head = Array<UInt8>()
    var tail = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        // 头窗口：覆盖完整 ID3v2（上限 ID3V2_MAX_TAG_SIZE）
        let headLen = if (size < ID3V2_MAX_TAG_SIZE) {
            size
        } else {
            ID3V2_MAX_TAG_SIZE
        }
        if (headLen > 0) {
            let hb = Array<UInt8>(headLen, repeat: 0)
            let got = f.read(hb)
            head = safeSlice(hb, 0, got)
        }
        // 尾窗口：覆盖 APEv2 扫描窗（APE_SCAN_LIMIT）；ID3v1 的 128 字节必然在内
        let tailLen = if (size < APE_SCAN_LIMIT) {
            size
        } else {
            APE_SCAN_LIMIT
        }
        if (tailLen > 0) {
            f.seek(SeekPosition.End(-tailLen))
            let tb = Array<UInt8>(tailLen, repeat: 0)
            let got = f.read(tb)
            tail = safeSlice(tb, 0, got)
        }
    }
    mp3TagsFromWindows(head, tail)
}

/// 从「文件头部窗口 + 尾部窗口」解析 MP3 的三段标签（ID3v2 / APEv2 / ID3v1）。
///
/// 窗口约定：
///   - `head`：文件**开头**的连续字节（长度任意；ID3v2 判定用前 10 字节，
///     标签体超过窗口长度时按窗口截断 —— 与文件级读取的 16 MB 上限口径一致）；
///   - `tail`：文件**末尾**的连续字节（APEv2 扫描 + ID3v1 的载体；长度不足
///     时相应标签自然落空）。
///
/// 这是纯函数 —— 文件级读取（readMp3TagsFromFile）与内存源读取（MP3 reader
/// 的 `metadata()`，见 ByteSource 泛化）共用同一份实现，保证两条路径行为一致。
protected func mp3TagsFromWindows(head: Array<UInt8>, tail: Array<UInt8>): Tag {
    mergeTags(id3v2TagFromHeadWindow(head), mergeTags(apev2TagFromTailWindow(tail), id3v1TagFromTailWindow(tail)))
}

/// 从文件头部窗口解析 ID3v2；无标签（或头部非法）返回空 Tag。
///
/// 与 readId3v2FromFile 的窗口内逻辑一致：前 10 字节判头、长度按
/// ID3V2_MAX_TAG_SIZE 截断。窗口比标签声明短时按窗口可得的字节解析
/// （结构损坏的报错口径由 parseId3v2 决定，与文件级路径相同）。
protected func id3v2TagFromHeadWindow(head: Array<UInt8>): Tag {
    var result = Tag()
    if (head.size < 10) {
        return result
    }
    match (id3v2TotalSize(head)) {
        case Some(total) =>
            if (total > 10) {
                var limit = total
                if (limit > head.size) {
                    limit = head.size
                }
                if (limit > ID3V2_MAX_TAG_SIZE) {
                    limit = ID3V2_MAX_TAG_SIZE
                }
                result = parseId3v2(safeSlice(head, 0, limit))
            }
        case None => ()
    }
    result
}

/// 从文件尾部窗口解析 ID3v1；末 128 字节不含 "TAG" 标识返回空 Tag。
protected func id3v1TagFromTailWindow(tail: Array<UInt8>): Tag {
    var result = Tag()
    if (tail.size < ID3V1_SIZE) {
        return result
    }
    result = parseId3v1(safeSlice(tail, tail.size - ID3V1_SIZE, ID3V1_SIZE))
    result
}

// ---------------------------------------------------------------------------
// 标签写入（安全子集，v0.2.0）：目前仅 MP3 / ID3v2.3
// ---------------------------------------------------------------------------

/// 计算 MP3 文件中**旧 ID3v2 标签的总字节数**（无标签或头部非法为 0）。
///
/// 只读 10 字节头部即可判定；长度字段不可信，按 ID3V2_MAX_TAG_SIZE 截断，
/// 超限视为结构异常（返回 0 会把超限标签当音频保留 —— 但 16 MB 的"标签"
/// 几乎必然是探测误判或损坏，此时写入器宁可把新标签前置、旧块原样保留，
/// 也不去冒剥错字节的险）。
private func oldId3v2SizeAtHead(f: File): Int64 {
    let header = Array<UInt8>(10, repeat: 0)
    let got = f.read(header)
    if (got < 10) {
        return 0
    }
    match (id3v2TotalSize(header)) {
        case Some(total) =>
            if (total > 10 && total <= ID3V2_MAX_TAG_SIZE) {
                total
            } else {
                0
            }
        case None => 0
    }
}

/// 把 `tag` 写入 MP3 文件（ID3v2.3，安全子集）。
///
/// 流程：读全文件 → 剥掉头部旧 ID3v2 → 新标签前置 → 写临时文件 → 原子换名。
/// 音频帧、APEv2 与 ID3v1 尾部字节**逐位保留**。
///
/// 抛出：
///   - 文件不存在 / 无权限 → `std.fs` 的 `FSException`
///   - 标签体序列化后超过 ID3V2_MAX_TAG_SIZE → `Audio4CjException`
///   - 临时文件写入或换名失败 → 底层 `FSException`（此时原文件未被触碰）
protected func writeMp3TagsToFile(path: String, tag: Tag): Unit {
    let newTagBytes = serializeId3v23(tag)
    if (Int64(newTagBytes.size) > ID3V2_MAX_TAG_SIZE) {
        throw Audio4CjException(
            "ID3v2.3 标签序列化结果超出上限（${newTagBytes.size} > ${ID3V2_MAX_TAG_SIZE}）：${path}")
    }

    // 读全文件。MP3 典型体积（数 MB ~ 数十 MB）可接受；标签写入本就是
    // 重写头部 + 平移后续字节的操作，不做全文件读写的原地方案需要
    // 逐段搬移，复杂度收益不匹配（安全子集原则：先做对）。
    var rest = Array<UInt8>()
    try (f = File(path, Read)) {
        let oldSize = oldId3v2SizeAtHead(f)
        f.seek(SeekPosition.Begin(oldSize))
        let remaining = f.length - oldSize
        if (remaining > 0) {
            let buf = Array<UInt8>(remaining, repeat: 0)
            let got = f.read(buf)
            rest = safeSlice(buf, 0, got)
        }
    }

    let out = ArrayList<UInt8>()
    for (b in newTagBytes) {
        out.add(b)
    }
    for (b in rest) {
        out.add(b)
    }

    // 原子落盘：临时文件写完后换名覆盖，任何一步失败原文件都完整保留
    let tmpPath = "${path}.a4cj_tmp"
    try (f = File(tmpPath, Write)) {
        f.write(out.toArray())
    }
    rename(Path(tmpPath), to: Path(path), overwrite: true)
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

// ---------------------------------------------------------------------------
// FLAC 标签写入 —— 审查改进方向 3.4 第二步（v0.2.0）
// ---------------------------------------------------------------------------

/// FLAC 元数据块链遍历上限（与 flac.cj 的 MAX_FLAC_BLOCKS 同口径）。
private let FLAC_WRITE_MAX_BLOCKS: Int64 = 1024

/// FLAC 块链头部的字节量："fLaC" + 至少一个 STREAMINFO 块（4 头 + 34 体）。
private let FLAC_MIN_HEAD_BYTES: Int64 = 42

/// 把 `tag` 写入 FLAC 文件（Vorbis comment，安全子集）。
///
/// 流程：读全文件 → 走头部块链，**逐位保留**全部既有块（STREAMINFO /
/// SEEKTABLE / PICTURE / PADDING / …），只剥掉旧 VORBIS_COMMENT；
/// 然后拼接：保留块（修正 isLast 标志）+ 新 VORBIS_COMMENT + 音频帧字节
/// → 写临时文件 → 原子换名。
///
/// 封面策略：经新 Vorbis comment 的 `METADATA_BLOCK_PICTURE` 条目携带
/// （base64）。文件里既有的独立 PICTURE 块**原样保留** —— 读侧约定注释头
/// 优先、PICTURE 只补空，因此新注释头的封面会生效，旧封面成为兜底；
/// 这样避免"写入器擅自删除用户既有块"的副作用（与 MP3 写入器保留 APEv2 /
/// ID3v1 尾部同一原则）。
///
/// SEEKTABLE 平移安全性：定位点的 stream_offset 是**相对首个音频帧**的
/// 字节偏移（flac_meta.cj），头部变长/变短不影响其正确性。
///
/// 抛出：
///   - 非 FLAC 文件（缺 "fLaC" 或块链损坏）→ `Audio4CjException`
///   - 文件不存在 / 无权限 → `std.fs` 的 `FSException`
///   - 临时文件写入或换名失败 → 底层 `FSException`（此时原文件未被触碰）
protected func writeFlacTagsToFile(path: String, tag: Tag): Unit {
    var data: Array<UInt8> = Array<UInt8>()
    try (f = File(path, Read)) {
        let buf = Array<UInt8>(f.length, repeat: 0)
        let got = f.read(buf)
        data = safeSlice(buf, 0, got)
    }

    if (data.size < FLAC_MIN_HEAD_BYTES || !matchAsciiAt(data, 0, "fLaC")) {
        throw Audio4CjException("FLAC 标签写入：文件缺少合法的块链头（${path}）")
    }

    // ---- 走块链，收集保留块与音频起点 ----
    let keptBlocks = ArrayList<UInt8>()
    var audioStart: Int64 = -1
    var offset: Int64 = 4
    var guardCounter: Int64 = 0

    while (offset + 4 <= data.size) {
        guardCounter += 1
        if (guardCounter > FLAC_WRITE_MAX_BLOCKS) {
            throw Audio4CjException("FLAC 标签写入：块链超出遍历上限（${path}）")
        }

        let head = data[offset]
        let isLast = (head & 0x80u8) != 0u8
        let blockType = head & 0x7Fu8
        let len = (Int64(data[offset + 1]) << 16) | (Int64(data[offset + 2]) << 8) | Int64(data[offset + 3])
        let bodyStart = offset + 4
        if (bodyStart + len > data.size) {
            throw Audio4CjException("FLAC 标签写入：块体越界（偏移 ${offset}，${path}）")
        }

        if (isLast) {
            // 原块链的终点：其块体结束后就是音频帧区
            if (blockType != 4u8) {
                // 保留该块，但 isLast 标志移交（后面还有新 VORBIS_COMMENT）
                let block = safeSlice(data, offset, 4 + len)
                block[0] = block[0] & 0x7Fu8
                for (b in block) {
                    keptBlocks.add(b)
                }
            }
            audioStart = bodyStart + len
            break
        }

        if (blockType != 4u8) {
            // 非 VORBIS_COMMENT：整块（头 + 体）逐位保留
            for (b in safeSlice(data, offset, 4 + len)) {
                keptBlocks.add(b)
            }
        }
        offset = bodyStart + len
    }

    if (audioStart < 0) {
        throw Audio4CjException("FLAC 标签写入：块链没有终止块（${path}）")
    }

    // ---- 组装新块链 ----
    let newComment = serializeVorbisComment(tag)
    let out = ArrayList<UInt8>()
    for (b in data[0..4]) { // "fLaC" 魔数
        out.add(b)
    }
    for (b in keptBlocks) {
        out.add(b)
    }
    // 新 VORBIS_COMMENT：类型 4，isLast = 1
    out.add(0x80u8 | 4u8)
    out.add(UInt8((Int64(newComment.size) >> 16) & 0xFF))
    out.add(UInt8((Int64(newComment.size) >> 8) & 0xFF))
    out.add(UInt8(Int64(newComment.size) & 0xFF))
    for (b in newComment) {
        out.add(b)
    }
    // 音频帧区原样平移
    for (b in safeSlice(data, audioStart, data.size - audioStart)) {
        out.add(b)
    }

    // 原子落盘
    let tmpPath = "${path}.a4cj_tmp"
    try (f = File(tmpPath, Write)) {
        f.write(out.toArray())
    }
    rename(Path(tmpPath), to: Path(path), overwrite: true)
}
