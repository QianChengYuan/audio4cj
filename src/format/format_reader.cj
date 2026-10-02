package audio4cj.format

import audio4cj.core.{AudioInfo, Track}
import audio4cj.meta.Tag

/* ============================================================================
 * FormatReader —— 开发文档 §4.6
 *
 * 容器读取器（demuxer）统一接口：一容器一实现，注册即用。
 *
 * 契约要点：
 *   - nextPacket() 返回 None 严格且仅表示"正常流结束"；
 *     解码/解析错误必须抛 CorruptedFileException，不得用 None 表达（§4.1 铁律 1）
 *   - seekTo() 返回**实际落点毫秒**，因为 VBR MP3 / Ogg Vorbis 的寻址
 *     天然是近似的，返回 Unit 会让调用方误以为精确到位
 *   - metadata() 无标签时返回各字段为 None 的**空 Tag**，不返回 None
 *
 * 接口成员隐式 public，不允许添加访问修饰符。
 * ========================================================================== */
protected interface FormatReader <: Resource {
    /// 全部轨道。
    func tracks(): Array<Track>

    /// 读取下一个数据包；None 表示流正常结束。
    func nextPacket(): ?Packet

    /// 按时间戳寻址，返回实际落点毫秒。
    func seekTo(timestampMs: Int64): Int64

    /// 读取标签；无标签返回空 Tag。
    func metadata(): Tag

    /// 读取音频基本信息。
    func info(): AudioInfo
}
