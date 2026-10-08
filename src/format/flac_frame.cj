package audio4cj.format

import std.time.*
import audio4cj.core.CorruptedFileException
import std.collection.ArrayList
// ============================================================================
// FLAC 分配闸门（受 testdata/diag/phase_timing.on 守卫，默认零开销）
//
// 【为什么需要】flac_frame.cj 里有 7 处每次调用都新建的大缓冲（blockSize 通常 4096
//   ⇒ 每块 32 KB）。但"该不该把它们改成复用池"不能靠估：本仓已两次证明微基准
//   会高估（形态复刻带进生产代码没有的开销）。唯一可信的判据是**在真实素材上量
//   出分配占整帧的比例** —— 那就是池的天花板。
//
// 【怎么量】所有大分配都走 flacAllocInt64（与原语句逐一对应，只是多了一对取时），
//   累计到 allocNs；整帧耗时由流层计入 frameNs。两者之比即答案。
// ============================================================================
protected class FlacPhaseStats {
    var frames: Int64 = 0
    var frameNs: Int64 = 0
    var allocNs: Int64 = 0
    var lastFrameNs: Int64 = 0
    var lastAllocNs: Int64 = 0
}

protected let FLAC_PHASE = FlacPhaseStats()
private let FLAC_PHASE_BASE = MonoTime.now()

protected func flacPhaseNow(): Int64 {
    (MonoTime.now() - FLAC_PHASE_BASE).toNanoseconds()
}

/// 大缓冲的统一入口：语义与 `flacAllocInt64(n)` 完全相同，只多一对取时。
protected func flacAllocInt64(n: Int64): Array<Int64> {
    mp3PhaseTick()
    if (!MP3_PHASE.enabled) {
        return Array<Int64>(n, repeat: 0)
    }
    let t0 = flacPhaseNow()
    let a = Array<Int64>(n, repeat: 0)
    FLAC_PHASE.allocNs += (flacPhaseNow() - t0)
    a
}

/// 每帧一次：累计并按间隔打印区间增量（与 MP3 的 PHASE 同构）。
protected func flacPhaseFrameDone(): Unit {
    mp3PhaseTick()
    if (!MP3_PHASE.enabled) {
        return
    }
    FLAC_PHASE.frames += 1
    if (FLAC_PHASE.frames % 1000 != 0) {
        return
    }
    let dFrame = FLAC_PHASE.frameNs - FLAC_PHASE.lastFrameNs
    let dAlloc = FLAC_PHASE.allocNs - FLAC_PHASE.lastAllocNs
    FLAC_PHASE.lastFrameNs = FLAC_PHASE.frameNs
    FLAC_PHASE.lastAllocNs = FLAC_PHASE.allocNs
    let pct = if (dFrame <= 0) {
        0.0
    } else {
        100.0 * Float64(dAlloc) / Float64(dFrame)
    }
    println(
        "FLACPHASE ${FLAC_PHASE.frames} 帧：整帧 ${dFrame / 1000} us、" +
            "其中大缓冲分配 ${dAlloc / 1000} us（占 ${pct}%）")
}

/* ============================================================================
 * FLAC 帧解码（纯仓颉）
 *
 * 【本文件的范围】
 *   只做「给定一段已加载的字节 + 位偏移 -> 一帧的整数样本」。
 *   **不含**文件 I/O、不含窗口缓冲、不含 f32 归一化 —— 那些分别属于
 *   format/flac_bitstream.cj（流式内核）与调用方的转换步骤。
 *   这样帧解码可以独立于流式机制被测试。
 *
 * 【为什么输出整数样本而不是 f32】
 *   FLAC 的解码路径**全程整数运算**（这是它能逐位无损的原因）。
 *   把 f32 归一化留到最后一刻，既让本文件的算术不引入任何浮点误差，
 *   也让"8 位 FLAC 是有符号"这类语义差异集中在转换处处理
 *   （注意：WAV 的 8 位是**无符号**，两者不同，不能共用 pcmToF32）。
 *
 * 【溢出：本文件最需要小心的工程问题】
 *   仓颉的整数运算**默认带溢出检查**（溢出抛 OverflowException，而非回绕）。
 *   合法 FLAC 文件不会溢出（编码器保证），但**损坏或恶意文件可以** ——
 *   而库的契约要求错误一律用库内异常表达。因此本文件在所有"输入可影响
 *   算术幅度"的地方都做了显式防护，见 §防护点 注释。
 *   不能用 @OverflowWrapping 一包了事：那样会把损坏文件的症状从"明确报错"
 *   降级为"静默产出错误样本"，比崩溃更难查。
 * ========================================================================== */

