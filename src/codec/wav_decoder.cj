package audio4cj.codec

import audio4cj.core.*
import audio4cj.format.Packet
import audio4cj.pcm.*

/* ============================================================================
 * WAV 解码器 —— Packet（原始 PCM 字节）→ AudioBuffer（f32 交错）
 *
 * 定位：WAV 是未压缩容器，其「解码」即位深/格式转换（属数据解析），
 *       因此本解码器是**纯仓颉实现**，不调用 FFI。
 *       （曾有一个第三方库的 WAV FFI 绑定放在同目录，实测零调用点，
 *         已随 C 依赖整体移除。）
 *
 * 支持两类载荷，由 isFloatFormat 分流：
 *   整型 PCM（formatTag 1）—— 按位深归一化（8 无符号 / 16 / 24 / 32 有符号）
 *   浮点 PCM（formatTag 3）—— 仅 32 位，按位重解释为 f32（不做数值转换）
 *
 * 与 Decoder 接口的对应：
 *   decode()      —— 转换一个包的 PCM 字节为 f32
 *   codecParams() —— 返回采样率 / 声道 / 位深
 *   reset()       —— 本实现无可变内部状态，空实现
 * ========================================================================== */

/// WAV 的 PCM 解码器（整型与 32 位浮点）。
protected class WavPcmDecoder <: Decoder {
    private let _bitsPerSample: Int64
    private let _channels: Int64
    private let _sampleRate: Int64
    private let _isFloatFormat: Bool
    private let _params: CodecParameters

    /// `isFloatFormat` 必填而非默认 `false`：若将来新增构造点漏传，整型归一化会把
    /// 浮点位模式当整型样本（数值全错却不报错）—— 这类静默错误代价太大。
    public init(bitsPerSample: Int64, channels: Int64, sampleRate: Int64, isFloatFormat: Bool) {
        this._bitsPerSample = bitsPerSample
        this._channels = channels
        this._sampleRate = sampleRate
        this._isFloatFormat = isFloatFormat

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

        let samples = pcmToF32(packet.data, _bitsPerSample, isFloatFormat: _isFloatFormat)
        AudioBuffer(_sampleRate, _channels, samples)
    }

    public func codecParams(): CodecParameters {
        _params
    }

    public func reset(): Unit {
        // 纯转换实现无可变状态，无需重置
    }
}
