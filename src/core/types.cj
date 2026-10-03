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

/// 容器与编码描述（由探测层的结果固化成公开值类型）。
///
/// 探测发生在 `AudioFile.open()` 内部（读文件头 → 判别容器与子编码 → 选择实现）。
/// 在本类型出现之前，那份判定结果**只用于分支选实现、随后即被丢弃** ——
/// 使用者拿不到"这是什么格式"，只能靠 `open()` 失败时的异常信息间接得知。
///
/// 设计取向：`container` 与 `codec` 分开，是为了让程序化判断可靠
/// （例如"凡是 Ogg 容器都走某条分支"），而 `codecId` 只服务于打印与日志。
public class FormatInfo {
    /// 容器标识（小写）：`wav` / `flac` / `mp3` / `ogg` / `mp4` / …
    public let container: String

    /// 容器内的**子编码**标识。
    ///
    /// 只有 Ogg 族存在子编码（`flac` / `vorbis` / `opus` / `speex`，判定不出时为空串）；
    /// 其余容器本身即编码，此字段为空串。
    public let codec: String

    /// 归一化标识，便于打印与比较：如 `flac`、`ogg/flac`、`ogg/opus`。
    ///
    /// 由容器与子编码拼成，无子编码时即容器名。**不要**用它做程序化判断 ——
    /// 请用 `container` / `codec` 两个字段。
    public let codecId: String

    /// MIME 类型（如 `audio/flac`）；无法判定时为 `application/octet-stream`。
    public let mimeType: String

    public init(container: String, codec: String, codecId: String, mimeType: String) {
        this.container = container
        this.codec = codec
        this.codecId = codecId
        this.mimeType = mimeType
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