/// 帧头解析结果。
protected class FlacFrameHeader {
    /// 帧内样本数（块大小）。
    protected let blockSize: Int64

    /// 声道分配方式（0..7 独立声道、8 left/side、9 right/side、10 mid/side）。
    protected let channelAssignment: Int64

    /// 本帧的声道数。
    protected let channels: Int64

    /// 本帧的样本位深（取自帧头；为 0 时由 STREAMINFO 补齐）。
    protected let bitsPerSample: Int64

    /// 帧体（第一个子帧）的起始位偏移 —— 供调用方重试与诊断使用。
    protected let bodyStartBit: Int64

    /// 帧头末尾的**字节**偏移（窗口相对），即 CRC-8 那个字节**之后**的位置。
    ///
    /// 供流式层重算帧头 CRC-8 用：需要覆盖的区间是
    /// `[帧起点, headerEndByte - 1)`，而 CRC 字节本身在 `headerEndByte - 1`。
    /// 帧头必然是整数字节（同步码 14 位 + 保留 2 位 = 2 字节，其余字段皆整字节），
    /// 故这里可以直接用整除以 8 得到。
    protected let headerEndByte: Int64

    protected init(
        blockSize: Int64,
        channelAssignment: Int64,
        channels: Int64,
        bitsPerSample: Int64,
        bodyStartBit: Int64,
        headerEndByte: Int64
    ) {
        this.blockSize = blockSize
        this.channelAssignment = channelAssignment
        this.channels = channels
        this.bitsPerSample = bitsPerSample
        this.bodyStartBit = bodyStartBit
        this.headerEndByte = headerEndByte
    }
}

/// 一帧的解码结果（按声道分开的整数样本）。
protected class FlacFrame {
    protected let blockSize: Int64

    /// 声道数。
    protected let channels: Int64

    /// 声道分配方式。解码器自己不需要它（去相关已在此完成），
    /// 但**对测试与诊断是必需的** —— 定位"样本值不一致"时，
    /// 第一件要知道的事就是该帧用的是独立声道还是哪种去相关。
    protected let channelAssignment: Int64

    /// 每声道一个数组，长度均为 blockSize。
    protected let samples: ArrayList<Array<Int64>>

    /// 本帧末尾的**字节**偏移（窗口相对），即 CRC-16 那两个字节**之后**的位置。
    ///
    /// 供流式层重算帧尾 CRC-16 用：需要覆盖的区间是
    /// `[帧起点, frameEndByte - 2)`，CRC 两字节在 `frameEndByte - 2` 起
    /// （大端存放）。帧尾在 CRC-16 之前已按规范对齐到字节边界，故可用整除以 8。
    protected let frameEndByte: Int64

    /// 帧头末尾的**字节**偏移（窗口相对），与 `FlacFrameHeader.headerEndByte` 同义。
    ///
    /// 【为什么帧上也要带一份】流式层做 CRC 校验时只拿得到 `FlacFrame`，
    /// 拿不到内部的 `FlacFrameHeader`（帧头在 decodeFrame 内部就消费掉了）。
    /// 校验需要两个区间，故把帧头末尾一并带出来。
    protected let headerEndByte: Int64

    protected init(
        blockSize: Int64,
        channels: Int64,
        channelAssignment: Int64,
        samples: ArrayList<Array<Int64>>,
        frameEndByte: Int64,
        headerEndByte: Int64
    ) {
        this.blockSize = blockSize
        this.channels = channels
        this.channelAssignment = channelAssignment
        this.samples = samples
        this.frameEndByte = frameEndByte
        this.headerEndByte = headerEndByte
    }
}

// ---------------------------------------------------------------------------
// 帧头
// ---------------------------------------------------------------------------

/// 帧同步码（14 位）。
private let FLAC_FRAME_SYNC: UInt64 = 0b11111111111110

