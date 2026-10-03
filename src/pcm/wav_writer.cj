package audio4cj.pcm

import audio4cj.core.Audio4CjException

/* ============================================================================
 * WAV 写出 —— PCM 的**写出方向**（此前本库只有读方向）
 *
 * 用途：把解码结果落成 WAV 字节。典型场景：
 *   · 把 FLAC 等解码结果转存为 WAV；
 *   · 交给只接受 WAV 的播放接口 —— 例如 Windows 的 PlaySound
 *     （见 examples/windows_playback/）；
 *   · 测试里做「写出 → 自己读回」的往返验证（本文件的用例就是这么用的）。
 *
 * 【为什么产出「内存字节」而不是直接写文件】
 *   写文件只多一行 std.fs，而"拿到字节"能被更多场景复用（内存播放、网络发送、
 *   二次加工）。库不该替使用者决定产物落到哪里。
 *
 * 【为什么默认 16 位】
 *   16 位是最通用的交换格式 —— WAV 播放接口几乎都吃它，体积也合理。
 *   交给系统播放时，16 位比 32 位浮点更不容易踩到驱动差异。
 * ========================================================================== */

/// WAV 头部固定 44 字节（PCM 整型）：
/// RIFF(4) + 块长(4) + WAVE(4) + "fmt "(4) + 块长(4) + fmt 体(16)
/// + "data"(4) + 块长(4)
private let WAV_HEADER_BYTES: Int64 = 44

/// WAV 的长度字段是 32 位，故单次打包的数据区上限约 4 GiB。
/// 与之对应的上限在源码里是显式的 —— 让它以异常呈现，好过静默截断。
private let WAV_MAX_DATA_BYTES: Int64 = 0xFFFFFFFF - 36

/// 把一个音频缓冲打包成内存中的 WAV（PCM 整型）字节。
///
/// - `bitsPerSample` 支持 8 / 16 / 24 / 32，缺省 16；其余取值抛 `Audio4CjException`
/// - 采样率与声道数取自 `buffer`；**不做重采样与声道变换**（本库不统一采样率）
/// - 数据区超过 WAV 的 32 位长度上限（约 4 GiB）时抛 `Audio4CjException`
///
/// 抛出：`Audio4CjException`（位深受支持、声道数非正、数据区超限）
public func wavBytes(buffer: AudioBuffer, bitsPerSample!: Int64 = 16): Array<UInt8> {
    if (!isSupportedPcmFormat(bitsPerSample, false)) {
        throw Audio4CjException("wavBytes 不支持的位深：${bitsPerSample}（支持 8 / 16 / 24 / 32）")
    }
    if (buffer.channels <= 0) {
        throw Audio4CjException("wavBytes: 声道数须为正数，实际为 ${buffer.channels}")
    }

    let data = f32ToPcm(buffer.samples, bitsPerSample)
    if (data.size > WAV_MAX_DATA_BYTES) {
        throw Audio4CjException(
            "wavBytes: 数据区 ${data.size} 字节超过 WAV 的 32 位长度上限（约 4 GiB）。" + "长音频请分块导出。")
    }

    let bps = bytesPerSample(bitsPerSample)
    let channels = buffer.channels
    let sampleRate = buffer.sampleRate

    let out = Array<UInt8>(WAV_HEADER_BYTES + data.size, repeat: 0)
    var p: Int64 = 0
    p = putAscii(out, p, "RIFF")
    // RIFF 块长度 = 文件总长 - 8（"RIFF" 与长度字段自身不算在内）
    p = putU32(out, p, UInt32(WAV_HEADER_BYTES - 8 + data.size))
    p = putAscii(out, p, "WAVE")
    p = putAscii(out, p, "fmt ")
    p = putU32(out, p, 16) // fmt 块长度：PCM 整型固定 16
    p = putU16(out, p, 1) // wFormatTag = 1 表示 PCM 整型（3 才是浮点）
    p = putU16(out, p, UInt16(channels))
    p = putU32(out, p, UInt32(sampleRate))
    p = putU32(out, p, UInt32(sampleRate * channels * bps)) // nAvgBytesPerSec
    p = putU16(out, p, UInt16(channels * bps)) // nBlockAlign
    p = putU16(out, p, UInt16(bitsPerSample))
    p = putAscii(out, p, "data")
    p = putU32(out, p, UInt32(data.size))

    var i: Int64 = 0
    while (i < data.size) {
        out[p + i] = data[i]
        i += 1
    }

    out
}

// ---------------------------------------------------------------------------
// 小端写入（手写，避免依赖未知的 std.binary API；与 convert.cj 的解析侧对称）
// ---------------------------------------------------------------------------

private func putAscii(out: Array<UInt8>, offset: Int64, s: String): Int64 {
    let bytes = s.toArray()
    var i: Int64 = 0
    while (i < bytes.size) {
        out[offset + i] = bytes[i]
        i += 1
    }
    offset + bytes.size
}

private func putU16(out: Array<UInt8>, offset: Int64, v: UInt16): Int64 {
    out[offset] = UInt8(v & 0xFF)
    out[offset + 1] = UInt8((v >> 8) & 0xFF)
    offset + 2
}

private func putU32(out: Array<UInt8>, offset: Int64, v: UInt32): Int64 {
    out[offset] = UInt8(v & 0xFF)
    out[offset + 1] = UInt8((v >> 8) & 0xFF)
    out[offset + 2] = UInt8((v >> 16) & 0xFF)
    out[offset + 3] = UInt8((v >> 24) & 0xFF)
    offset + 4
}
