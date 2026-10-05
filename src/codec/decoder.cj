package audio4cj.codec

import audio4cj.core.CodecParameters
import audio4cj.format.Packet
import audio4cj.pcm.AudioBuffer

/* ============================================================================
 * Decoder —— 开发文档 §4.6
 *
 * 解码器统一接口：一编码一实现，注册即用。
 * 本版本各实现均为纯仓颉（WAV / FLAC / Ogg-FLAC）。
 * （历史上 FLAC 等曾由第三方 C 库的 FFI 适配层实现，那层须与 FFI 声明同包 ——
 * 因 foreign 函数无法带访问修饰符、父包访问不到子包的 internal 声明；
 * 这套约束已随 C 依赖整体移除。）
 *
 * 契约要点：
 *   - decode() 遇坏帧必须抛 DecodeException，不得返回空 AudioBuffer
 *     污染下游（§4.1 铁律 1）
 *   - reset() 用于 seek 后重置解码器内部状态
 *
 * 接口成员隐式 public，不允许添加访问修饰符；
 * class 实现时可忽略 mut 修饰（class 实例成员函数始终可修改实例状态）。
 * ========================================================================== */
protected interface Decoder {
    /// 解码一个包，输出 f32 交错 PCM。
    func decode(packet: Packet): AudioBuffer

    /// 当前解码参数（采样率 / 声道数 / 位深 / 总帧数）。
    func codecParams(): CodecParameters

    /// 重置解码器内部状态（seek 后调用）。
    func reset(): Unit
}
