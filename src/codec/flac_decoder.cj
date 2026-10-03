package audio4cj.codec

import audio4cj.core.*
import audio4cj.pcm.AudioBuffer
import audio4cj.format.Packet
import audio4cj.pcm.reinterpretF32Bytes

/* ============================================================================
 * FLAC 解码器 —— 把 Packet 中已解码的 f32 交错 PCM 重解释为 AudioBuffer
 *
 * 为什么本类如此简单：
 *   FLAC 是**压缩**格式，真正的解码（LPC 预测、残差解码、立体声解相关等）
 *   由 dr_libs 完成 —— 见 format/flac.cj 的 FlacFormatReader.nextPacket，
 *   它经 FFI 把 f32 交错 PCM 直接写入 Packet.data。本类只把同一块内存
 *   换一个视角（字节 -> Float32），不含任何算法处理。
 *
 * 为什么不把「读取」放在本类：
 *   Reader 持有 dr_libs 句柄并负责 seek 与进度推进；若让 Decoder 也持有
 *   同一句柄会引入所有权纠缠。让 Reader 一次读取、Decoder 只做视角转换，
 *   职责边界与 WAV 实现完全对齐（WavPcmDecoder 亦是纯转换）。
 *
 * 代价：f32 数据存在一次字节视角的拷贝（每块约 128 KiB 量级，立体声）。
 *   在 M4「以正确性优先」的阶段可接受，作为性能优化项记录给 M5/M7。
 * ========================================================================== */

/// FLAC 解码器。
protected class FlacPcmDecoder <: Decoder {
    private let _sampleRate: Int64
    private let _channels: Int64
    private let _bitsPerSample: Int64
    private let _totalFrames: Int64

    public init(sampleRate: Int64, channels: Int64, bitsPerSample: Int64, totalFrames: Int64) {
        this._sampleRate = sampleRate
        this._channels = channels
        this._bitsPerSample = bitsPerSample
        this._totalFrames = totalFrames
    }

    /// 把数据包中的 f32 交错 PCM 字节重解释为 `AudioBuffer`。
    ///
    /// 说明：dr_libs 已按 f32 交错写出（取值范围 [-1.0, 1.0]），
    /// 因此这里不做任何数值变换，只是换视角读取同一块内存。
    public func decode(packet: Packet): AudioBuffer {
        let samples = reinterpretF32Bytes(packet.data)
        AudioBuffer(_sampleRate, _channels, samples)
    }

    public func codecParams(): CodecParameters {
        let p = CodecParameters()
        p.sampleRate = _sampleRate
        p.channels = _channels
        p.bitDepth = _bitsPerSample
        p.totalFrames = _totalFrames
        p
    }

    /// 无内部状态需要重置 —— 句柄与读取进度都由 Reader 持有。
    public func reset(): Unit {
        ()
    }
}
