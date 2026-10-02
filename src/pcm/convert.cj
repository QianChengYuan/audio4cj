package audio4cj.pcm

/* ============================================================================
 * 位深转换 —— 开发文档 §3.2（pcm/convert.cj）
 *
 * 职责：把整型 PCM 字节流转换为统一的 f32 交错表示，取值范围 [-1.0, 1.0]。
 *
 * 归一化约定（与 dr_libs / ffmpeg 一致）：
 *   8  bit  无符号： (v - 128) / 128.0
 *   16 bit  有符号： v / 32768.0
 *   24 bit  有符号： v / 8388608.0
 *   32 bit  有符号： v / 2147483648.0
 *   32 bit  浮点  ： 直接使用（本阶段暂不支持，见下）
 *
 * 说明：
 *   - 全部按**小端**解析（WAV 规范）
 *   - 负的满量程（如 -32768）映射到 -1.0，正的满量程映射到略小于 1.0，
 *     这是业界通行做法
 *   - 本函数不做声道与采样率变换（本库不统一采样率，见 §5）
 * ========================================================================== */

/// 是否为本模块支持的位深 / 格式组合。
public func isSupportedPcmFormat(bitsPerSample: Int64, isFloatFormat: Bool): Bool {
    if (isFloatFormat) {
        return false // 32-bit float PCM 暂不支持，见文件头说明
    }
    match (bitsPerSample) {
        case 8 | 16 | 24 | 32 => true
        case _ => false
    }
}

/// 计算单个样本占用的字节数。
public func bytesPerSample(bitsPerSample: Int64): Int64 {
    (bitsPerSample + 7) / 8
}

/// 把交错整型 PCM 转换为 f32 交错样本。
///
/// - data 长度不足一个完整样本时，尾部多余字节被忽略
/// - 调用方须先用 isSupportedPcmFormat 校验
public func pcmToF32(data: Array<UInt8>, bitsPerSample: Int64): Array<Float32> {
    let bps = bytesPerSample(bitsPerSample)
    if (bps <= 0) {
        return Array<Float32>()
    }

    let sampleCount = data.size / bps
    let out = Array<Float32>(sampleCount, repeat: 0.0)

    match (bitsPerSample) {
        case 8 =>
            // 8 bit WAV 为**无符号**，中点为 128
            for (i in 0..sampleCount) {
            let raw = Float32(data[i * bps])
            out[i] = (raw - 128.0) / 128.0
        }
        case 16 => for (i in 0..sampleCount) {
            out[i] = Float32(readInt16LE(data, i * bps)) / 32768.0
        }
        case 24 => for (i in 0..sampleCount) {
            out[i] = Float32(readInt24LE(data, i * bps)) / 8388608.0
        }
        case 32 => for (i in 0..sampleCount) {
            out[i] = Float32(readInt32LE(data, i * bps)) / 2147483648.0
        }
        case _ => return Array<Float32>()
    }

    out
}

// ---------------------------------------------------------------------------
// 小端整型解析（手写实现，避免依赖未知的 std.binary API）
// ---------------------------------------------------------------------------

/// 读取 1 字节。
public func readUInt8(data: Array<UInt8>, offset: Int64): UInt8 {
    data[offset]
}

/// 读取 2 字节无符号小端。
public func readUInt16LE(data: Array<UInt8>, offset: Int64): UInt16 {
    let lo = UInt16(data[offset])
    let hi = UInt16(data[offset + 1])
    (hi << 8) | lo
}

/// 读取 4 字节无符号小端。
public func readUInt32LE(data: Array<UInt8>, offset: Int64): UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1])
    let b2 = UInt32(data[offset + 2])
    let b3 = UInt32(data[offset + 3])
    (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
}

/// 读取 2 字节有符号小端，返回**加宽后的 Int32**。
///
/// 注意（2026-10-02 实测教训）：**不能**写成 `Int16(readUInt16LE(...))` ——
/// 仓颉的数值类型转换默认带溢出检查，当原始值 > 32767（如 0xFFFF = 65535）时
/// 会抛出：
///     OverflowException: The result would be greater than Int16.Max
/// 因此这里改为返回加宽的 Int32 并手动做符号扩展，调用方再做归一化。
private func readInt16LE(data: Array<UInt8>, offset: Int64): Int32 {
    let raw = Int32(readUInt16LE(data, offset))
    if (raw > 32767) {
        raw - 65536
    } else {
        raw
    }
}

/// 读取 3 字节有符号小端（WAV 的 24-bit 为紧凑 3 字节，需手动符号扩展）。
private func readInt24LE(data: Array<UInt8>, offset: Int64): Int32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1])
    let b2 = UInt32(data[offset + 2])
    let raw = (b2 << 16) | (b1 << 8) | b0

    let signBit = UInt32(0x80) << 16
    if ((raw & signBit) != UInt32(0)) {
        // 负数：减去 2^24 完成符号扩展
        Int32(raw) - 16777216
    } else {
        Int32(raw)
    }
}

/// 读取 4 字节有符号小端，返回**加宽后的 Int64**（同上，规避转换溢出检查）。
private func readInt32LE(data: Array<UInt8>, offset: Int64): Int64 {
    let raw = Int64(readUInt32LE(data, offset))
    if (raw > 2147483647) {
        raw - 4294967296
    } else {
        raw
    }
}
