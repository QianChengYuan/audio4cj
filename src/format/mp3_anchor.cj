package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 —— 帧同步（找第一帧）与 VBR 锚点
 *
 * 【为什么要"找"第一帧】MP3 的裸流没有文件头：开头可能有 ID3v2 标签、可能有
 *   编码器写入的垃圾字节。因此打开文件时只能**扫描同步字**并验证它是否真的
 *   成立。`findFrame` 负责扫描，`matchFrame` 负责"这个候选是不是真的"。
 *
 * 【为什么单个同步字不足为凭】任何字节都可能是 0xFF。0xFF 之后高 3 位全 1 只是
 *   **必要条件**：真正的判据是"**按帧长推进，连续若干帧的帧头都同串流**"
 *   （`hdrCompare` 只看版本/层/采样率/声道模式，见 mp3_header.cj）。
 *   这条规则是"K 连续帧"（`MAX_FRAME_SYNC_MATCHES = 10`），也是本层抵御
 *   伪造/损坏数据的主要手段 —— 放宽它，垃圾文件会被当成音频解出噪声。
 *
 * 【VBR 锚点是什么】编码器会在**第一个帧**里塞一段元数据（Xing / Info / VBRI），
 *   声明总帧数、字节数与 TOC（用于定位）。它只影响"时长与 seek 的精度"，
 *   不影响一帧能否解码 —— 所以解析失败只返回 `None`，不报错。
 *   注意：**锚点声明的帧数与实际解出的帧数可能不等**（编码器延迟/填充），
 *   总帧数只作为"时长估计"，不能当解码循环的终止条件。
 * ========================================================================== */

/// 判断从 `hdr` 起点开始的帧头是否成立：按帧长推进，检查连续帧是否同串流。
///
/// 返回 **1 = 成立、0 = 不成立**（不是布尔是因为参照实现如此，保持调用处一致）。
/// 推进到数据不足时：已经匹配过若干帧（`nmatch > 0`）就算成立 —— 流尾本来就
/// 可能不完整；一帧都没匹配上则判否。
private func matchFrame(hdr: Array<UInt8>, mp3Bytes: Int64, frameBytes: Int64): Int64 {
    var i: Int64 = 0
    var nmatch: Int64 = 0
    while (nmatch < MAX_FRAME_SYNC_MATCHES) {
        i = i + hdrFrameBytes(hdr.slice(i, mp3Bytes - i), frameBytes) + hdrPadding(hdr.slice(i, mp3Bytes - i))
        if (i + HDR_SIZE > mp3Bytes) {
            if (nmatch > 0) {
                return 1
            } else {
                return 0
            }
        }
        if (!hdrCompare(hdr, hdr.slice(i, mp3Bytes - i))) {
            return 0
        }
        nmatch = nmatch + 1
    }
    return 1
}

/// `findFrame` 的结果（值类型）：
///   · `offset`：第一帧相对输入起点的字节偏移（前面的 ID3/垃圾字节都不算）；
///   · `frameBytes`：这一帧的长度（**不含填充**，调用方按需相加）；
///   · `freeFormatBytes`：自由格式下实测出来的帧长（0 表示不是自由格式）。
protected struct FindFrameResult {
    var offset: Int64 = 0
    var frameBytes: Int64 = 0
    var freeFormatBytes: Int64 = 0
}

/* ============================================================================
 * 首帧锚点：探测结果 + 总帧数（Xing / Info / VBRI）
 *
 * 【为什么要 Xing/VBRI】MP3 的帧数无法从头部直接算出（变比特率下每帧字节数不同）。
 *   LAME 等编码器会在**首帧**写入 Xing（VBR）或 Info（CBR）标签，内含帧数；
 *   Fraunhofer 系则写 VBRI。读到它们就能给出精确总帧数（时长）。
 *   读不到时总帧数报 -1（不可知），由调用方按"未知"处理 —— 这是本库既有约定。
 *
 * 【为什么放在本文件】这里要用到帧头字段访问与帧同步扫描，它们都是本文件的
 *   私有实现；把锚点解析一并放在此处，避免把这些内部细节升格为跨文件 API。
 * ========================================================================== */

/// 首帧锚点（容器级信息，供 demuxer 使用）。
protected class Mp3Anchor {
    /// 首个音频帧相对数据起始的字节偏移（MID3/ID3v2 之后的第一个同步字）。
    protected var frameOffset: Int64 = 0

