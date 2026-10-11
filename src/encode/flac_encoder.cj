// ============================================================
// FLAC 编码器（纯仓颉，R3）—— AudioBuffer(f32 交错) → FLAC 文件映像
//
// 实现范围（v0.1.5）：
//   - 元数据：仅 STREAMINFO（MD5 置 0，规范允许表示「未计算」）
//   - 定长分帧（4096 帧，尾帧允许更短）
//   - 子帧类型自动择优：constant / verbatim / fixed 预测阶 0..4
//   - 残差：单分区（分区阶 0）Rice 编码，k 参数按最小位长遍历 0..14
//   - 位深：仅 16（s16 口径，与 wavBytes 的缩放一致）
//   - CRC：帧头 CRC-8 / 帧 CRC-16 复用 format 包的 crc8Of / crc16Of
//     （protected 同模块可见；表生成与解码侧同源，保证两侧一致）
//
// 验证方式：① 编码 → audio4cj FLAC 解码 roundtrip 逐样本比对；
//   ② ffmpeg 交叉验证（解码 MD5 与原 WAV 一致，见缺口评估文档 R3 记录）。
// 已知边界：不做立体声通道联合编码（left/side/right），压缩率略低于 libFLAC；
//           不计算 MD5；非实时（逐位写入有优化空间）。
// ============================================================
package audio4cj.encode

import audio4cj.core.Audio4CjException
import audio4cj.format.crc16Of
import audio4cj.format.crc8Of
import audio4cj.pcm.AudioBuffer
import std.collection.ArrayList

/// 定长分帧的每帧帧数
private const FLAC_BLOCK_FRAMES: Int64 = 4096

// ============================================================
// 位写入器（MSB 优先，FLAC 位流序）
// ============================================================

class BitWriter {
    private let out: ArrayList<Byte> = ArrayList<Byte>()
    private var acc: UInt8 = 0
    private var nbits: Int32 = 0

    /// 写入 n 位（MSB 优先）。n=8 且当前字节对齐时走整字节快速路径。
    func writeBits(v: UInt64, n: Int32): Unit {
        if (nbits == 0 && n >= 8 && n % 8 == 0) {
            var s = n - 8
            while (s >= 0) {
                out.add(UInt8((v >> s) & 0xFF))
                s -= 8
            }
            return
        }
        var i = n - 1
        while (i >= 0) {
            let bit = UInt8((v >> i) & 1)
            acc = ((acc << 1) & 0xFF) | bit
            nbits += 1
            if (nbits == 8) {
                out.add(acc)
                acc = 0
                nbits = 0
            }
            i -= 1
        }
    }

    /// 写有符号整数的低 n 位（二进制补码，FLAC 样本/预热样本口径）
    func writeSigned(v: Int64, n: Int32): Unit {
        let mask = (Int64(1) << n) - 1
        writeBits(UInt64(v & mask), n)
    }

    /// Rice 一元码：q 个 0 + 1 个 1
    func writeUnary(q: Int64): Unit {
        var i: Int64 = 0
        while (i < q) {
            writeBits(0, 1)
            i += 1
        }
        writeBits(1, 1)
    }

    /// 补齐到字节边界（补 0）
    func align(): Unit {
        while (nbits != 0) {
            writeBits(0, 1)
        }
    }

    func toBytes(): Array<Byte> {
        align()
        return out.toArray()
    }
}

// ============================================================
// 工具
// ============================================================

/// 有符号 → 无符号（FLAC 残差 Rice 用的 zigzag 映射）
private func zigzag(v: Int64): UInt64 {
    return UInt64((v << 1) ^ (v >> 63))
}

/// 固定预测器系数（阶 1..4）
private func fixedCoefs(order: Int64): Array<Int64> {
    let coefs = match (order) {
        case 1 => [1]
        case 2 => [2, -1]
        case 3 => [3, -3, 1]
        case _ => [4, -6, 4, -1]
    }
    return coefs
}

/// 计算固定阶 order 的残差（长度 = count - order），写入调用方提供的 res
private func fixedResiduals(samples: Array<Int64>, count: Int64, order: Int64, res: Array<Int64>): Unit {
    let coefs = fixedCoefs(order)
    for (j in 0..count - order) {
        var acc: Int64 = 0
        for (t in 0..order) {
            acc += coefs[t] * samples[order + j - 1 - t]
        }
        res[j] = samples[order + j] - acc
    }
}

