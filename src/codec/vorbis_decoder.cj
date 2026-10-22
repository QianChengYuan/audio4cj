package audio4cj.codec

import audio4cj.core.*
import audio4cj.format.Packet
import audio4cj.pcm.AudioBuffer
import audio4cj.pcm.reinterpretF32Bytes

/* ============================================================================
 * Vorbis 解码器 —— 把 Packet 中已解码的 f32 交错 PCM 重解释为 AudioBuffer
 *
 * 与 Mp3PcmDecoder 同构：真正的 Vorbis 解码（码本、floor、residue、IMDCT、
 * 重叠相加）由 Reader 持有的解码内核完成（format/vorbis_decode.cj），
 * 它把 f32 交错 PCM 直接写进 Packet.data。本类不含任何算法处理。
 *
 * 分工理由与 MP3/FLAC 一致：Reader 负责 packet 重组、seek 与进度推进；
 * 若让 Decoder 也持有同一内核会引入所有权纠缠。
 * ========================================================================== */

/// Vorbis 解码器。
protected class VorbisPcmDecoder <: Decoder {
    private let _sampleRate: Int64
    private let _channels: Int64
    private let _totalFrames: Int64

    public init(sampleRate: Int64, channels: Int64, totalFrames: Int64) {
        _sampleRate = sampleRate
        _channels = channels
        _totalFrames = totalFrames
    }

    public func decode(packet: Packet): AudioBuffer {
        let samples = reinterpretF32Bytes(packet.data)
        AudioBuffer(_sampleRate, _channels, samples)
    }

    public func codecParams(): CodecParameters {
        let p = CodecParameters()
        p.sampleRate = _sampleRate
        p.channels = _channels
        p.bitDepth = 32
        p.totalFrames = _totalFrames
        p
    }

    /// 无内部状态需要重置 —— Vorbis 的重叠状态由 Reader 持有。
    public func reset(): Unit {
        ()
    }
}
