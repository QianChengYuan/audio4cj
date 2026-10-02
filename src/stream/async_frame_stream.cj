package audio4cj.stream

import audio4cj.core.*
import audio4cj.pcm.AudioBuffer
import std.collection.concurrent.*
import std.sync.*

/* ============================================================================
 * AsyncFrameStream —— 后台解码 + 有界队列背压（开发文档 §10 M5）
 *
 * 【要解决的问题】
 *   `FrameStream.next()` 是**同步拉取**：调用时才解码。它天然具备
 *   「不调用就不解码」的节流，但**解码与消费无法并行** —— 当消费侧较慢
 *   （写磁盘、滤波、重采样、播放）时，多核完全用不上。
 *
 *   本类在后台线程解码，经**有界阻塞队列**把数据交给消费者线程，
 *   使解码与消费并行；队列满时生产者阻塞在入队处，这就是**背压**，
 *   它同时把内存占用封顶在「队列容量 × 单块大小」。
 *
 * 【三条不变式】
 *   1. 内存有界：任何时刻队列中最多 capacity 块；生产者无法超前解码。
 *   2. 结束语义与 FrameStream 一致：`next()` 返回 None **只表示流结束**
 *      （含被取消），错误一律抛 Audio4CjException。
 *   3. 必须汇合：`close()` 会等待后台线程真正退出 —— 仓颉的主线程退出会
 *      杀死未完成的子线程，不汇合会导致解码被静默截断。
 *
 * 【为什么用「哨兵」表示结束】
 *   队列元素类型为 `?AudioBuffer`：生产者遇到源流结束（next() 返回 None）
 *   时投入一个 `None` 作为终止标记；消费者取到它即知流已结束。
 *   这样消费者无需额外轮询标志位，语义与 FrameStream 完全对齐。
 *
 * 【线程安全】
 *   - 队列与两个原子标志是跨线程共享状态，安全；
 *   - 内部的 FrameStream **只被后台线程访问**（消费者只接触队列），
 *     因此不违反「FrameStream 非线程安全、单实例单线程」的既有契约。
 * ========================================================================== */

/// 默认队列容量（块数）。8 块在立体声下约占 1 MB 量级。
private let DEFAULT_QUEUE_CAPACITY: Int64 = 8

/// 阻塞操作的单次超时（毫秒）。
///
/// 生产者的入队与消费者的出队都使用**带超时的重载**而非无限阻塞：
/// 超时后检查取消/关闭标志，从而使 `close()` 不会死等 ——
/// 若用无限阻塞，消费者停止消费时生产者会永远卡在入队处。
private let WAIT_TIMEOUT_MS: Int64 = 100

/// 异步流式读取器：在后台线程解码，经有界队列交付。
public class AsyncFrameStream <: Resource {
    private let _source: FrameStream
    private let _queue: ArrayBlockingQueue<?AudioBuffer>

    /// 已关闭标志（跨线程可见，故用原子类型）。
    private let _closedFlag = AtomicBool(false)

    /// 是否已到达流末尾（由消费者线程写入）。
    private let _endedFlag = AtomicBool(false)

    /// 后台解码线程句柄；close() 时用它强制汇合。
    private var _worker: ?Future<Unit> = None

    /// 仅供静态工厂使用。
    protected init(source: FrameStream, queueCapacity: Int64) {
        this._source = source
        this._queue = ArrayBlockingQueue<?AudioBuffer>(queueCapacity)
    }

    /// 创建并**立即开始**后台解码。
    ///
    /// - `source`：由 `AudioFile.stream()` 获得的同步流（其所有权转交本对象）
    /// - `queueCapacity`：队列容量（块数），即「允许生产者超前解码多少块」，
    ///   也就是内存上限。必须为正。
    ///
    /// 说明：此处采用「静态工厂 + 两阶段启动」而非在构造函数里启动线程 ——
    /// 构造期间 `this` 尚未完成初始化，此时把 `this` 交给另一个线程存在隐患。
    public static func start(source: FrameStream, queueCapacity!: Int64 = DEFAULT_QUEUE_CAPACITY): AsyncFrameStream {
        if (queueCapacity <= 0) {
            throw Audio4CjException("队列容量必须为正数（当前 ${queueCapacity}）")
        }

        let s = AsyncFrameStream(source, queueCapacity)
        s.begin()
        s
    }

