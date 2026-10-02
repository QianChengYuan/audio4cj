package audio4cj.meta

import std.collection.*

/* ============================================================================
 * MP4 原子（atom/box）标签解析 —— 开发文档 §10 M3（延后项，本轮补上）
 *
 * 【box 结构】
 *
 *     size(4, 大端) | type(4) | 负载
 *
 *   - size 为 1：其后跟 8 字节 **largesize**（64 位），用于超过 4 GB 的 box；
 *   - size 为 0：该 box 一直延伸到父容器末尾；
 *   - 其余：size 即整个 box（**含 8 字节头部**）的字节数。
 *
 * 【标签的位置】
 *
 *     moov / udta / meta / ilst / <条目 box> / data box
 *
 *   两处最容易漏的地方：
 *
 *   1. **`meta` 是 FullBox**：它的负载开头有 4 字节 version + flags，
 *      子 box 从第 4 字节之后才开始。漏掉这一步会把 version/flags 当成
 *      box 的长度字段，直接解析失败（且失败得很安静，只是读不到标签）。
 *
 *   2. **`©` 前缀是单字节 0xA9**，见下方常量处的说明。
 *
 * 【data box 的负载】
 *
 *     typeIndicator(4, 大端) | locale(4) | 实际数据
 *
 *   - typeIndicator == 1：UTF-8 文本；
 *   - trkn / disk：二进制，2 字节保留 + 2 字节当前值 + 2 字节总数（大端）；
 *   - covr：图片数据，typeIndicator 13 = JPEG / 14 = PNG。
 *
 * 【输入约定】
 *   `parseMp4Tags` 接收文件的一段字节与其中 `moov` box 的**起始下标**。
 *   之所以由调用方给出 moov 位置：`moov` 既可能在文件头部（做过 faststart
 *   优化），也可能在**文件末尾**（ffmpeg 的默认行为）—— 后者要用"尾部窗口 +
 *   尾部对齐"定位，属 I/O 侧的职责（见 file_tags.cj）。
 * ========================================================================== */

/// box 的最小头部长度。
private let MP4_BOX_HEADER: Int64 = 8

/// 单层内 box 的遍历上限（防畸形数据造成长循环）。
private let MP4_MAX_BOXES: Int64 = 4096

/// ilst 条目数上限。
private let MP4_MAX_ITEMS: Int64 = 1024

// ---------------------------------------------------------------------------
// 含 `©` 前缀的条目类型名
//
// **这是 MP4 标签解析最经典的坑**：`©` 在 MP4 的 box 类型名里是**单字节 0xA9**
// （Latin-1 意义上的版权符号 U+00A9）；而在 UTF-8 里同一个码点是**两字节**
// 0xC2 0xA9。于是在源码里写字符串 "©nam" 会得到 5 字节 0xC2 0xA9 'n' 'a' 'm'，
// 与文件里 4 字节的类型名永远匹配不上 —— 而且不报错，只是静默读不到标签。
//
// 因此这些类型名一律用**字节数组**表达，首字节显式写成 0xA9。
// 纯 ASCII 的类型名（moov / udta / ilst / trkn …）则直接用字符串比较，
// 既可读又不会踩这个坑。
// ---------------------------------------------------------------------------

private let MP4_ITEM_TITLE: Array<UInt8> = [0xA9, 0x6E, 0x61, 0x6D] // ©nam
private let MP4_ITEM_ARTIST: Array<UInt8> = [0xA9, 0x41, 0x52, 0x54] // ©ART
private let MP4_ITEM_ALBUM: Array<UInt8> = [0xA9, 0x61, 0x6C, 0x62] // ©alb
private let MP4_ITEM_YEAR: Array<UInt8> = [0xA9, 0x64, 0x61, 0x79] // ©day
private let MP4_ITEM_GENRE: Array<UInt8> = [0xA9, 0x67, 0x65, 0x6E] // ©gen
private let MP4_ITEM_COMMENT: Array<UInt8> = [0xA9, 0x63, 0x6D, 0x74] // ©cmt
private let MP4_ITEM_COMPOSER: Array<UInt8> = [0xA9, 0x77, 0x72, 0x74] // ©wrt