/// 在 k ∈ 0..14 中选最小位长的 Rice 参数。返回 (k, 总位数)。
private func bestRiceK(res: Array<Int64>, count: Int64): (Int64, Int64) {
    var bestK: Int64 = 0
    var best: Int64 = Int64.Max
    for (k in 0..15) {
        var sum: Int64 = 0
        for (i in 0..count) {
            sum += Int64(zigzag(res[i]) >> k) + 1 + k
        }
        if (sum < best) {
            best = sum
            bestK = k
        }
    }
    return (bestK, best)
}

// ============================================================
// 子帧编码（自动择优：constant / verbatim / fixed 0..4）
// ============================================================

private func isConstantBlock(samples: Array<Int64>, count: Int64): Bool {
    for (i in 1..count) {
        if (samples[i] != samples[0]) {
            return false
        }
    }
    return true
}

/// 固定预测子帧的择优结果
internal struct FixedPlan {
    internal var order: Int64 = 0
    internal var riceK: Int64 = 0
    internal var res: Array<Int64> = Array<Int64>()
}

/// 在固定阶 0..4 中择优。
private func pickFixedPlan(samples: Array<Int64>, count: Int64, bits: Int32): FixedPlan {
    var plan = FixedPlan()
    var bestCost: Int64 = Int64.Max
    for (order in 0..5) {
        let res = Array<Int64>(count - order, repeat: 0)
        fixedResiduals(samples, count, order, res)
        let (k, cost) = bestRiceK(res, count - order)
        let total = 8 + Int64(order) * Int64(bits) + 6 + cost
        if (total < bestCost) {
            bestCost = total
            plan.order = order
            plan.riceK = k
            plan.res = res
        }
    }
    return plan
}

private func writeSubframeHeader(bw: BitWriter, typeBits: UInt64): Unit {
    bw.writeBits(0, 1) // pad
    bw.writeBits(typeBits, 6) // 子帧类型
    bw.writeBits(0, 1) // wasted bits
}

private func encodeConstant(bw: BitWriter, value: Int64, bits: Int32): Unit {
    writeSubframeHeader(bw, 0) // 000000 = constant
    bw.writeSigned(value, bits)
}

private func encodeVerbatim(bw: BitWriter, samples: Array<Int64>, count: Int64, bits: Int32): Unit {
    writeSubframeHeader(bw, 1) // 000001 = verbatim
    for (i in 0..count) {
        bw.writeSigned(samples[i], bits)
    }
}

private func encodeFixed(bw: BitWriter, samples: Array<Int64>, count: Int64, bits: Int32, plan: FixedPlan): Unit {
    writeSubframeHeader(bw, UInt64(8 + plan.order)) // 001000 + order
    for (i in 0..plan.order) {
        bw.writeSigned(samples[i], bits) // 预热样本
    }
    bw.writeBits(0, 2) // 残差：2 位填充
    bw.writeBits(0, 4) // 分区阶 0（单分区覆盖全部残差）
    bw.writeBits(UInt64(plan.riceK), 4) // Rice 参数
    for (i in 0..count - plan.order) {
        let u = zigzag(plan.res[i])
        bw.writeUnary(Int64(u >> plan.riceK))
        if (plan.riceK > 0) {
            bw.writeBits(u & ((UInt64(1) << plan.riceK) - 1), Int32(plan.riceK))
        }
    }
}

private func encodeSubframe(bw: BitWriter, samples: Array<Int64>, count: Int64, bits: Int32): Unit {
    if (isConstantBlock(samples, count)) {
        encodeConstant(bw, samples[0], bits)
        return
    }
    let plan = pickFixedPlan(samples, count, bits)
    // verbatim 成本 = count × bits；噪声段可能优于 rice，择优
    let riceCost = bestRiceK(plan.res, count - plan.order)[1]
    let fixedCost = 8 + Int64(plan.order) * Int64(bits) + 6 + riceCost
    if (count * Int64(bits) < fixedCost) {
        encodeVerbatim(bw, samples, count, bits)
        return
    }
    encodeFixed(bw, samples, count, bits, plan)
}

// ============================================================
// 帧编码
// ============================================================

