package audio4cj.format

import audio4cj.core.CorruptedFileException
import audio4cj.core.FormatNotSupportedException
import audio4cj.pcm.readUInt32LE
import std.fs.*

/* ============================================================================
 * Ogg 封装的 FLAC —— 字节源（纯仓颉）
 *
 * 【它做什么】
 *   把 Ogg 容器"拆开"，向解码器呈现一条**与原生 FLAC 逐字节等同的字节流**，
 *   于是 flac_bitstream.cj 的解码逻辑可以原样复用，一行不改。
 *
 * 【重建规则：一条实测钉死的等式】
 *   FLAC 字节流 = 选定逻辑流的**各页页体按出现顺序拼接**，再丢掉首包的
 *   9 字节映射头。首包的实际布局（真实素材实测，见下方"实测依据"）：
 *       7F 46 4C 41 43   0x7F "FLAC"（映射标识，非可打印文本，故用字节写）
 *       01 00            映射主版本 1、次版本 0
 *       00 01            后续元数据块数 headerCount（2 字节，**大端**）
 *       66 4C 61 43 00 00 00 ...   ← 从这里开始就是原生 FLAC 流（"fLaC" 起）
 *   丢掉前 9 字节即得原生流，故源偏移 0 == "fLaC" 的 'f'。
 *
 * 【为什么可以只丢 9 字节、而不做完整的 packet 重组】
 *   页面之间的字节在**重建流里是连续的**：一个 packet 无论结束于本页
 *   （lacing < 255）还是延续到下一页（lacing == 255），它贡献的字节都是
 *   连续的。既然解码器不需要知道 packet 边界（FLAC 自己的帧头已经足够），
 *   就不必重组 packet —— 这是本实现比"完整 Ogg 解析"简单得多的关键。
 *   唯一需要 packet 边界的地方是**首包那 9 字节头**，而它必然落在首页。
 *
 * 【为什么读整页进内存是安全的】
 *   Ogg 规范的硬上限：段表最多 255 项、每项最大 255 字节，故页体 ≤ 65025 字节。
 *   页缓存因此是**有界且与文件大小无关**的（≤ 64 KB），与本库"内存占用与
 *   音频总时长无关"的核心承诺一致。相比之下 meta/ogg_page.cj 面向标签读取、
 *   只读前几个 packet，两者的规模假设完全不同。
 *
 * 【页 CRC 每次都校验（本实现刻意不做"跳页不校验"的优化）】
 *   遍历到的每一页都整页读入并校验 CRC-32，包括被 skip 跳过的页。
 *   另有一种更快的写法是"按段表长度直接越过页体、不读不校验"，但那会让
 *   损坏只能被"恰好读过"的页发现，且本项目原生源的 skip 本来就是读掉丢弃
 *   （见 flac_source.cj 的说明），快慢并无实质差别。宁可校验更全。
 *
 * 【其他逻辑流一律忽略】
 *   Ogg 允许在同一个文件里复用多条逻辑流（音视频复用即典型）。本实现只认
 *   **文件中第一个带 BOS 标志的页面**所属的流，其余 serial 的页面整页跳过 ——
 *   把不同 serial 的字节混进同一条流只会得到垃圾数据。
 *   这与 meta/ogg_page.cj 的选择一致（那里同样"只认第一个带 BOS 的流"）。
 *
 * 【实测依据（真实素材，非推断）】
 *   testdata/ogg/ogg_flac.oga（3 页）与 ogg_flac_tagged.oga（4 页）：
 *   拼接后首 9 字节为 7F 46 4C 41 43 01 00 00 01，第 10 字节起为 "fLaC"；
 *   元数据链解析得 STREAMINFO(34) + VORBIS_COMMENT，首帧偏移 95 / 177；
 *   两者 STREAMINFO 的总样本数均为 **0**（不可知）—— 编码 Ogg 时未必能预知
 *   长度，故本项目如实报告 -1，这正是 §4.1 的既有契约。
 *   页 CRC：8 个素材、30 个页面的存储值与重算值全部一致（见 ogg_crc_test.cj）。
 * ========================================================================== */

/// Ogg 页头固定长度（不含长度可变的段表）。规范口径，与 meta/ogg_page.cj 一致。
private let OGG_PAGE_HEADER_SIZE: Int64 = 27

/// FLAC-in-Ogg 映射头长度（见文件头说明）。
private let OGG_FLAC_MAPPING_HEADER_SIZE: Int64 = 9

/// 单页页体上限（段表 255 项 × 每项 255 字节）。
private let OGG_MAX_PAGE_BODY: Int64 = 255 * 255

/// 页头类型标志位。
private let OGG_HTYPE_BOS: UInt8 = 0x02
private let OGG_HTYPE_EOS: UInt8 = 0x04

/// 页头里 CRC 字段的偏移（小端 4 字节）。
private let OGG_CRC_FIELD_OFFSET: Int64 = 22

