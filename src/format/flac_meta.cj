package audio4cj.format

import audio4cj.core.CorruptedFileException
import audio4cj.core.FormatNotSupportedException

/* ============================================================================
 * FLAC 元数据块解析（纯仓颉）
 *
 * 【用途】
 *   纯仓颉 FLAC 内核要自己回答"采样率/声道/位深/总帧数是多少"，
 *   这些信息全部来自文件开头的 STREAMINFO 块，无需解码任何音频数据。
 *   因此这一步可以**独立完成并独立验证** —— 且验证方式很强：
 *   对同一文件，纯仓颉解析出的参数必须与 FFI 内核报告的**完全一致**。
 *
 * 【位置无关性】
 *   本文件只做**纯解析**：输入是头部字节，不碰文件 I/O。
 *   读取字节的事由调用方（format/flac_bitstream.cj 或测试）负责 ——
 *   与 meta 层"纯解析器 + 单独 I/O 入口"的既有分工一致。
 *
 * 【规范依据】
 *   RFC 9639（FLAC 格式正式标准）规定的元数据块结构：
 *     4 字节  标记 "fLaC"
 *     每块    1 位 last 标志 + 7 位块类型 + 24 位块长度（均按 MSB-first 位序）
 *     STREAMINFO（类型 0，长度固定 34 字节，且必须是首块）字段依次为：
 *       16 位 最小块大小      16 位 最大块大小
 *       24 位 最小帧大小      24 位 最大帧大小
 *       20 位 采样率          3 位 声道数 - 1
 *        5 位 位深 - 1        36 位 总样本数
 *      128 位 MD5
 * ========================================================================== */

/// STREAMINFO 块中本库需要的字段（其余如 min/max 帧大小、MD5 暂不使用）。
protected class FlacStreamInfo {
    /// 采样率（Hz）。
    protected let sampleRate: Int64

    /// 声道数。
    protected let channels: Int64

    /// 位深。
    protected let bitsPerSample: Int64

    /// 总样本数（每声道）。**0 表示未知** —— FLAC 允许流式编码时留 0，
    /// 因此它与 FlacDecodeKernel.totalFrames() 的"0 = 不可知"约定一致。
    protected let totalSamples: Int64

    /// 最大块大小（帧内样本数上限），分配解码缓冲时用得到。
    protected let maxBlockSize: Int64

    protected init(
        sampleRate: Int64,
        channels: Int64,
        bitsPerSample: Int64,
        totalSamples: Int64,
        maxBlockSize: Int64
    ) {
        this.sampleRate = sampleRate
        this.channels = channels
        this.bitsPerSample = bitsPerSample
        this.totalSamples = totalSamples
        this.maxBlockSize = maxBlockSize
    }
}

/// FLAC 的标识标记。
private let FLAC_MARKER: Array<UInt8> = [0x66, 0x4C, 0x61, 0x43] // "fLaC"

/// STREAMINFO 块的类型号与固定体长。
private let FLAC_BLOCK_STREAMINFO: Int64 = 0
private let FLAC_STREAMINFO_LENGTH: Int64 = 34

/// "fLaC" 标记的长度（字节）。
protected let FLAC_MARKER_SIZE: Int64 = 4