/// 解析帧头。当前位置须位于帧起点（同步码处）。
///
/// 【防护点 1】同步码与两个保留位必须严格匹配 —— 这是"从头开始解码一帧"的
/// 前提；不匹配说明要么调用方位置错了，要么文件损坏/根本不是 FLAC。
protected func parseFrameHeader(reader: BitReader, info: FlacStreamInfo): FlacFrameHeader {
    if (reader.readBits(14) != FLAC_FRAME_SYNC) {
        throw CorruptedFileException("FLAC 帧同步码不匹配（当前位 ${reader.bitPosition() - 14}）")
    }
    // 保留位必须为 0
    if (reader.readBits(1) != UInt64(0)) {
        throw CorruptedFileException("FLAC 帧头保留位非 0")
    }

    // 0 = 定长块，1 = 变长块。本库按顺序解码帧、不依赖该标志，读掉即可。
    // 注意用 `let _ =` 而不是 `let _name =`：仓颉只把下划线**单独**作模式时才
    // 视为丢弃，`_name` 仍是一个变量，会触发 unused 告警。
    let _ = reader.readBits(1)
    let blockSizeCode = Int64(reader.readBits(4))
    let sampleRateCode = Int64(reader.readBits(4))
    let channelAssignment = Int64(reader.readBits(4))
    let sampleSizeCode = Int64(reader.readBits(3))

    // 第二个保留位
    if (reader.readBits(1) != UInt64(0)) {
        throw CorruptedFileException("FLAC 帧头第二个保留位非 0")
    }

    // 帧号或样本号（UTF-8 式变长整数）。
    // 本库按顺序解码帧、不依赖它推进进度，但**必须把它读掉** ——
    // 它占据帧头中长度可变的位置，跳过会使后续所有字段错位。
    let _ = reader.readUtf8Number()

    // 块大小的可变部分
    var blockSize: Int64 = match (blockSizeCode) {
        case 0 => throw CorruptedFileException("FLAC 块大小编码 0 为保留值")
        case 1 => 192
        case 2 => 576
        case 3 => 1152
        case 4 => 2304
        case 5 => 4608
        case 6 => Int64(reader.readBits(8)) + 1
        case 7 => Int64(reader.readBits(16)) + 1
        case 8 => 256
        case 9 => 512
        case 10 => 1024
        case 11 => 2048
        case 12 => 4096
        case 13 => 8192
        case 14 => 16384
        case _ => 32768
    }

    // 采样率的可变部分（本库以 STREAMINFO 为准，此处只需把位读掉）
    parseSampleRateExtension(reader, sampleRateCode)

    // 帧头的 CRC-8（1 字节）。
    // **必须读掉**：它是帧体起点的定位依据，漏读会让第一个子帧从错的位开始解析。
    // （实测代价：漏读后报的是"子帧填充位非 0"，报错点离真正的错误远了一步。
    //   好在填充位校验把错位挡在了帧体入口，没有演变成样本值悄悄偏掉。）
    //
    // 【本版未校验 CRC】：校验需要拿到帧头对应的**原始字节**重算，
    // 而本函数只持有位读取器；将在流式内核（flac_bitstream.cj）中
    // 与帧尾 CRC-16 一并接入 —— 那里才有完整的帧字节窗口。
    let _ = reader.readBits(8)

    // 声道数与（可能来自 STREAMINFO 的）位深
    let channels = match (channelAssignment) {
        case 0 => 1
        case 1 => 2
        case 2 => 3
        case 3 => 4
        case 4 => 5
        case 5 => 6
        case 6 => 7
        case 7 => 8
        case 8 | 9 | 10 => 2
        case _ => throw CorruptedFileException("FLAC 声道分配 ${channelAssignment} 为保留值")
    }

    let bitsPerSample = match (sampleSizeCode) {
        case 0 => info.bitsPerSample
        case 1 => 8
        case 2 => 12
        case 4 => 16
        case 5 => 20
        case 6 => 24
        case 7 => 32
        case _ => throw CorruptedFileException("FLAC 样本位宽编码 ${sampleSizeCode} 非法")
    }

    if (blockSize <= 0) {
        throw CorruptedFileException("FLAC 块大小 ${blockSize} 非法")
    }

    FlacFrameHeader(
        blockSize,
        channelAssignment,
        channels,
        bitsPerSample,
        reader.bitPosition(), // 帧体起始位（= CRC-8 之后）
        reader.bitPosition() / 8 // 帧头末尾字节偏移（供流式层重算 CRC-8）
    )
}

