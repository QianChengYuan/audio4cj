package audio4cj.stream

import audio4cj.core.Audio4CjException
import audio4cj.core.ClosedResourceException
import audio4cj.pcm.AudioBuffer
import audio4cj.format.FormatReader
import audio4cj.codec.Decoder

/* ============================================================================
 * FrameStream —— 开发文档 §4.5
 *
 * 流式消费主 API。存在的理由（§7.3 内存策略）：
 *   f32 交错 PCM 为 4 字节/样本，44.1kHz 立体声 1 小时约 1.27 GB，
 *   因此 readAll() 只能作为便捷 API，主推本类的分块消费模式。
 *
 * 消费范式：
 *   let s = f.stream()
 *   while (let Some(chunk) <- s.next()) { ... }
 *
 * 取消语义（仓颉为协作式取消）：
 *   cancel() 只设置标志位；此外每轮 next() 会检查
 *   Thread.currentThread.hasPendingCancellation，响应外部取消请求。
 *   仓颉不会强制停止线程，故必须由本类主动轮询。
 *
 * 并发约定：本类**非线程安全**，单实例只能被一个线程使用（§4.7）。
 *
 * 可见性说明：构造需接收 FormatReader / Decoder（均为 protected 类型），
 *   若构造为 public 会违反"public 声明不得使用非 public 类型"，
 *   故真实后端构造为 protected（模块内可见），由 facade 包调用。
 * ========================================================================== */
public class FrameStream {
    private var _cancelled: Bool = false
    private var _closed: Bool = false
    private var _ended: Bool = false

    private let _reader: ?FormatReader
    private let _decoder: ?Decoder

    /// 空流构造（无后端）。next() 立即返回 None（表示正常结束）。
    public init() {
        this._reader = None
        this._decoder = None
    }

    /// 模块内构造：绑定真实 demuxer 与解码器。
    protected init(reader: FormatReader, decoder: Decoder) {
        this._reader = reader
        this._decoder = decoder
    }

    /// 取下一条分块。
    /// - None **严格且仅表示**正常流结束（含用户取消）
    /// - 解码/解析错误抛 DecodeException 等，绝不用 None 表示错误（§4.1 铁律 1）
    ///
    /// 抛出：`ClosedResourceException`（对已 close() 的流继续取值，§4.1）
    public func next(): ?AudioBuffer {
        if (_closed) {
            throw ClosedResourceException("对已关闭的 FrameStream 执行操作")
        }
        if (_cancelled || _ended) {
            return None
        }

        // 协作式取消：响应外部取消请求
        if (Thread.currentThread.hasPendingCancellation) {
            _cancelled = true
            return None
        }

        match ((_reader, _decoder)) {
            case (Some(r), Some(d)) => match (r.nextPacket()) {
                case Some(p) => d.decode(p)
                case None =>
                    _ended = true
                    None
            }
            case _ =>
                // 空流：视作立即结束
                _ended = true
                None
        }
    }

    /// 请求取消（协作式，只设置标志位）。
    public func cancel(): Unit {
        _cancelled = true
    }

    /// 是否已被请求取消。
    public func isCancelled(): Bool {
        _cancelled
    }

    /// 是否已到达流末尾。
    public func isEnded(): Bool {
        _ended
    }

    /// 是否已关闭。
    public func isClosed(): Bool {
        _closed
    }

    /// 关闭流并释放其持有的底层读取器（幂等）。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _cancelled = true
            match (_reader) {
                case Some(r) => r.close()
                case None => ()
            }
        }
    }
}