// ---------------------------------------------------------------------------
// box 遍历
// ---------------------------------------------------------------------------
/// 比较 `data` 的 `offset` 处是否为给定字节序列（用于含 0xA9 的类型名）。
private func mp4MatchType(data: Array<UInt8>, offset: Int64, want: Array<UInt8>): Bool {
    if (offset < 0 || offset + want.size > data.size) {
        return false
    }
    for (i in 0..want.size) {
        if (data[offset + i] != want[i]) {
            return false
        }
    }
    true
}

/// 读出一个 box 的范围，返回 (`块体起点`, `box 末尾`)；结构非法时返回 None。
///
/// `limit` 是父容器的末尾（对最外层即数据末尾）。所有长度字段都来自文件内容、
/// 均不可信，因此每一步都要校验，宁可停止解析也不越界读取。
private func mp4BoxRange(data: Array<UInt8>, boxStart: Int64, limit: Int64): ?(Int64, Int64) {
    if (boxStart < 0 || boxStart + MP4_BOX_HEADER > limit) {
        return None
    }

    let size32 = Int64(readUInt32BE(data, boxStart))
    var headerLen = MP4_BOX_HEADER
    var boxSize = size32

    if (size32 == 1) {
        // 64 位 largesize
        if (boxStart + 16 > limit) {
            return None
        }
        let hi = Int64(readUInt32BE(data, boxStart + 8))
        let lo = Int64(readUInt32BE(data, boxStart + 12))
        headerLen = 16
        boxSize = (hi << 32) | lo
    } else if (size32 == 0) {
        // 延伸到父容器末尾
        boxSize = limit - boxStart
    }

    let boxEnd = boxStart + boxSize

    // 长度不足以容纳头部，或越出父容器 —— 视为结构非法
    if (boxSize < headerLen || boxEnd > limit) {
        return None
    }

    Some((boxStart + headerLen, boxEnd))
}

/// 在 `[start, limit)` 内遍历**直接子 box**，查找类型为 `want` 的那一个，
/// 返回其 (`块体起点`, `box 末尾`)；找不到返回 None。
private func mp4FindChild(
    data: Array<UInt8>,
    start: Int64,
    limit: Int64,
    want: Array<UInt8>
): ?(Int64, Int64) {
    var offset = start
    var guard: Int64 = 0

    while (offset + MP4_BOX_HEADER <= limit) {
        guard += 1
        if (guard > MP4_MAX_BOXES) {
            break
        }

        match (mp4BoxRange(data, offset, limit)) {
            case Some(r) =>
                // 这里只用 box 末尾来推进游标，块体起点用通配符丢弃
                let (_, boxEnd) = r
                if (mp4MatchType(data, offset + 4, want)) {
                    return Some(r)
                }
                // 防止 size 为 0 造成原地打转（size 为 0 时 boxEnd 本应等于 limit，
                // 但若 limit 计算异常仍可能原地不动）
                if (boxEnd <= offset) {
                    break
                }
                offset = boxEnd
            case None => break
        }
    }

    None
}

/// 正向查找**顶层** `moov` box 的起始下标（用于文件头部窗口）。
///
/// 只走顶层 box 链：既快，也避免在 mdat 的音频数据里误命中 "moov" 字节。
protected func mp4FindMoov(data: Array<UInt8>): ?Int64 {
    var offset: Int64 = 0
    var guard: Int64 = 0

    while (offset + MP4_BOX_HEADER <= data.size) {
        guard += 1
        if (guard > MP4_MAX_BOXES) {
            break
        }

        match (mp4BoxRange(data, offset, data.size)) {
            case Some(r) =>
                if (matchAsciiAt(data, offset + 4, "moov")) {
                    return Some(offset)
                }
                // 只用到 box 末尾；元组不存在 `.1` 这种字段访问写法，必须解构
                let (_, boxEnd) = r
                if (boxEnd <= offset) {
                    break
                }
                offset = boxEnd
            case None => break
        }
    }

    None
}

