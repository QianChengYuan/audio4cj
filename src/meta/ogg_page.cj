package audio4cj.meta

import audio4cj.pcm.readUInt32LE
import std.collection.*

/* ============================================================================
 * Ogg 页重组 —— 开发文档 §10 M3（Vorbis comment 的 Ogg 容器接入）
 *
 * 【为什么需要这一层】
 *   `parseVorbisComment` 早就写好了，但它只吃「注释块的内容字节」，不含容器头部
 *   —— 它原本只服务于 FLAC 的 `VORBIS_COMMENT` 元数据块。Ogg 缺的不是解析，
 *   而是**把散落在多个页面里的注释头重组出来**。本文件补的就是这一层。
 *
 * 【Ogg 页结构】
 *   偏移 长度 含义
 *   0    4    "OggS" 捕获模式
 *   4    1    结构版本（恒为 0）
 *   5    1    页头类型：0x01 = 续传页，0x02 = 起始页(BOS)，0x04 = 结束页(EOS)
 *   6    8    granule position（本实现用不到）
 *   14   4    逻辑流序号 serial（小端）
 *   18   4    页序号（小端）
 *   22   4    CRC 校验和（小端）
 *   26   1    段表长度 page_segments
 *   27   N    段表（N 个 lacing 值）
 *   27+N ?    页体，长度为段表各值之和
 *
 * 【packet 与页的关系（本模块的核心难点）】
 *   一个 packet 由若干「段」拼成，段的长度由段表中的 lacing 值给出：
 *     - 值为 255：该 packet **尚未结束**，后续内容在紧随的段或下一页；
 *     - 值 < 255：该 packet **到此结束**（该值即最后一段的长度）。
 *   因此一个较大的注释块会横跨多页 —— 不处理续传就会静默截断它，
 *   表现为"标签只读到一半"。这是本模块最容易写错的地方。
 *
 * 【子编码如何在 Ogg 里表示】
 *   各子编码用**首个 packet 的 magic** 区分，注释头的位置也不同：
 *     Vorbis  首包 0x01"vorbis"，注释头为**第 2 个** packet，magic 0x03"vorbis"
 *     Opus    首包 "OpusHead"，注释头为**第 2 个** packet，magic "OpusTags"
 *     FLAC    首包 0x7F"FLAC"，其后每个 packet 承载**一个 FLAC 元数据块**
 * ========================================================================== */

/// Ogg 页头固定长度（不含长度可变的段表）。
private let OGG_PAGE_HEADER_SIZE: Int64 = 27

/// 页遍历上限（防畸形数据造成长循环）。
private let OGG_MAX_PAGES: Int64 = 4096

/// 单个 packet 的可接受上限（256 KB）。
///
/// 两层作用：防「段表恒为 255、packet 永不完结」的畸形输入把内存吃光；
/// 也防注释头里塞入超大块。常规注释头（含内嵌封面）都在这个量级以内。
private let OGG_MAX_PACKET_SIZE: Int64 = 256 * 1024

/// Vorbis / Opus 只需前 2 个 packet：第 1 个是识别头，第 2 个是注释头。
private let OGG_PACKETS_TWO: Int64 = 2

/// FLAC-in-Ogg 的首包是 STREAMINFO 块，标签在其后的元数据包里，
/// 故多取几个（典型为 VORBIS_COMMENT 加少量 PADDING / SEEKTABLE）。
private let OGG_PACKETS_FLAC: Int64 = 4

// ---------------------------------------------------------------------------
// 页与 packet
// ---------------------------------------------------------------------------

