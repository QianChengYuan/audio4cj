package audio4cj.core

/* ============================================================================
 * 基础数据类型 —— 开发文档 §4.2
 *
 * 说明：AudioInfo / Track 用 let 字段（不可变快照，可跨线程读）；
 *       CodecParameters 用 var 字段（解码器初始化的可写参数载体），
 *       因所有字段均有初始值，编译器会自动生成无参 public init()。
 * ========================================================================== */

/// 音频流的基本信息（不可变快照）。
public class AudioInfo {
    /// 采样率（Hz）。注意：本库**不统一采样率**，此处为源文件实际值。
    public let sampleRate: Int64

    /// 声道数。
    public let channels: Int64

    /// 源位深：16 / 24 / 32 / 32（代表 float32）。
    public let bitDepth: Int64

    /// 时长（毫秒）。
    public let durationMs: Int64

    /// 总帧数；**-1 表示不可知**（如无索引的流式来源）。
    public let totalFrames: Int64

    public init(
        sampleRate: Int64,
        channels: Int64,
        bitDepth: Int64,
        durationMs: Int64,
        totalFrames: Int64
    ) {
        this.sampleRate = sampleRate
        this.channels = channels
        this.bitDepth = bitDepth
        this.durationMs = durationMs
        this.totalFrames = totalFrames
    }
}

/// 轨道描述。
public class Track {
    public let index: Int64
    public let codecId: String
    public let sampleRate: Int64
    public let channels: Int64

    public init(index: Int64, codecId: String, sampleRate: Int64, channels: Int64) {
        this.index = index
        this.codecId = codecId
        this.sampleRate = sampleRate
        this.channels = channels
    }
}

/// 解码器参数载体（由解码器填充）。
public class CodecParameters {
    public var sampleRate: Int64 = 0
    public var channels: Int64 = 0
    public var bitDepth: Int64 = 0

    /// 总帧数；-1 表示不可知。
    public var totalFrames: Int64 = -1
}