/// 查找**紧贴窗口末尾**的 `moov` box 起始下标（用于文件尾部窗口）。
///
/// 【为什么不能只搜 "moov" 字节】
///   mdat 里就是压缩后的音频数据，其中完全可能偶然出现 "moov" 四个字节。
///   这里要求「box 的 size 恰好让它结束于窗口末尾」，即
///   `i + size(i) == data.size` —— 对于放在文件末尾的 moov 这是恒成立的
///   结构事实，而偶然命中的概率极低。
///
/// 为省开销，先用类型名过滤（4 字节比较能一次性排除绝大多数位置），
/// 再算长度关系。
protected func mp4FindTrailingMoov(data: Array<UInt8>): ?Int64 {
    if (data.size < MP4_BOX_HEADER) {
        return None
    }

    var i: Int64 = 0
    while (i + MP4_BOX_HEADER <= data.size) {
        if (matchAsciiAt(data, i + 4, "moov")) {
            if (Int64(readUInt32BE(data, i)) == data.size - i) {
                return Some(i)
            }
        }
        i += 1
    }

    None
}

// ---------------------------------------------------------------------------
// ilst 解析
// ---------------------------------------------------------------------------

/// 把 box 类型名渲染成可打印字符串，用作 `extra` 的键。
///
/// 0xA9（`©` 的单字节形式）写成 'c' —— 这与多数 MP4 工具的习惯一致
/// （如 `©nam` 写作 `cnam`）；其余不可打印字节写成 '_'。
private func mp4TypeName(data: Array<UInt8>, offset: Int64): String {
    let runes = ArrayList<Rune>()

    for (i in 0..4) {
        let idx = offset + i
        if (idx < 0 || idx >= data.size) {
            break
        }
        let b = data[idx]
        if (b == 0xA9u8) {
            runes.add(r'c')
        } else if (b >= 0x20u8 && b < 0x7Fu8) {
            runes.add(Rune(UInt32(b)))
        } else {
            runes.add(r'_')
        }
    }

    String(runes.toArray())
}

/// 读取 trkn / disk 的「当前值 / 总数」。
///
/// 负载：2 字节保留 + 2 字节当前值 + 2 字节总数（大端；总数可能缺失）。
private func mp4ReadNumberPair(data: Array<UInt8>, start: Int64, end: Int64): (?Int64, ?Int64) {
    var current: ?Int64 = None
    var total: ?Int64 = None

    if (start + 4 <= end) {
        current = Some(Int64(readUInt16BE(data, start + 2)))
    }
    if (start + 6 <= end) {
        total = Some(Int64(readUInt16BE(data, start + 4)))
    }

    (current, total)
}

/// 把一个 ilst 条目的 `data` box 载荷映射到 `tag`。
///
/// `typeOff` 是该条目的类型名在 `data` 中的下标（4 字节）。
private func mp4ApplyItem(
    data: Array<UInt8>,
    typeOff: Int64,
    bodyStart: Int64,
    bodyEnd: Int64,
    tag: Tag
): Unit {
    // data box 负载至少要容纳 typeIndicator + locale 共 8 字节
    if (bodyStart + 8 > bodyEnd) {
        return
    }

    let indicator = Int64(readUInt32BE(data, bodyStart))
    let payloadStart = bodyStart + 8
    let payloadLen = bodyEnd - payloadStart
    if (payloadLen <= 0) {
        return
    }

    // ---- 封面：covr ----
    if (matchAsciiAt(data, typeOff, "covr")) {
        if (indicator == 13 || indicator == 14) {
            tag.coverArt = safeSlice(data, payloadStart, payloadLen)
            tag.coverMime = if (indicator == 13) {
                "image/jpeg"
            } else {
                "image/png"
            }
        }
        return
    }

    // ---- 音轨号 / 碟号：二进制而非文本 ----
    if (matchAsciiAt(data, typeOff, "trkn") || matchAsciiAt(data, typeOff, "disk")) {
        let (cur, total) = mp4ReadNumberPair(data, payloadStart, bodyEnd)
        if (matchAsciiAt(data, typeOff, "trkn")) {
            tag.track = cur
            tag.trackTotal = total
        } else {
            tag.disc = cur
        }
        return
    }

    // ---- 其余按文本处理 ----
    // 只认 typeIndicator == 1（UTF-8 文本）。别的类型指示说明这不是文本，
    // 按文本硬解只会得到乱码，不如不填。
    if (indicator != 1) {
        return
    }

    let text = decodeUtf8Safe(safeSlice(data, payloadStart, payloadLen)).trimAscii()
    if (text.isEmpty()) {
        return
    }

    if (mp4MatchType(data, typeOff, MP4_ITEM_TITLE)) {
        tag.title = text
    } else if (mp4MatchType(data, typeOff, MP4_ITEM_ARTIST)) {
        tag.artist = text
    } else if (mp4MatchType(data, typeOff, MP4_ITEM_ALBUM)) {
        tag.album = text
    } else if (matchAsciiAt(data, typeOff, "aART")) {
        tag.albumArtist = text
    } else if (mp4MatchType(data, typeOff, MP4_ITEM_YEAR)) {
        tag.year = text
    } else if (mp4MatchType(data, typeOff, MP4_ITEM_GENRE)) {
        tag.genre = text
    } else if (mp4MatchType(data, typeOff, MP4_ITEM_COMMENT)) {
        tag.comment = text
    } else if (mp4MatchType(data, typeOff, MP4_ITEM_COMPOSER)) {
        tag.composer = text
    } else {
        // 冷门原子（©too / ©lyr / ©grp 等）进 extra 兜底，键为渲染后的类型名
        tag.putExtra(mp4TypeName(data, typeOff), text)
    }
}