/// 取出**首个逻辑流**的前 `count` 个完整 packet（按出现顺序）。
///
/// 设计要点：
///
///   1. **只认第一个带 BOS 标志的流**。Ogg 允许在一个文件里复用多条逻辑流
///      （音视频复用即为典型），把不同 serial 的包混拼起来只会得到垃圾。
///   2. **凑够 `count` 个包立即停止**，不把整个音频流重组出来 —— 标签所需的
///      注释头只在前几个包里，多余的重组纯属浪费内存与时间。
///   3. **正确处理跨页续传**（见文件头说明）。
///   4. 页数、单包长度均设上限；页体不完整（读取窗口不够或文件被截断）即停止，
///      绝不越界读取。
protected func oggFirstPackets(data: Array<UInt8>, count: Int64): ArrayList<Array<UInt8>> {
    let out = ArrayList<Array<UInt8>>()
    if (count <= 0) {
        return out
    }

    var chosenSerial: ?Int64 = None
    var pending = ArrayList<UInt8>()
    var offset: Int64 = 0
    var pages: Int64 = 0

    while (offset + OGG_PAGE_HEADER_SIZE <= data.size) {
        pages += 1
        if (pages > OGG_MAX_PAGES) {
            break
        }

        // 不是页起点：说明前面解析已经跑偏，或已走到窗口里非页对齐的位置
        if (!matchAsciiAt(data, offset, "OggS")) {
            break
        }

        let headerType = data[offset + 5]
        let pageSerial = Int64(readUInt32LE(data, offset + 14))
        let segCount = Int64(data[offset + 26])

        let tableStart = offset + OGG_PAGE_HEADER_SIZE
        if (tableStart + segCount > data.size) {
            break
        }

        // 页体长度 = 段表各值之和（这是页体的**权威长度**，
        // 页头里没有独立的页体长度字段）
        var bodyLen: Int64 = 0
        for (i in 0..segCount) {
            bodyLen += Int64(data[tableStart + i])
        }
        let bodyStart = tableStart + segCount
        if (bodyStart + bodyLen > data.size) {
            // 页体不完整：可能只是读取窗口不够，也可能是文件被截断
            break
        }

        if (chosenSerial.isNone()) {
            // 首条流必须带 BOS 标志，否则不是规范的 Ogg 流
            if ((headerType & 0x02u8) == 0u8) {
                break
            }
            chosenSerial = Some(pageSerial)
        }

        if (pageSerial != chosenSerial.getOrThrow()) {
            // 其它逻辑流：整页跳过。注意必须推进 offset，不能 break ——
            // 否则会因为一条无关的流而放弃整个文件
            offset = bodyStart + bodyLen
            continue
        }

        // ---- 按段表把一个页体切成若干 packet ----
        var pos = bodyStart
        for (i in 0..segCount) {
            let lacing = Int64(data[tableStart + i])
            if (lacing > 0) {
                for (b in safeSlice(data, pos, lacing)) {
                    pending.add(b)
                }
            }
            pos += lacing

            // 单包上限：既拦"段值恒为 255、永不完结"的畸形，
            // 也拦超大注释块
            if (pending.size > OGG_MAX_PACKET_SIZE) {
                return out
            }

            if (lacing < 255) {
                // 该 packet 到此结束
                out.add(pending.toArray())
                pending = ArrayList<UInt8>()
                if (out.size >= count) {
                    return out
                }
            }
        }

        offset = bodyStart + bodyLen
    }

    out
}

// ---------------------------------------------------------------------------
// 各子编码的注释头
// ---------------------------------------------------------------------------

/// 从 Vorbis / Opus 的第 2 个 packet 中取出注释载荷（去掉各自的 magic）。
///
///   Vorbis：`0x03` + `"vorbis"`（7 字节），其后即标准 Vorbis comment 结构
///   Opus  ：`"OpusTags"`（8 字节），其后是**同构**的 comment 结构 ——
///           Opus 复用了 Vorbis comment 的字段编码方式，只换了顶层 magic，
///           因此两者可以共用同一个解析器。
///
/// 认不出则返回 None（不是错误）。
private func commentPayloadOf(packet: Array<UInt8>): ?Array<UInt8> {
    if (packet.size >= 7 && packet[0] == 0x03u8 && matchAsciiAt(packet, 1, "vorbis")) {
        return Some(safeSlice(packet, 7, packet.size - 7))
    }
    if (matchAsciiAt(packet, 0, "OpusTags")) {
        return Some(safeSlice(packet, 8, packet.size - 8))
    }
    None
}

