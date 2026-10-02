package audio4cj.codec

import audio4cj.core.*
import audio4cj.format.Packet
import audio4cj.pcm.*

/* ============================================================================
 * WAV 解码器 —— Packet（原始整型 PCM 字节）→ AudioBuffer（f32 交错）
 *
 * 定位：WAV 是未压缩容器，其「解码」即位深转换（属数据解析），
 *       因此本解码器是**纯仓颉实现**，不调用 FFI。
 *       dr_libs 的 WAV 通路在同目录下作为交叉验证基准保留。
 *
 * 与 Decoder 接口的对应：
 *   decode()      —— 转换一个包的 PCM 字节为 f32
 *   codecParams() —— 返回采样率 / 声道 / 位深
 *   reset()       —— 本实现无可变内部状态，空实现
 * ========================================================================== */

/// WAV 的整型 PCM 解码器。
protected class WavPcmDecoder <: Decoder {
    private let _bitsPerSample: Int64
    private let _channels: Int64
    private let _sampleRate: Int64
    private let _params: CodecParameters

    public init(bitsPerSample: Int64, channels: Int64, sampleRate: Int64) {
        this._bitsPerSample = bitsPerSample
        this._channels = channels
        this._sampleRate = sampleRate

        let p = CodecParameters()
        p.sampleRate = sampleRate
        p.channels = channels
        p.bitDepth = bitsPerSample
        p.totalFrames = -1
        this._params = p
    }

    /// 解码一个包；坏包抛 DecodeException（不返回空缓冲污染下游 —— §4.1 铁律 1）。
    public func decode(packet: Packet): AudioBuffer {
        if (_channels <= 0 || _sampleRate <= 0) {
            throw DecodeException("解码参数非法（channels=${_channels}, rate=${_sampleRate}）")
        }

        let samples = pcmToF32(packet.data, _bitsPerSample)
        AudioBuffer(_sampleRate, _channels, samples)
    }

    public func codecParams(): CodecParameters {
        _params
    }

    public func reset(): Unit {
        // 纯转换实现无可变状态，无需重置
    }
}