/// 从文件头部字节解析 STREAMINFO。
///
/// 要求 `data` 至少覆盖 "fLaC" 标记与首个元数据块头部（4 + 4 + 34 字节）。
/// 任何结构性问题（标记缺失、首块不是 STREAMINFO、长度不符、数值非法）
/// 一律抛异常 —— 不用返回值表达错误（§4.1 铁律）。
protected func parseStreamInfo(data: Array<UInt8>): FlacStreamInfo {
    // ---- 标记 ----
    if (data.size < FLAC_MARKER_SIZE + 4 + FLAC_STREAMINFO_LENGTH) {
        throw CorruptedFileException(
            "FLAC 头部字节不足（需 ${FLAC_MARKER_SIZE + 4 + FLAC_STREAMINFO_LENGTH}，实得 ${data.size}）")
    }
    var i: Int64 = 0
    while (i < FLAC_MARKER_SIZE) {
        if (data[i] != FLAC_MARKER[i]) {
            throw FormatNotSupportedException("不是 FLAC 流：缺少 fLaC 标记")
        }
        i += 1
    }

    // ---- 首个元数据块头部 ----
    // byte[4]：1 位 last 标志 + 7 位块类型；byte[5..7]：24 位块长度
    let blockType = Int64(data[FLAC_MARKER_SIZE]) & 0x7F
    let blockLength = (Int64(data[FLAC_MARKER_SIZE + 1]) << 16) | (Int64(data[FLAC_MARKER_SIZE + 2]) << 8) | Int64(data[FLAC_MARKER_SIZE +
            3])

    if (blockType != FLAC_BLOCK_STREAMINFO) {
        throw CorruptedFileException("FLAC 首块必须是 STREAMINFO（实际类型 ${blockType}）")
    }
    if (blockLength != FLAC_STREAMINFO_LENGTH) {
        throw CorruptedFileException("STREAMINFO 块长度应为 34，实际 ${blockLength}")
    }

    // ---- 块体（MSB-first 位序，直接复用已验证的位读取器）----
    let reader = BitReader(data)
    reader.seekToBit((FLAC_MARKER_SIZE + 4) * 8)

    // 读取顺序即字段顺序，不可打乱。本库暂不使用最小块大小与 min/max 帧大小，
    // 用 `let _ =` 读掉以保持位置正确（`let _name =` 仍会触发 unused 告警）。
    let _ = reader.readBits(16) // 最小块大小
    let maxBlockSize = Int64(reader.readBits(16))
    let _ = reader.readBits(24) // 最小帧大小
    let _ = reader.readBits(24) // 最大帧大小
    let sampleRate = Int64(reader.readBits(20))
    let channels = Int64(reader.readBits(3)) + 1
    let bitsPerSample = Int64(reader.readBits(5)) + 1
    let totalSamples = Int64(reader.readBits(36))

    // ---- 基本合法性校验 ----
    // 这几项为 0 说明头部已损坏：采样率必需，声道数至少 1，位深至少 4
    if (sampleRate <= 0) {
        throw CorruptedFileException("FLAC STREAMINFO 采样率为 ${sampleRate}，非法")
    }
    if (channels <= 0) {
        throw CorruptedFileException("FLAC STREAMINFO 声道数为 ${channels}，非法")
    }
    if (bitsPerSample < 4) {
        throw CorruptedFileException("FLAC STREAMINFO 位深为 ${bitsPerSample}，非法")
    }
    if (maxBlockSize <= 0) {
        throw CorruptedFileException("FLAC STREAMINFO 最大块大小为 ${maxBlockSize}，非法")
    }

    FlacStreamInfo(sampleRate, channels, bitsPerSample, totalSamples, maxBlockSize)
}

/// 定位第一个音频帧的**字节偏移**（跳过全部元数据块）。
///
/// FLAC 文件结构是：`fLaC` 标记 + 若干元数据块（每块为 1 位 last 标志 +
/// 7 位类型 + 24 位长度），最后一块的 last 标志置 1，其后即第一个音频帧。
///
/// 必须**逐块跳过**，不能假设"只有 STREAMINFO 一块" —— 带封面、带
/// SEEKTABLE 或带 Vorbis comment 的文件都会多出若干块
/// （testdata/flac/flac_cover.flac 与 flac_tagged.flac 就是这种形态）。
///
/// 块长度越界一律抛异常：否则损坏文件会把"帧起点"定到文件中间。
protected func findFirstFrameOffset(data: Array<UInt8>): Int64 {
    if (data.size < FLAC_MARKER_SIZE) {
        throw CorruptedFileException("FLAC 头部字节不足（${data.size}）")
    }
    var i: Int64 = 0
    while (i < FLAC_MARKER_SIZE) {
        if (data[i] != FLAC_MARKER[i]) {
            throw FormatNotSupportedException("不是 FLAC 流：缺少 fLaC 标记")
        }
        i += 1
    }

    var pos = FLAC_MARKER_SIZE
    var isLast = false
    var guard: Int64 = 0
    while (!isLast) {
        // 元数据块数量本应有限；加保护避免损坏文件造成长循环
        guard += 1
        if (guard > 1024) {
            throw CorruptedFileException("FLAC 元数据块数量异常（超过 1024 块）")
        }
        if (pos + 4 > data.size) {
            throw CorruptedFileException("FLAC 元数据块头部越界（偏移 ${pos}）")
        }

        isLast = (Int64(data[pos]) & 0x80) != 0
        let length = (Int64(data[pos + 1]) << 16) | (Int64(data[pos + 2]) << 8) | Int64(data[pos + 3])
        pos += 4 + length

        if (pos > data.size) {
            throw CorruptedFileException("FLAC 元数据块长度越界（偏移 ${pos}）")
        }
    }
    pos
}