/// 把 FLAC-in-Ogg 的头部包重建成**原生 FLAC 形式的字节**（`"fLaC"` + 块序列），
/// 以便直接复用 `parseFlacMetadata` —— 没必要为 Ogg 封装再写一套块链解析。
///
/// 首包布局（Ogg-FLAC 映射约定）：
///
///     0x7F 'F''L''A''C'   5 字节，映射头
///     主版本               1 字节
///     次版本               1 字节
///     头包数               2 字节，大端
///     'f''L''a''C'         4 字节
///     首个元数据块         4 字节块头 + 34 字节 STREAMINFO 体
///
/// 即**首包第 13 字节起**就是 STREAMINFO 块，可直接续在 `"fLaC"` 之后。
/// 其后每个 packet 承载**一个** FLAC 元数据块；按块头最高位（是否最后一块）
/// 判断何时停止 —— 不能把音频包也喂进块链解析器。
private func rebuildFlacChain(packets: ArrayList<Array<UInt8>>): ?Array<UInt8> {
    if (packets.size < 1) {
        return None
    }

    let first = packets[0]
    // 最短合法首包 = 5 + 1 + 1 + 2 + 4 + 4（块头）= 17 字节
    if (first.size < 17) {
        return None
    }
    if (first[0] != 0x7Fu8 || !matchAsciiAt(first, 1, "FLAC") || !matchAsciiAt(first, 9, "fLaC")) {
        return None
    }

    let out = ArrayList<UInt8>()
    for (b in "fLaC".toArray()) {
        out.add(b)
    }

    // 首包尾部：STREAMINFO 块
    let streamInfo = safeSlice(first, 13, first.size - 13)
    for (b in streamInfo) {
        out.add(b)
    }

    var finished = (streamInfo.size >= 1) && ((streamInfo[0] & 0x80u8) != 0u8)

    var i: Int64 = 1
    while (!finished && i < packets.size) {
        let block = packets[i]
        if (block.size < 4) {
            break
        }
        for (b in block) {
            out.add(b)
        }
        if ((block[0] & 0x80u8) != 0u8) {
            finished = true
        }
        i += 1
    }

    Some(out.toArray())
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 解析 Ogg 容器中的标签。**纯解析、零 I/O**：输入为文件开头的一段字节。
///
/// 按首个 packet 的 magic 自行判定子编码，再走各自路径：
///
///   | 子编码 | 标签位置 |
///   |--------|----------|
///   | Vorbis | 第 2 个 packet，去掉 `0x03"vorbis"` 后交给 `parseVorbisComment` |
///   | Opus   | 第 2 个 packet，去掉 `"OpusTags"` 后交给 `parseVorbisComment` |
///   | FLAC   | 头部各 packet 承载的 FLAC 元数据块链，复原后交给 `parseFlacMetadata` |
///   | 其它   | 返回空 Tag（Speex 的注释机制与 Vorbis comment 不同，未覆盖） |
///
/// 认不出子编码、没有注释头、结构非法 —— 一律返回**空 Tag**，绝不抛异常：
/// 「没有标签」不是错误（§4.1 铁律 1）。
protected func parseOggTags(data: Array<UInt8>): Tag {
    var result = Tag()

    let head = oggFirstPackets(data, OGG_PACKETS_TWO)
    if (head.size < 1) {
        return result
    }

    let first = head[0]
    let isFlac = (first.size >= 5) && (first[0] == 0x7Fu8) && matchAsciiAt(first, 1, "FLAC")

    if (isFlac) {
        // FLAC-in-Ogg：标签在后续的元数据包里，需要多取几个头部包。
        // 这里重新扫一遍而不是一次取够，是为了让 Vorbis / Opus（绝大多数情形）
        // 只重组 2 个包，完全不去碰音频包。
        let packets = oggFirstPackets(data, OGG_PACKETS_FLAC)
        match (rebuildFlacChain(packets)) {
            case Some(chain) => result = parseFlacMetadata(chain)
            case None => ()
        }
    } else if (head.size >= 2) {
        match (commentPayloadOf(head[1])) {
            case Some(payload) => result = parseVorbisComment(payload)
            case None => ()
        }
    }

    result
}