/// Ogg 封装的 FLAC 字节源。
protected class OggFlacByteSource <: FlacByteSource {
    private let _path: String
    private var _file: File
    private var _closed: Bool = false

    /// 选定逻辑流的 serial（文件中第一个带 BOS 的页面所属的流）。
    private var _serial: Int64 = -1

    /// 当前页页体（**已通过 CRC 校验**），以及其中已消费到的位置。
    private var _page: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    private var _pageRead: Int64 = 0

    /// 当前页是否为选定流的 EOS 页：它的字节交付完毕后，本流即结束。
    private var _eos: Bool = false

    // ---- 最近一次读到的页头字段（readNextPage 的产物）----
    private var _curSerial: Int64 = -1
    private var _curHtype: UInt8 = 0
    private var _curIsEos: Bool = false

    protected init(path: String) {
        this._path = path
        this._file = File(path, Read)
        try {
            startStream()
        } catch (e: Exception) {
            // 构造失败时该对象永远不会被使用者持有，也就没人能再调用 close()，
            // 句柄会随之泄漏（表现为该文件无法被删除或移动）。
            // 与 FlacFormatReader.init 处理同一类问题的方式一致。
            this._file.close()
            throw e
        }
    }

    // ------------------------------------------------------------------
    // FlacByteSource 实现
    // ------------------------------------------------------------------

    public func readExact(n: Int64): Array<UInt8> {
        let out = Array<UInt8>(n, repeat: 0)
        var got: Int64 = 0
        while (got < n) {
            let scratch = Array<UInt8>(n - got, repeat: 0)
            let r = readSome(scratch)
            if (r <= 0) {
                throw CorruptedFileException("Ogg/FLAC 字节流提前结束（需 ${n} 字节，已得 ${got}）")
            }
            var i: Int64 = 0
            while (i < r) {
                out[got + i] = scratch[i]
                i += 1
            }
            got += r
        }
        out
    }

    public func skip(n: Int64): Unit {
        var left = n
        while (left > 0) {
            if (_pageRead >= _page.size) {
                if (!loadNextMatchingPage()) {
                    // 跳不足必须抛：静默返回会让源的位置与解码器的记账错位
                    // （详见 flac_source.cj 的 skip 契约说明）
                    throw CorruptedFileException("Ogg/FLAC 字节流提前结束：需跳过 ${n} 字节，还有 ${left} 字节未能跳过")
                }
            }
            let avail = _page.size - _pageRead
            let take = if (avail < left) {
                avail
            } else {
                left
            }
            _pageRead += take
            left -= take
        }
    }

    public func readSome(buf: Array<UInt8>): Int64 {
        var total: Int64 = 0
        while (total < buf.size) {
            if (_pageRead >= _page.size) {
                if (!loadNextMatchingPage()) {
                    break
                }
            }
            let avail = _page.size - _pageRead
            let room = buf.size - total
            let take = if (avail < room) {
                avail
            } else {
                room
            }
            var i: Int64 = 0
            while (i < take) {
                buf[total + i] = _page[_pageRead + i]
                i += 1
            }
            _pageRead += take
            total += take
        }
        total
    }