    /// 该帧占用的字节数（含 padding）。
    protected var frameBytes: Int64 = 0

    /// 每帧样本数（MPEG1 为 1152，MPEG2/2.5 为 576）。
    protected var samplesPerFrame: Int64 = 0

    protected var sampleRate: Int64 = 0

    protected var channels: Int64 = 0

    /// MPEG 层号（1/2/3；本库仅承诺 Layer III 即 MP3）。
    protected var layer: Int64 = 0

    /// 首帧比特率（kbps；自由格式为 0）。
    protected var bitrateKbps: Int64 = 0

    /// Xing/VBRI 声明的总帧数；**-1 表示不可知**。
    protected var totalFrames: Int64 = -1

    public init() {}
}

/// 判定 `data[off..]` 是否以 ASCII 串 `tag` 开头。
/// 判断 `data[off..]` 是否为 ASCII 字符串 `tag`（如 "Xing" / "Info" / "VBRI"）。
///
/// 越界一律返回 false（而不是抛异常）：锚点探测要连续试三种标签，
/// 用异常表达"这个位置不是它"会让调用方充斥着 try —— 大小比较更直接。
private func tagEquals(data: Array<UInt8>, off: Int64, tag: String): Bool {
    let n = tag.size
    if (off < 0 || off + n > data.size) {
        return false
    }
    var i: Int64 = 0
    while (i < n) {
        if (Int64(data[off + i]) != Int64(tag[i])) {
            return false
        }
        i += 1
    }
    true
}

/// 读取大端 32 位整数（MP3 的位流是大端）。
/// 读一个大端 32 位无符号整数。
///
/// 【为什么锚点用大端而音频数据不用】Xing/VBRI 是编码器自定的标签区，
/// 沿用了网络字节序；而 MP3 的音频语法是**按位**读的，没有"小端/大端"一说。
/// 两者混在一个文件里，是这里必须显式写 `BE` 的原因。
private func readU32BE(data: Array<UInt8>, off: Int64): Int64 {
    (Int64(data[off]) << 24) | (Int64(data[off + 1]) << 16) | (Int64(data[off + 2]) << 8) | Int64(data[off + 3])
}

/// 解析首帧锚点；数据里找不到合法帧时返回 None。
///
/// 调用方需保证 `bytes <= data.size` 且数据足以覆盖首帧与可能的 VBR 标签。
/// 解析第一个帧里的 VBR 锚点（Xing / Info / VBRI），返回 `None` 表示没有。
///
/// 【为什么返回 Option 而不是抛异常】锚点缺失或字段缺失是**完全正常**的
/// （CBR 文件、或编码器没写锚点），不影响解码。调用方把它当成"时长/定位的
/// 附加信息"处理。三个标签的位置不同（Xing/Info 在帧头之后按声道数偏移，
/// VBRI 固定在帧头后 32 字节），故探测时要分别试。
protected func mp3ParseAnchor(data: Array<UInt8>, bytes: Int64): ?Mp3Anchor {
    if (bytes < HDR_SIZE) {
        return None
    }
    let found = findFrame(data, bytes, 0)
    if (found.frameBytes == 0 || found.offset + HDR_SIZE > bytes) {
        return None
    }

    let hdr = data.slice(found.offset, HDR_SIZE)
    let a = Mp3Anchor()
    a.frameOffset = found.offset
    a.frameBytes = found.frameBytes
    a.samplesPerFrame = hdrFrameSamples(hdr)
    a.sampleRate = hdrSampleRateHz(hdr)
    a.layer = 4 - hdrGetLayer(hdr)
    a.channels = if (hdrIsMono(hdr)) {
        1
    } else {
        2
    }
    a.bitrateKbps = hdrBitrateKbps(hdr)

    // Xing/VBRI 里记的是 **MP3 帧数**，需乘每帧样本数才是本库口径的 PCM 帧数
    let vbrFrames = readVbrFrames(data, bytes, found.offset, hdr)
    a.totalFrames = if (vbrFrames >= 0) {
        vbrFrames * a.samplesPerFrame
    } else {
        -1
    }
    Some(a)
}