/// 读掉采样率编码带来的扩展位（取值本身以 STREAMINFO 为准）。
private func parseSampleRateExtension(reader: BitReader, code: Int64): Unit {
    match (code) {
        case 12 => reader.readBits(8) // kHz
        case 13 => reader.readBits(16) // Hz
        case 14 => reader.readBits(16) // 十 Hz
        case 15 => throw CorruptedFileException("FLAC 采样率编码 15 为非法值")
        case _ => ()
    }
}

// ---------------------------------------------------------------------------
// 残差（Rice 编码，两种分区方法）
// ---------------------------------------------------------------------------

/// 解码残差，返回长度 = blockSize 的残差数组。
///
/// 【防护点 2：Rice 商的上界】
///   一元码在损坏文件上可能读出一个极大的商，`商 << 参数` 会撞上仓颉的
///   溢出检查并抛出非库异常。这里显式设上界：合法 FLAC 的残差幅度受
///   位深约束，商不可能接近 2^30。
private func decodeResidual(reader: BitReader, blockSize: Int64, predictorOrder: Int64): Array<Int64> {
    let method = Int64(reader.readBits(2))
    if (method > 1) {
        throw CorruptedFileException("FLAC 残差编码方法 ${method} 为保留值")
    }
    let paramBits = if (method == 0) {
        4
    } else {
        5
    }
    let escape = if (method == 0) {
        0b1111
    } else {
        0b11111
    }

    let partitionOrder = Int64(reader.readBits(4))
    let partitions = Int64(1) << partitionOrder
    if (blockSize % partitions != 0) {
        throw CorruptedFileException("FLAC 分区数 ${partitions} 无法整除块大小 ${blockSize}")
    }

    let out = flacAllocInt64(blockSize)
    var index: Int64 = 0
    var p: Int64 = 0
    while (p < partitions) {
        let param = Int64(reader.readBits(paramBits))

        // 每个分区的样本数：**第一个分区要扣掉预测器阶数**
        var count = blockSize / partitions
        if (p == 0) {
            count -= predictorOrder
        }
        if (count < 0) {
            throw CorruptedFileException("FLAC 残差分区样本数为负（预测阶数 ${predictorOrder}）")
        }

        if (param == escape) {
            // 逃逸：随后是固定位宽的原始样本
            let rawBits = Int64(reader.readBits(5))
            if (rawBits > 32) {
                throw CorruptedFileException("FLAC 残差逃逸位宽 ${rawBits} 非法")
            }
            var i: Int64 = 0
            while (i < count) {
                out[index] = if (rawBits == 0) {
                    0
                } else {
                    reader.readSignedBits(rawBits)
                }
                index += 1
                i += 1
            }
        } else {
            var i: Int64 = 0
            while (i < count) {
                let quotient = reader.readUnary()
                if (quotient > 0x3FFFFFFF) {
                    throw CorruptedFileException("FLAC 残差商过大（${quotient}），文件可能已损坏")
                }
                let remainder = Int64(reader.readBits(param))
                var value = (quotient << param) | remainder
                // ZigZag 解码：偶数 -> 正，奇数 -> 负
                value = if ((value & 1) == 1) {
                    -((value >> 1) + 1)
                } else {
                    value >> 1
                }
                out[index] = value
                index += 1
                i += 1
            }
        }
        p += 1
    }
    out
}

// ---------------------------------------------------------------------------
// 子帧（四种预测类型 + wasted bits）
// ---------------------------------------------------------------------------