/// 写 FLAC 的 UTF-8 式变长帧号（1..4 字节，覆盖到 2^21 帧 ≈ 2^33 样本）
private func writeUtf8Number(bw: BitWriter, n: Int64): Unit {
    if (n < 0x80) {
        bw.writeBits(UInt64(n), 8)
    } else if (n < 0x800) {
        bw.writeBits(UInt64(0xC0 | (n >> 6)), 8)
        bw.writeBits(UInt64(0x80 | (n & 0x3F)), 8)
    } else if (n < 0x10000) {
        bw.writeBits(UInt64(0xE0 | (n >> 12)), 8)
        bw.writeBits(UInt64(0x80 | ((n >> 6) & 0x3F)), 8)
        bw.writeBits(UInt64(0x80 | (n & 0x3F)), 8)
    } else {
        bw.writeBits(UInt64(0xF0 | (n >> 18)), 8)
        bw.writeBits(UInt64(0x80 | ((n >> 12) & 0x3F)), 8)
        bw.writeBits(UInt64(0x80 | ((n >> 6) & 0x3F)), 8)
        bw.writeBits(UInt64(0x80 | (n & 0x3F)), 8)
    }
}

/// 一帧的编码输入（封装参数，避免长参数列表）
internal struct FrameSpec {
    internal var blocks: Array<Array<Int64>> = Array<Array<Int64>>() // 每声道样本块
    internal var framesInBlock: Int64 = 0 // 本帧帧数（尾块可短）
    internal var bits: Int32 = 16 // 样本位深
    internal var channels: Int64 = 0
    internal var sampleRate: Int64 = 0
    internal var frameIndex: Int64 = 0
}

/// 编码一帧：帧头（同步码 + 编码字段 + 帧尾扩展 + CRC-8）→ 子帧 → CRC-16
private func encodeFrame(spec: FrameSpec): Array<Byte> {
    let hw = BitWriter()
    // 同步码 14 位 0b11111111111110：前两字节即 0xFF 0xF8
    hw.writeBits(0b11111111111110, 14)
    hw.writeBits(0, 1) // 保留位
    hw.writeBits(0, 1) // 定长块策略
    let fullBlock = spec.framesInBlock == FLAC_BLOCK_FRAMES
    if (fullBlock) {
        hw.writeBits(12, 4) // 4096 = 256 × 2^(12-8)，无扩展
    } else {
        hw.writeBits(7, 4) // 尾块：16 位块大小扩展在帧头末尾
    }
    hw.writeBits(13, 4) // 采样率：16 位 Hz 扩展在帧头末尾
    hw.writeBits(UInt64(spec.channels - 1), 4) // 独立声道分配
    hw.writeBits(4, 3) // 位深 16
    hw.writeBits(0, 1) // 保留位
    writeUtf8Number(hw, spec.frameIndex)
    // 帧尾扩展区（顺序：块大小扩展 → 采样率扩展，均在 CRC-8 之前）
    if (!fullBlock) {
        hw.writeBits(UInt64(spec.framesInBlock - 1), 16)
    }
    hw.writeBits(UInt64(spec.sampleRate), 16)
    let head = hw.toBytes()
    let crc8 = crc8Of(head, 0, head.size)

    let bw = BitWriter()
    for (b in head) {
        bw.writeBits(UInt64(b), 8)
    }
    bw.writeBits(UInt64(crc8), 8)
    for (ch in 0..spec.channels) {
        encodeSubframe(bw, spec.blocks[ch], spec.framesInBlock, spec.bits)
    }
    bw.align()
    let body = bw.toBytes()
    let crc16 = crc16Of(body, 0, body.size)
    let out = ArrayList<Byte>()
    for (b in body) {
        out.add(b)
    }
    out.add(UInt8((crc16 >> 8) & 0xFF))
    out.add(UInt8(crc16 & 0xFF))
    return out.toArray()
}

// ============================================================
// 对外入口
// ============================================================

/// 组装文件头：fLaC 魔数 + STREAMINFO（最后一块元数据，MD5 置 0）
private func buildStreamInfo(sampleRate: Int64, channels: Int64, frames: Int64, minBlock: Int64, maxBlock: Int64): Array<Byte> {
    let head = BitWriter()
    head.writeBits(0x66, 8) // f
    head.writeBits(0x4C, 8) // L
    head.writeBits(0x61, 8) // a
    head.writeBits(0x43, 8) // C
    head.writeBits(1, 1) // 最后一个元数据块
    head.writeBits(0, 7) // 类型 0 = STREAMINFO
    head.writeBits(34, 24) // 块长 34 字节
    head.writeBits(UInt64(minBlock), 16)
    head.writeBits(UInt64(maxBlock), 16)
    head.writeBits(0, 24) // min framesize（未知）
    head.writeBits(0, 24) // max framesize（未知）
    head.writeBits(UInt64(sampleRate), 20)
    head.writeBits(UInt64(channels - 1), 3)
    head.writeBits(15, 5) // 位深 16 = (16 - 1)
    head.writeBits(UInt64(frames), 36)
    // MD5 128 位（未计算，规范允许全 0）
    head.writeBits(0, 32)
    head.writeBits(0, 32)
    head.writeBits(0, 32)
    head.writeBits(0, 32)
    let bytes = head.toBytes()
    if (bytes.size != 42) {
        throw Audio4CjException("flacBytes: STREAMINFO 装配异常（${bytes.size} ≠ 42 字节）")
    }
    return bytes
}

