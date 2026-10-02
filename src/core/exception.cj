package audio4cj.core

/* ============================================================================
 * 异常体系 —— 落地开发文档 §4.1「错误契约」
 *
 * 三条铁律：
 *   1. Option 只表示"无值"，绝不表示错误（None = 正常结束 / 字段不存在）
 *   2. 所有失败路径抛出 Exception 子类，绝不静默失败
 *   3. 只继承 Exception，禁止继承 Error（仓颉规定 Error 为系统级错误，
 *      应用不应抛出或继承）
 *
 * 各 API 错误语义（详见开发文档 §4.1）：
 *   open()          -> FormatNotSupportedException / CorruptedFileException / IO 异常
 *   metadata()      -> 无标签返回空 Tag（绝不返回 None）；标签区损坏抛 CorruptedFileException
 *   stream().next() -> None 严格且仅表示"正常流结束"；解码错误抛 DecodeException
 *   seekTo()        -> 格式不支持寻址抛 SeekNotSupportedException
 *   任何已 close() 后的调用 -> ClosedResourceException
 * ========================================================================== */

/// 音频库异常根类型。所有本库抛出的异常均为此类型的子类，
/// 调用方可用单个 catch 兜住全部库内异常。
public open class Audio4CjException <: Exception {
    public init(message: String) {
        super(message)
    }

    public override func toString(): String {
        "audio4cj: ${message}"
    }
}

/// 格式不受支持。message 应包含探测到的容器/编码名，便于定位。
public class FormatNotSupportedException <: Audio4CjException {
    public init(message: String) {
        super(message)
    }
}

/// 文件损坏或结构非法。
public class CorruptedFileException <: Audio4CjException {
    public init(message: String) {
        super(message)
    }
}

/// 解码失败（坏帧、数据不完整等）。
public class DecodeException <: Audio4CjException {
    public init(message: String) {
        super(message)
    }
}

/// 该格式不支持按时间戳寻址。
public class SeekNotSupportedException <: Audio4CjException {
    public init(message: String) {
        super(message)
    }
}

/// 对已关闭的资源进行操作。
public class ClosedResourceException <: Audio4CjException {
    public init(message: String) {
        super(message)
    }
}