/// 解码一个子帧，返回长度 = blockSize 的**已去 wasted bits**的样本。
private func decodeSubframe(reader: BitReader, bitsPerSample: Int64, blockSize: Int64): Array<Int64> {
    // 填充位必须为 0
    if (reader.readBits(1) != UInt64(0)) {
        throw CorruptedFileException("FLAC 子帧填充位非 0")
    }
    let subframeType = Int64(reader.readBits(6))
    let hasWasted = reader.readBits(1) == UInt64(1)

    var wasted = 0
    if (hasWasted) {
        // 一元码：wasted = k，其中读到的是 k-1 个 0
        wasted = Int64(reader.readUnary()) + 1
    }

    let effectiveBits = bitsPerSample - wasted
    if (effectiveBits < 0) {
        throw CorruptedFileException("FLAC wasted bits ${wasted} 超过位深 ${bitsPerSample}")
    }

    let samples = match (subframeType) {
        case 0 => decodeConstant(reader, effectiveBits, blockSize)
        case 1 => decodeVerbatim(reader, effectiveBits, blockSize)
        case 8 => decodeFixed(reader, 0, effectiveBits, blockSize)
        case 9 => decodeFixed(reader, 1, effectiveBits, blockSize)
        case 10 => decodeFixed(reader, 2, effectiveBits, blockSize)
        case 11 => decodeFixed(reader, 3, effectiveBits, blockSize)
        case 12 => decodeFixed(reader, 4, effectiveBits, blockSize)
        case _ =>
            if (subframeType >= 32) {
                decodeLpc(reader, subframeType - 31, effectiveBits, blockSize)
            } else {
                throw CorruptedFileException("FLAC 子帧类型 ${subframeType} 为保留值")
            }
    }

    // 还原 wasted bits：解码时按 (位深 - wasted) 处理，这里左移回去
    if (wasted > 0) {
        var i: Int64 = 0
        while (i < blockSize) {
            // 【防护点 3】左移可能溢出（损坏文件的 wasted 可以很大）
            let v = samples[i]
            if (v > (Int64.Max >> wasted) || v < (Int64.Min >> wasted)) {
                throw CorruptedFileException("FLAC wasted bits 还原时溢出（wasted=${wasted}）")
            }
            samples[i] = v << wasted
            i += 1
        }
    }
    samples
}

/// CONSTANT 子帧：整块同一个值。
private func decodeConstant(reader: BitReader, bitsPerSample: Int64, blockSize: Int64): Array<Int64> {
    let value = reader.readSignedBits(bitsPerSample)
    let out = flacAllocInt64(blockSize)
    var i: Int64 = 0
    while (i < blockSize) {
        out[i] = value
        i += 1
    }
    out
}

/// VERBATIM 子帧：未压缩，逐样本位宽 = 位深。
private func decodeVerbatim(reader: BitReader, bitsPerSample: Int64, blockSize: Int64): Array<Int64> {
    let out = flacAllocInt64(blockSize)
    var i: Int64 = 0
    while (i < blockSize) {
        out[i] = reader.readSignedBits(bitsPerSample)
        i += 1
    }
    out
}

/// FIXED 子帧：order 阶定系数预测 + 残差。
///
/// 预测系数是固定的（0/1/2/3/4 阶），因此只需残差 + 前若干样本即可还原。
private func decodeFixed(reader: BitReader, order: Int64, bitsPerSample: Int64, blockSize: Int64): Array<Int64> {
    if (order > blockSize) {
        throw CorruptedFileException("FLAC FIXED 阶数 ${order} 超过块大小 ${blockSize}")
    }
    let out = flacAllocInt64(blockSize)

    // 前 order 个样本是原样存储的
    var i: Int64 = 0
    while (i < order) {
        out[i] = reader.readSignedBits(bitsPerSample)
        i += 1
    }

    let residual = decodeResidual(reader, blockSize, order)

    i = order
    while (i < blockSize) {
        // 【索引口径】残差数组是**紧凑**的：residual[0] 对应第一个被预测的样本
        // （样本号 = order），而不是样本号 0。写成 residual[i] 会让整段预测
        // 从第一个样本起就错位 —— 且位消耗完全正确、只有样本值错，
        // 症状与"预测系数算错"极像，是本实现踩过的最隐蔽的一处。
        let r = residual[i - order]
        var predicted: Int64 = match (order) {
            case 0 => 0
            case 1 => out[i - 1]
            case 2 => 2 * out[i - 1] - out[i - 2]
            case 3 => 3 * out[i - 1] - 3 * out[i - 2] + out[i - 3]
            case _ => 4 * out[i - 1] - 6 * out[i - 2] + 4 * out[i - 3] - out[i - 4]
        }
        // 【防护点 4】预测值与残差相加可能溢出
        let sum = predicted + r
        checkSampleRange(sum, bitsPerSample)
        out[i] = sum
        i += 1
    }
    out
}