    public func reopen(): Unit {
        _file.close()
        _file = File(_path, Read)

        // 源内部状态一并复位：否则会把上一个流的页缓存/选定 serial 带进来
        _serial = -1
        _page = Array<UInt8>(0, repeat: 0)
        _pageRead = 0
        _eos = false
        _curSerial = -1
        _curHtype = 0
        _curIsEos = false

        startStream()
    }

    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _file.close()
        }
    }

    // ------------------------------------------------------------------
    // 内部：定位流起点
    // ------------------------------------------------------------------

    /// 定位选定流，并把读位置移到重建流的起点（即丢掉 9 字节映射头）。
    private func startStream(): Unit {
        if (!readNextPage()) {
            throw CorruptedFileException("Ogg 文件为空：没有任何页面")
        }

        // 首个页面必须带 BOS 标志，否则不是规范的 Ogg 流（无法据它选定逻辑流）
        if ((_curHtype & OGG_HTYPE_BOS) == 0) {
            throw CorruptedFileException("Ogg 首个页面缺少 BOS 标志，不是规范的 Ogg 流")
        }
        _serial = _curSerial

        // ---- 校验 FLAC-in-Ogg 映射头 ----
        if (_page.size < OGG_FLAC_MAPPING_HEADER_SIZE) {
            throw CorruptedFileException("Ogg 首包不足以容纳 FLAC 映射头（仅 ${_page.size} 字节）")
        }
        if (!(_page[0] == 0x7F && _page[1] == 0x46 && _page[2] == 0x4C && _page[3] == 0x41 && _page[4] == 0x43)) {
            throw FormatNotSupportedException("不是 Ogg 封装的 FLAC 流：首包缺少 0x7F\"FLAC\" 映射标识（${_path}）")
        }
        if (_page[5] != 1) {
            // 官方要求：主版本不同的流无法保证兼容；次版本差异则可忽略
            throw FormatNotSupportedException("Ogg/FLAC 映射主版本为 ${_page[5]}，本实现只支持 1（${_path}）")
        }

        _pageRead = OGG_FLAC_MAPPING_HEADER_SIZE
        _eos = _curIsEos
    }

    // ------------------------------------------------------------------
    // 内部：页面读取
    // ------------------------------------------------------------------

    /// 读下一个 Ogg 页面并整页校验 CRC，结果放在 `_page` / `_cur*` 字段。
    ///
    /// 返回 false 表示**文件到此干净结束**（一个字节都读不到），
    /// 这与"读到一半被截断"是两个不同的结论，后者抛异常。
    private func readNextPage(): Bool {
        let head = readRaw(OGG_PAGE_HEADER_SIZE)
        if (head.size == 0) {
            return false
        }

        if (!(head[0] == 0x4F && head[1] == 0x67 && head[2] == 0x67 && head[3] == 0x53)) {
            throw CorruptedFileException(
                "Ogg 页面起始处缺少 \"OggS\" 捕获模式（实际 ${head[0]} ${head[1]} ${head[2]} ${head[3]}）")
        }
        if (head[4] != 0) {
            // 规范：结构版本恒为 0；未来版本必须显式拒绝而不是当作 0 处理
            throw CorruptedFileException("Ogg 结构版本为 ${head[4]}，本实现只支持 0")
        }

        let segCount = Int64(head[26])
        let table = readRaw(segCount)

        // 页体长度 = 段表各项之和（页头里**没有**独立的页体长度字段）
        var bodyLen: Int64 = 0
        var i: Int64 = 0
        while (i < segCount) {
            bodyLen += Int64(table[i])
            i += 1
        }
        if (bodyLen > OGG_MAX_PAGE_BODY) {
            throw CorruptedFileException("Ogg 页体长度 ${bodyLen} 超出规范上限 ${OGG_MAX_PAGE_BODY}")
        }
        let body = readRaw(bodyLen)

        // ---- 整页 CRC-32 校验 ----
        // 覆盖 页头 + 段表 + 页体；计算前必须把 CRC 字段自身（页头 22..25）置零
        let full = Array<UInt8>(OGG_PAGE_HEADER_SIZE + segCount + bodyLen, repeat: 0)
        var p: Int64 = 0
        while (p < head.size) {
            full[p] = head[p]
            p += 1
        }
        p = 0
        while (p < table.size) {
            full[OGG_PAGE_HEADER_SIZE + p] = table[p]
            p += 1
        }
        p = 0
        while (p < body.size) {
            full[OGG_PAGE_HEADER_SIZE + segCount + p] = body[p]
            p += 1
        }
        let stored = readUInt32LE(full, OGG_CRC_FIELD_OFFSET)
        full[OGG_CRC_FIELD_OFFSET] = 0
        full[OGG_CRC_FIELD_OFFSET + 1] = 0
        full[OGG_CRC_FIELD_OFFSET + 2] = 0
        full[OGG_CRC_FIELD_OFFSET + 3] = 0
        let computed = crc32Ogg(full, 0, full.size)
        if (computed != stored) {
            let pageSeq = readUInt32LE(head, 18)
            throw CorruptedFileException("Ogg 页 CRC 不匹配（页序号 ${pageSeq}，存储 ${stored}，计算 ${computed}）")
        }

        _curSerial = Int64(readUInt32LE(head, 14))
        _curHtype = head[5]
        _curIsEos = (_curHtype & OGG_HTYPE_EOS) != 0
        _page = body
        true
    }

    /// 载入下一页**选定流**的页体（其他逻辑流整页忽略）。
    ///
    /// 返回 false 表示本流已结束：或上一页是 EOS 页，或文件干净结束。
    private func loadNextMatchingPage(): Bool {
        if (_eos) {
            return false // 上一页已是本流末页，其后即便还有字节也不属于本流
        }

        // 逐页读到"本流的页"为止；其他 serial 的页整页忽略（音视频复用即典型）
        var got = readNextPage()
        while (got && _curSerial != _serial) {
            got = readNextPage()
        }
        if (!got) {
            return false
        }

        _pageRead = 0
        _eos = _curIsEos
        true
    }

    /// 精确读 n 字节；**文件恰好到此结束**（一个字节都读不到）时返回空数组，
    /// 读了一部分就断则抛异常。
    private func readRaw(n: Int64): Array<UInt8> {
        let out = Array<UInt8>(n, repeat: 0)
        var got: Int64 = 0
        while (got < n) {
            let scratch = Array<UInt8>(n - got, repeat: 0)
            let r = _file.read(scratch)
            if (r <= 0) {
                if (got == 0) {
                    return Array<UInt8>(0, repeat: 0)
                }
                throw CorruptedFileException("Ogg 页在文件末尾被截断（需 ${n} 字节，只得 ${got}）")
            }
            var i: Int64 = 0
            while (i < r) {
                out[got + i] = scratch[i]
                i += 1
            }
            got += r
        }
        out
    }
}