    // ------------------------------------------------------------------
    // 消费者接口
    // ------------------------------------------------------------------

    /// 取下一条分块。None **严格且仅表示**流已结束（含被取消）。
    ///
    /// 阻塞直到有数据可取。若已关闭则抛异常（与 FrameStream 一致）。
    public func next(): ?AudioBuffer {
        if (_closedFlag.load()) {
            throw Audio4CjException("对已关闭的 AsyncFrameStream 执行操作")
        }

        // 注意：此处不使用 `while (true) { ... return ... }` 形式 ——
        // 仓颉将 while 视为 Unit 表达式，编译器不会因「循环内必然 return」
        // 而认定函数不会落到末尾，会报类型不匹配。故用显式状态变量。
        var result: ?AudioBuffer = None
        var finished = false

        while (!finished) {
            match (_queue.remove(Duration.millisecond * WAIT_TIMEOUT_MS)) {
                case Some(item) => match (item) {
                    case Some(buf) =>
                        result = buf
                        finished = true
                    case None =>
                        // 取到结束哨兵
                        _endedFlag.store(true)
                        finished = true
                }
                case None =>
                    // 超时：可能是源流较长，也可能是已被取消 —— 后者需要主动退出，
                    // 否则消费者会在此永久等待一个永远不会到来的哨兵。
                    if (_source.isCancelled() && _queue.size == 0) {
                        _endedFlag.store(true)
                        finished = true
                    }
            }
        }

        result
    }

    /// 是否已到达流末尾。
    public func isEnded(): Bool {
        _endedFlag.load()
    }

    /// 是否已关闭。
    public func isClosed(): Bool {
        _closedFlag.load()
    }

    /// 关闭：请求源流取消、**等待后台线程退出**、关闭源流（幂等）。
    ///
    /// 顺序很重要：
    ///   1. 置关闭标志 —— 让后台线程在下次超时时主动退出；
    ///   2. 取消源流 —— 让它尽快停止解码；
    ///   3. `Future.get()` 汇合 —— 保证线程真正结束（否则主线程退出会杀死它）；
    ///   4. 关闭源流 —— 释放其持有的底层 reader。
    public func close(): Unit {
        if (_closedFlag.load()) {
            return
        }
        _closedFlag.store(true)
        _source.cancel()

        match (_worker) {
            case Some(f) => f.get()
            case None => ()
        }

        _source.close()
    }

    // ------------------------------------------------------------------
    // 生产者（后台线程）
    // ------------------------------------------------------------------

    /// 启动后台解码线程。仅在 `start` 中调用一次。
    private func begin(): Unit {
        this._worker = spawn {
            pump()
        }
    }

    /// 后台解码主循环：解码一块就投递一块，队列满则阻塞（背压）。
    private func pump(): Unit {
        while (true) {
            let chunk = _source.next() // None = 源流结束（含被取消）

            match (chunk) {
                case Some(buf) =>
                    if (!enqueue(buf)) {
                        return // 关闭/取消期间放弃投递
                    }
                case None =>
                    enqueueEnd()
                    return
            }
        }
    }

    /// 投递数据块。返回 false 表示应当退出生产者循环。
    private func enqueue(buf: AudioBuffer): Bool {
        var accepted = false
        var decided = false

        while (!decided) {
            if (_queue.add(buf, Duration.millisecond * WAIT_TIMEOUT_MS)) {
                accepted = true
                decided = true
            } else if (_source.isCancelled() || _closedFlag.load()) {
                // 入队超时：若已取消或已关闭，说明消费者不会再取走数据，
                // 继续等待将造成死锁，故放弃投递并退出。
                accepted = false
                decided = true
            }
        }

        accepted
    }

    /// 投递结束哨兵。持续尝试直到成功或已关闭。
    private func enqueueEnd(): Unit {
        var done = false

        while (!done) {
            if (_queue.add(None, Duration.millisecond * WAIT_TIMEOUT_MS)) {
                done = true
            } else if (_closedFlag.load()) {
                done = true
            }
        }
    }
}