/// 遍历 ilst 的各条目，逐个映射到 `tag`。
private func mp4ParseIlst(data: Array<UInt8>, start: Int64, end: Int64, tag: Tag): Unit {
    var offset = start
    var guard: Int64 = 0

    while (offset + MP4_BOX_HEADER <= end) {
        guard += 1
        if (guard > MP4_MAX_ITEMS) {
            break
        }

        match (mp4BoxRange(data, offset, end)) {
            case Some(r) =>
                let (bodyStart, boxEnd) = r
                let typeOff = offset + 4

                // 每个条目内部只有一个 data box（规范如此）；找不到就跳过该条目
                match (mp4FindChild(data, bodyStart, boxEnd, "data".toArray())) {
                    case Some(d) =>
                        let (dataBody, dataEnd) = d
                        mp4ApplyItem(data, typeOff, dataBody, dataEnd, tag)
                    case None => ()
                }

                if (boxEnd <= offset) {
                    break
                }
                offset = boxEnd
            case None => break
        }
    }
}

/// 逐层定位 `moov / udta / meta / ilst`，返回 ilst 的块体范围。
private func mp4FindIlst(data: Array<UInt8>, moovStart: Int64): ?(Int64, Int64) {
    match (mp4BoxRange(data, moovStart, data.size)) {
        case Some(moov) =>
            let (moovBody, moovEnd) = moov

            match (mp4FindChild(data, moovBody, moovEnd, "udta".toArray())) {
                case Some(udta) =>
                    let (udtaBody, udtaEnd) = udta

                    match (mp4FindChild(data, udtaBody, udtaEnd, "meta".toArray())) {
                        case Some(meta) =>
                            let (metaBody, metaEnd) = meta

                            // meta 是 FullBox：跳过 4 字节 version + flags
                            let childrenStart = metaBody + 4
                            if (childrenStart > metaEnd) {
                                return None
                            }
                            mp4FindChild(data, childrenStart, metaEnd, "ilst".toArray())
                        case None => None
                    }
                case None => None
            }
        case None => None
    }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 解析 MP4 的 ilst 标签。**纯解析、零 I/O**。
///
/// - `data`：文件的一段字节
/// - `moovStart`：`data` 内 `moov` box 的起始下标（即其 size 字段的位置）
///
/// 层级缺失、结构非法、没有标签 —— 一律返回**空 Tag**，绝不抛异常：
/// 「没有标签」不是错误（§4.1 铁律 1）。而 `moov` 的位置由调用方给出，
/// 是因为它可能位于文件头（faststart）或文件尾（ffmpeg 默认）。
protected func parseMp4Tags(data: Array<UInt8>, moovStart: Int64): Tag {
    let tag = Tag()

    match (mp4FindIlst(data, moovStart)) {
        case Some(ilst) =>
            let (start, end) = ilst
            mp4ParseIlst(data, start, end, tag)
        case None => ()
    }

    tag
}