/// 逐帧编码全部样本
private func encodeAllFrames(ints: Array<Int64>, frames: Int64, channels: Int64, sampleRate: Int64, bits: Int32): ArrayList<Byte> {
    let out = ArrayList<Byte>()
    let fullFrames = frames / FLAC_BLOCK_FRAMES
    let tail = frames % FLAC_BLOCK_FRAMES
    let frameCount = fullFrames + (if (tail > 0) {
        1
    } else {
        0
    })
    for (f in 0..frameCount) {
        let framesInBlock = if (f < fullFrames) {
            FLAC_BLOCK_FRAMES
        } else {
            tail
        }
        // 抽取各声道块（声道主序）
        let blocks = ArrayList<Array<Int64>>()
        for (ch in 0..channels) {
            var block = Array<Int64>(framesInBlock, repeat: 0)
            for (fr in 0..framesInBlock) {
                block[fr] = ints[(f * FLAC_BLOCK_FRAMES + fr) * channels + ch]
            }
            blocks.add(block)
        }
        var spec = FrameSpec()
        spec.blocks = blocks.toArray()
        spec.framesInBlock = framesInBlock
        spec.bits = bits
        spec.channels = channels
        spec.sampleRate = sampleRate
        spec.frameIndex = f
        for (b in encodeFrame(spec)) {
            out.add(b)
        }
    }
    return out
}

/// 把 f32 交错 PCM 编码为完整 FLAC 文件映像（16 位，s16 口径与 wavBytes 一致）。
///
/// 语义与边界：
/// - 采样率/声道数取自 buffer；定长分帧 4096 帧，尾帧允许更短；子帧类型自动择优
/// - STREAMINFO 的 MD5 置 0（规范允许，表示未计算）；
///   压缩率低于 libFLAC（无立体声联合编码、搜索阶有限），但格式完全合法
///
/// 抛出：
///   - 位深非 16，或声道数超出 1..8 → `Audio4CjException`
public func flacBytes(buffer: AudioBuffer, bitsPerSample!: Int64 = 16): Array<Byte> {
    if (bitsPerSample != 16) {
        throw Audio4CjException("flacBytes: 目前仅支持 16 位编码（收到 ${bitsPerSample}）")
    }
    let channels = buffer.channels
    if (channels < 1 || channels > 8) {
        throw Audio4CjException("flacBytes: 声道数 ${channels} 超出 FLAC 支持范围（1..8）")
    }
    let samples = buffer.samples
    let frames = buffer.frameCount
    // f32 交错 [-1,1] → 16 位整数码样本（Int64 承载，帧内预测在整数域进行）
    let ints = Array<Int64>(samples.size, repeat: 0)
    for (i in 0..samples.size) {
        var v = Float64(samples[i]) * 32768.0
        if (v > 32767.0) {
            v = 32767.0
        }
        if (v < -32768.0) {
            v = -32768.0
        }
        ints[i] = Int64(v)
    }
    // 规划分帧（STREAMINFO 的 min/max 块大小按实际值声明）
    let fullFrames = frames / FLAC_BLOCK_FRAMES
    let tail = frames % FLAC_BLOCK_FRAMES
    let minBlock = if (tail > 0) {
        tail
    } else {
        FLAC_BLOCK_FRAMES
    }
    let maxBlock = if (fullFrames > 0) {
        FLAC_BLOCK_FRAMES
    } else {
        minBlock
    }
    var out = ArrayList<Byte>()
    for (b in buildStreamInfo(buffer.sampleRate, channels, frames, minBlock, maxBlock)) {
        out.add(b)
    }
    let body = encodeAllFrames(ints, frames, channels, buffer.sampleRate, 16)
    for (b in body) {
        out.add(b)
    }
    return out.toArray()
}