/// LPC 子帧：order 阶线性预测，系数显式存储在帧内。
private func decodeLpc(reader: BitReader, order: Int64, bitsPerSample: Int64, blockSize: Int64): Array<Int64> {
    if (order > blockSize) {
        throw CorruptedFileException("FLAC LPC 阶数 ${order} 超过块大小 ${blockSize}")
    }
    if (order > 32) {
        throw CorruptedFileException("FLAC LPC 阶数 ${order} 超过规范上限 32")
    }

    let out = flacAllocInt64(blockSize)

    // 前 order 个样本原样存储
    var i: Int64 = 0
    while (i < order) {
        out[i] = reader.readSignedBits(bitsPerSample)
        i += 1
    }

    // 系数精度（4 位，0b1111 非法）
    let precisionCode = Int64(reader.readBits(4))
    if (precisionCode == 0b1111) {
        throw CorruptedFileException("FLAC LPC 系数精度编码 0b1111 非法")
    }
    let precision = precisionCode + 1

    // 量化级移位（5 位有符号；负值表示左移）
    let shift = reader.readSignedBits(5)

    // 系数：共 order 个，每个 precision 位有符号
    let coef = flacAllocInt64(order)
    i = 0
    while (i < order) {
        coef[i] = reader.readSignedBits(precision)
        i += 1
    }

    let residual = decodeResidual(reader, blockSize, order)

    i = order
    while (i < blockSize) {
        // 累加：coef[j] 对应"更早"的样本，故用 i-1-j
        // 幅度分析：order<=32、|coef|<2^15、|样本|<2^32 -> |sum| < 2^52，Int64 安全
        var sum: Int64 = 0
        var j: Int64 = 0
        while (j < order) {
            sum += coef[j] * out[i - 1 - j]
            j += 1
        }

        // 应用移位。左移（shift 为负）需先确认不溢出 ——
        // 合法文件不会溢出，损坏文件在此被明确拒绝（见 §防护点 5）
        var restored: Int64 = 0
        if (shift < 0) {
            let left = -shift
            if (left > 32) {
                throw CorruptedFileException("FLAC LPC 左移位数 ${left} 过大")
            }
            if (sum > (Int64.Max >> left) || sum < (Int64.Min >> left)) {
                throw CorruptedFileException("FLAC LPC 左移溢出（shift=${shift}）")
            }
            restored = sum << left
        } else {
            restored = sum >> shift
        }

        // 同 FIXED：残差数组紧凑，索引要减去阶数
        let value = restored + residual[i - order]
        checkSampleRange(value, bitsPerSample)
        out[i] = value
        i += 1
    }
    out
}

/// 【防护点 5】样本值必须落在声明位深可表达的范围内。
///
/// 这条校验是"用规范约束挡住损坏输入"的关键：合法 FLAC 的样本必然在
/// [-2^(n-1), 2^(n-1)-1] 内，因此越界只可能来自损坏数据或算术溢出。
/// 没有它，损坏文件会静默产出听不出问题却完全错误的样本。
private func checkSampleRange(value: Int64, bitsPerSample: Int64): Unit {
    if (bitsPerSample <= 0 || bitsPerSample > 63) {
        return
    }
    let limit = Int64(1) << (bitsPerSample - 1)
    if (value >= limit || value < -limit) {
        throw CorruptedFileException("FLAC 样本值 ${value} 超出 ${bitsPerSample} 位可表达范围")
    }
}

// ---------------------------------------------------------------------------
// 帧级编排
// ---------------------------------------------------------------------------

/// 计算某一声道子帧的样本位宽。
///
/// 【为什么不是所有声道都用 bitsPerSample】
///   立体声去相关时 **side 声道的取值范围会多一位** ——
///   因为 side = left - right 的最小值可达 -(2^(n-1)) - (2^(n-1) - 1)，
///   需要 n+1 位才能无损表示。编码器据此用 bitsPerSample+1 位存储 side 声道，
///   解码端若仍按 bitsPerSample 读，就会**每个子帧少读一位**而失步。
///
///   三种去相关方式下 side 都在 ch1，唯独 right/side 把 side 放在 ch0：
///     left/side : ch0 = left,  ch1 = left  - right  -> ch1 是 side
///     right/side: ch0 = left - right, ch1 = right   -> ch0 是 side
///     mid/side  : ch0 = mid,   ch1 = left  - right  -> ch1 是 side
///
///   实测教训：本实现初版对所有声道统一用 bitsPerSample，结果是
///   **前 8 帧正确、第 9 帧失步** —— 因为前 8 帧恰好用独立声道存储，
///   第 9 帧才切到去相关模式。这类"取决于编码器逐帧选择"的差异，
///   只有靠与成熟实现逐样本对照才能稳定暴露。
private func subframeBits(bitsPerSample: Int64, channelAssignment: Int64, channel: Int64): Int64 {
    let isSide = match (channelAssignment) {
        case 8 => channel == 1
        case 9 => channel == 0
        case 10 => channel == 1
        case _ => false
    }
    if (isSide) {
        bitsPerSample + 1
    } else {
        bitsPerSample
    }
}

