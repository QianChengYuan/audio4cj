package audio4cj.codec

import audio4cj.core.*
import audio4cj.pcm.AudioBuffer
import audio4cj.format.Packet
import audio4cj.pcm.reinterpretF32Bytes

/* ============================================================================
 * MP3 解码器 —— 把 Packet 中已解码的 f32 交错 PCM 重解释为 AudioBuffer
 *
 * 与 FlacPcmDecoder 同构：真正的解码（帧同步、Huffman、反量化、IMDCT、
 * 多相合成滤波）由**解码内核**完成 —— 见 format/mp3_decode.cj 的 mp3DecodeFrame，
 * 它把内核产出的 f32 交错 PCM 直接写入 Packet.data。本类只把同一块内存
 * 换一个视角（字节 -> Float32），不含任何算法处理。
 *
 * 分工的理由与 FLAC 一致：Reader 持有解码内核并负责 seek 与进度推进；
 * 若让 Decoder 也持有同一内核会引入所有权纠缠。Reader 一次读取、
 * Decoder 只做视角转换，职责边界与 WAV / FLAC 完全对齐。
 *
 * 与 FLAC 的一处差异：MP3 是**有损**格式，不存在"逐位相同"的判据。
 * 本类的职责不变，但针对它的正确性判据是"帧数 + 整体能量"的包络比对
 * （见 src/test/golden_test.cj 的说明）。
 * ========================================================================== */

/// MP3 解码器。
protected class Mp3PcmDecoder <: Decoder {
    private let _sampleRate: Int64
    private let _channels: Int64
    private let _totalFrames: Int64

    public init(sampleRate: Int64, channels: Int64, totalFrames: Int64) {
        this._sampleRate = sampleRate
        this._channels = channels
        this._totalFrames = totalFrames
    }

    /// 把数据包中的 f32 交错 PCM 字节重解释为 `AudioBuffer`。
    ///
    /// 说明：解码内核已按 f32 交错写出（取值范围 [-1.0, 1.0]），
    /// 因此这里不做任何数值变换，只是换视角读取同一块内存。
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

    /// 无内部状态需要重置 —— 位池与读取进度都由 Reader 持有。
    public func reset(): Unit {
        ()
    }
}