/// 优先从 Xing/Info，其次从 VBRI 读取总帧数；两者都没有时返回 -1。
/// 从锚点帧里读出"总帧数"：优先用锚点声明的值，没有就**实测**（沿帧长走一遍）。
///
/// 实测是最后手段，代价是整文件扫描；它的意义在于"锚点缺失时仍能报出准确时长"。
/// 返回 0 表示无法确定（调用方按"不可知"处理，与既有约定一致）。
private func readVbrFrames(data: Array<UInt8>, bytes: Int64, frameOffset: Int64, hdr: Array<UInt8>): Int64 {
    let mpeg1 = hdrTestMpeg1(hdr)
    let mono = hdrIsMono(hdr)
    let sideInfo = if (mpeg1) {
        if (mono) {
            17
        } else {
            32
        }
    } else {
        if (mono) {
            9
        } else {
            17
        }
    }
    let crc: Int64 = if (hdrIsCrc(hdr)) {
        2
    } else {
        0
    }

    // Xing / Info：紧随帧头 + CRC + side info 之后
    let xOff = frameOffset + HDR_SIZE + crc + sideInfo
    if (tagEquals(data, xOff, "Xing") || tagEquals(data, xOff, "Info")) {
        let flags = readU32BE(data, xOff + 4)
        if ((flags & 1) != 0 && xOff + 12 <= bytes) {
            return readU32BE(data, xOff + 8)
        }
    }

    // VBRI：固定在帧头之后 32 字节处；其 frames 字段位于 VBRI 起点 +14
    let vOff = frameOffset + HDR_SIZE + 32
    if (tagEquals(data, vOff, "VBRI") && vOff + 18 <= bytes) {
        return readU32BE(data, vOff + 14)
    }

    -1
}

/// 扫描输入，定位**第一处成立的同步**；找不到时返回 `frameBytes = 0` 的结果。
///
/// 流程：跳过可能开头的 ID3v2 → 逐字节找 `0xFF` 候选 → `hdrValid` 过滤保留值 →
/// `matchFrame` 用"连续帧"确认。三步缺一不可：
///   · 只找 0xFF 会把巧合字节当帧；
///   · 只看 `hdrValid` 会把"合法帧头 + 垃圾数据"当帧；
///   · 只有 `matchFrame` 才是"真能按帧长走下去"的证据。
/// 自由格式（比特率索引 0）无法从帧头算帧长，只能用"扫到下一处同步"的距离实测；
/// `freeFormatBytesIn` 让调用方把已知值带进来，省掉重复扫描。
protected func findFrame(mp3: Array<UInt8>, mp3Bytes: Int64, freeFormatBytesIn: Int64): FindFrameResult {
    var res = FindFrameResult()
    res.freeFormatBytes = freeFormatBytesIn
    var i: Int64 = 0
    var k: Int64 = 0
    var mp3p = mp3
    while (i < mp3Bytes - HDR_SIZE) {
        if (hdrValid(mp3p)) {
            var frameBytes = hdrFrameBytes(mp3p, res.freeFormatBytes)
            var frameAndPadding = frameBytes + hdrPadding(mp3p)
            k = HDR_SIZE
            while (frameBytes == 0 && k < MAX_FREE_FORMAT_FRAME_SIZE && i + 2 * k < mp3Bytes - HDR_SIZE) {
                if (hdrCompare(mp3p, mp3p.slice(k, mp3Bytes - i - k))) {
                    let fb = k - hdrPadding(mp3p)
                    let nextfb = fb + hdrPadding(mp3p.slice(k, mp3Bytes - i - k))
                    if (i + k + nextfb + HDR_SIZE > mp3Bytes ||
                        !hdrCompare(mp3p, mp3p.slice(k + nextfb, mp3Bytes - i - (k + nextfb)))) {
                        k = k + 1
                        continue
                    }
                    frameAndPadding = k
                    frameBytes = fb
                    res.freeFormatBytes = fb
                }
                k = k + 1
            }
            if ((frameBytes != 0 && i + frameAndPadding <= mp3Bytes && matchFrame(mp3p, mp3Bytes - i, frameBytes) != 0) ||
                (i == 0 && frameAndPadding == mp3Bytes)) {
                res.offset = i
                res.frameBytes = frameAndPadding
                return res
            }
            res.freeFormatBytes = 0
        }
        i = i + 1
        mp3p = mp3p.slice(1, mp3p.size - 1)
    }
    res.offset = i
    res.frameBytes = 0
    return res
}