/// 解码一整帧（帧头 + 各声道子帧）。
///
/// 【防护点 6：声道去相关前的通道数一致性】
///   子帧数量由帧头的 channelAssignment 决定，与 STREAMINFO 的声道数不一致
///   属于结构损坏，直接拒绝。
protected func decodeFrame(reader: BitReader, info: FlacStreamInfo): FlacFrame {
    let header = parseFrameHeader(reader, info)

    if (header.channels != info.channels) {
        throw CorruptedFileException("FLAC 帧内声道数 ${header.channels} 与 STREAMINFO 的 ${info.channels} 不一致")
    }

    // 逐声道解出子帧。注意各声道的位宽**可能不同**：去相关模式下 side 声道多一位。
    let raw = ArrayList<Array<Int64>>()
    var ch: Int64 = 0
    while (ch < header.channels) {
        let bits = subframeBits(header.bitsPerSample, header.channelAssignment, ch)
        raw.add(decodeSubframe(reader, bits, header.blockSize))
        ch += 1
    }

    // 帧体在 CRC-16 之前会**填充到字节边界**（规范要求帧头与帧尾都字节对齐）。
    // 漏掉这一步对齐，读 CRC-16 与下一帧都会从错的位开始。
    //
    // 实测教训：这个缺口只在"子帧总位数不是 8 的倍数"时才暴露 ——
    // CONSTANT 子帧（1+6+1 + 位深 = 8+16 位）天然对齐，所以静音文件能过，
    // 而含 LPC/FIXED 的文件会在**第二帧**报"帧同步码不匹配"，
    // 且报错位偏移不是字节的整数倍（75490 / 8 = 9436.25）—— 这正是判断依据。
    reader.alignToByte()

    // 帧尾 CRC-16（2 字节）。**必须读掉**，否则下一帧会从错的位开始解析。
    // 【校验由流式层完成】重算需要帧的原始字节，本函数只持有位读取器；
    // 这里只把帧尾的字节偏移报出去（见 FlacFrame.frameEndByte）。
    let _ = reader.readBits(16)
    let frameEndByte = reader.bitPosition() / 8

    let samples = applyChannelDecorrelation(raw, header)
    FlacFrame(
        header.blockSize,
        header.channels,
        header.channelAssignment,
        samples,
        frameEndByte,
        header.headerEndByte
    )
}

/// 声道去相关：把帧内存储的（可能是 mid/side 等）通道还原为左右声道。
///
/// FLAC 的三种立体声去相关方式（规范附录说明）：
///   left/side : ch0 = left,          ch1 = left - right
///   right/side: ch0 = left - right,  ch1 = right
///   mid/side  : ch0 = (left+right)>>1, ch1 = left - right
/// 其中 mid/side 还原时需要把 mid 的左移一位补回（因为编码时右移丢了最低位），
/// 编码器把该位存进了 side 的最低位 —— 这是最容易写错的一处。
private func applyChannelDecorrelation(
    raw: ArrayList<Array<Int64>>,
    header: FlacFrameHeader
): ArrayList<Array<Int64>> {
    if (header.channelAssignment <= 7) {
        // 独立声道，无需还原
        return raw
    }

    if (header.channels != 2) {
        throw CorruptedFileException("FLAC 立体声去相关要求 2 声道，实得 ${header.channels}")
    }

    let a = raw[0]
    let b = raw[1]
    let n = header.blockSize
    let left = flacAllocInt64(n)
    let right = flacAllocInt64(n)

    var i: Int64 = 0
    while (i < n) {
        match (header.channelAssignment) {
            case 8 =>
                // left/side：left 已知，right = left - side
                left[i] = a[i]
                right[i] = a[i] - b[i]
            case 9 =>
                // right/side：side = left - right
                right[i] = b[i]
                left[i] = a[i] + b[i]
            case _ =>
                // mid/side
                let mid = (a[i] << 1) | (b[i] & 1)
                let side = b[i]
                left[i] = (mid + side) >> 1
                right[i] = (mid - side) >> 1
        }
        i += 1
    }

    let out = ArrayList<Array<Int64>>()
    out.add(left)
    out.add(right)
    out
}
