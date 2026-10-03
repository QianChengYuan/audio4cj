package audio4cj.codec

import audio4cj.core.*
import audio4cj.pcm.AudioBuffer
import audio4cj.format.Packet
import audio4cj.pcm.reinterpretF32Bytes

/* ============================================================================
 * MP3 解码器 —— 把 Packet 中已解码的 f32 交错 PCM 重解释为 AudioBuffer
 *
 * 与 FlacPcmDecoder 结构完全一致：真正的解码（Huffman 解码、逆量化、
 * IMDCT、多相合成滤波等）由 dr_mp3 完成，本类只做字节到 Float32 的视角转换，
 * 不含任何算法处理。
 *
 * 位深语义：`bitDepth` 报告为 32，含义是「float32」而非 32 位整数 PCM ——
 * MP3 是有损格式，没有源位深概念（详见 format/mp3.cj 的说明）。
 * ========================================================================== */

/// MP3 解码器。
protected class Mp3PcmDecoder <: Decoder {
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
