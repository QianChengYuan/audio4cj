# `audio4cj.stream` API 参考

> 流式消费层。分块读取音频，内存占用与音频总时长无关。
>
> 本包提供两种流：
>
> - **`FrameStream`** —— 同步拉取（调用 `next()` 时才解码），单线程使用；
> - **`AsyncFrameStream`** —— 后台线程解码 + 有界队列背压，解码与消费并行（见第六节）。
>
> ```cangjie
> import audio4cj.stream.FrameStream
> import audio4cj.stream.AsyncFrameStream
> ```

## 一、为什么需要 `FrameStream`

f32 交错 PCM 是 **4 字节/样本**。以 44.1 kHz 立体声计算：

| 时长 | 内存占用 |
|---|---|
| 1 分钟 | ≈ 21 MB |
| 10 分钟 | ≈ 212 MB |
| **1 小时** | ≈ **1.27 GB** |

因此 `AudioFile.readAll()` 只能定位为便捷 API，**`FrameStream` 才是主 API**：它每次只交付一块数据，内存占用与音频时长无关。

## 二、`FrameStream`

```cangjie
public class FrameStream {
    public init()
    protected init(reader: FormatReader, decoder: Decoder)

    public func next(): ?AudioBuffer
    public func cancel(): Unit
    public func isCancelled(): Bool
    public func isEnded(): Bool
    public func isClosed(): Bool
    public func close(): Unit
}
```

### 2.1 构造

| 构造 | 可见性 | 说明 |
|---|---|---|
| `FrameStream()` | `public` | **空流**（无后端）。`next()` 立即返回 `None`，视为已结束。主要用于契约测试 |
| `FrameStream(reader, decoder)` | `protected` | 绑定真实后端。**由 `AudioFile.stream()` 在模块内调用**，使用方无法直接构造 |

> 使用方**不应自行构造** `FrameStream`，请一律通过 `AudioFile.stream()` 获取。

> **`FrameStream` 未实现 `Resource` 接口**，因此**不能**写成 `try (s = f.stream()) { ... }`。
> 请用 `try-with-resources` 管理 `AudioFile`（关闭它会连带关闭流），或在需要提前停止时手动调用 `s.close()`。
> 对比：`AsyncFrameStream` **实现了** `Resource`，可以用于 try-with-resources。

### 2.2 成员

| 成员 | 签名 | 说明 |
|---|---|---|
| `next()` | `func next(): ?AudioBuffer` | 取下一条分块。`None` 表示**流已结束**（正常读完或已被取消） |
| `cancel()` | `func cancel(): Unit` | 请求取消（**协作式**，只设标志位） |
| `isCancelled()` | `func isCancelled(): Bool` | 是否已被请求取消 |
| `isEnded()` | `func isEnded(): Bool` | 是否已到达流末尾 |
| `isClosed()` | `func isClosed(): Bool` | 是否已关闭 |
| `close()` | `func close(): Unit` | 关闭流并释放底层读取器（**幂等**） |

## 三、核心语义

### 3.1 `next()` 的 `None` 只表示「结束」

这是本库最重要的契约之一：

| 情况 | 表现 |
|---|---|
| 正常读完 | 返回 `None` |
| 已被取消（`cancel()` 或外部取消请求） | 返回 `None` |
| 空流（无后端） | 返回 `None` |
| **解码失败 / 数据损坏** | **抛出 `DecodeException` 等异常** |
| **对已关闭的流调用 `next()`** | **抛出 `Audio4CjException`** |

**`None` 绝不用于表示错误**。这样调用方可以放心地把 `None` 当作循环终止条件。

### 3.2 取消是协作式的

仓颉**不会强制停止线程**，`cancel()` 只是设置一个标志位。真正的退出发生在下一次 `next()` 调用时：

```text
cancel()  →  设置 _cancelled = true
              ↓
下一次 next()  →  检测到标志  →  返回 None
```

此外，每轮 `next()` 还会检查 `Thread.currentThread.hasPendingCancellation`，以响应**外部**（如 `Future.cancel()` 或线程中断）发来的取消请求。

因此：**取消只会在 `next()` 的边界生效**。如果单次 `next()` 耗时很长，取消的响应也会相应延迟。

### 3.3 ⚠️ `close()` 会关闭底层 reader

`FrameStream.close()` 不仅关闭自身，**还会关闭它所持有的底层 `FormatReader`**。而 `AudioFile.stream()` 返回的 `FrameStream` 与 `AudioFile` **共享同一个 reader 实例**。

这意味着：**关闭流之后，该 `AudioFile` 的数据方法也会失效**。

```cangjie
try (f = AudioFile.open("./demo.wav")) {
    let s = f.stream()
    while (let Some(chunk) <- s.next()) { /* ... */ }
    s.close()

    // ❌ 此时 reader 已关闭
    // let info = f.info()        // 会抛 ClosedResourceException
}
```

**实践建议**：

- 用 `try-with-resources` 管理 `AudioFile` 即可，**不必手动 `close()` 流**——`AudioFile.close()` 会连带关闭它；
- 若确实需要在同一文件上多次遍历，请**重新 `AudioFile.open()`**，而不是复用同一个实例。

> 补充：`AudioFile.readAll()` 与 `readFrames()` 内部也会创建流并在结束时关闭它，因此**它们同样会消耗掉该 `AudioFile` 的 reader**。详见 [facade.md](facade.md#38-readall-与-readframes-的副作用)。

## 四、使用示例

### 4.1 标准消费模式

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./long.wav")) {
        let s = f.stream()
        var totalFrames: Int64 = 0

        // None 即循环终止条件
        while (let Some(chunk) <- s.next()) {
            totalFrames += chunk.frameCount
            // chunk.samples 为 f32 交错样本，可直接消费
        }

        println("共消费 ${totalFrames} 帧")
    }
}
```

### 4.2 中途取消

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./long.wav")) {
        let s = f.stream()
        var frames: Int64 = 0

        while (let Some(chunk) <- s.next()) {
            frames += chunk.frameCount

            // 只处理前 44100 帧（1 秒）
            if (frames >= 44100) {
                s.cancel()
            }
        }

        println("已消费 ${frames} 帧")
        println("是否取消: ${s.isCancelled()}")   // true
        println("是否结束: ${s.isEnded()}")       // false（是被取消，不是自然读完）
    }
}
```

注意 `isCancelled()` 与 `isEnded()` 的区别：前者表示「用户主动中止」，后者表示「自然读到末尾」。两者都会让 `next()` 返回 `None`。

### 4.3 将流写入另一个文件

```cangjie
import audio4cj.facade.AudioFile
import std.fs.*

main() {
    try (f = AudioFile.open("./in.wav")) {
        let s = f.stream()
        while (let Some(chunk) <- s.next()) {
            // chunk.samples 为 Float32，需自行编码后写出
            // 此处仅演示遍历结构
            println("块: ${chunk.frameCount} 帧 / ${chunk.channels} 声道")
        }
    }
}
```

## 五、并发约束

`FrameStream` **非线程安全**，与 `AudioFile` 相同：

- 单个实例**只能被一个线程使用**；
- 不要用多个线程并发调用同一个流的 `next()`（游标竞态会导致数据错乱或丢帧）；
- 需要并行处理多个文件时，**为每个文件创建独立的 `AudioFile` 与 `FrameStream`**。

```cangjie
import audio4cj.facade.AudioFile
import std.sync.SyncCounter

main() {
    let paths = ["./a.wav", "./b.wav", "./c.wav"]
    let counter = SyncCounter(paths.size)

    for (p in paths) {
        spawn {
            try (f = AudioFile.open(p)) {     // 每线程独立实例
                let s = f.stream()
                var n: Int64 = 0
                while (let Some(c) <- s.next()) {
                    n += c.frameCount
                }
                println("${p}: ${n} 帧")
            }
            counter.dec()
        }
    }

    counter.waitUntilZero()   // 必须等待，否则主线程退出会杀死子线程
}
```

> ⚠️ **解码任务必须显式汇合**（`waitUntilZero()` / `Future.get()`）。仓颉的主线程退出会**杀死未完成的子线程**，长音频处理会被静默截断。

## 六、`AsyncFrameStream`：后台解码 + 有界队列背压

`FrameStream` 是**同步拉取**：只有调用 `next()` 时才解码。它天然具备「不调用就不解码」的节流，但**解码与消费无法并行**——当消费侧较慢（写磁盘、滤波、重采样、播放）时，多核完全用不上。

`AsyncFrameStream` 让解码在后台线程进行，经**有界阻塞队列**把数据交给消费线程，使两侧并行；队列满时生产者阻塞在入队处，这就是**背压**，它同时把内存占用封顶在「队列容量 × 单块大小」。

### 6.1 签名

```cangjie
public class AsyncFrameStream <: Resource {
    public static func start(source: FrameStream, queueCapacity!: Int64 = 8): AsyncFrameStream

    public func next(): ?AudioBuffer
    public func isEnded(): Bool
    public func isClosed(): Bool
    public func close(): Unit
}
```

| 成员 | 说明 |
|---|---|
| `start(source, queueCapacity)` | 创建并**立即开始**后台解码。`queueCapacity` 是队列容量（块数），即「允许生产者超前解码多少块」，也就是**内存上限**；必须为正，否则抛 `Audio4CjException` |
| `next()` | 阻塞取下一条分块。返回 `None` **严格且仅表示**流已结束（正常读完或被取消）。对已关闭的流调用会抛 `Audio4CjException` |
| `isEnded()` / `isClosed()` | 状态查询 |
| `close()` | 请求取消源流 → **等待后台线程退出** → 关闭源流（**幂等**） |

### 6.2 三条不变式

1. **内存有界**：任何时刻队列中最多 `queueCapacity` 块，生产者无法超前解码；
2. **结束语义与 `FrameStream` 一致**：`next()` 返回 `None` 只表示结束，错误一律抛异常；
3. **`close()` 必定汇合**：它会等待后台线程**真正退出**。仓颉的主线程退出会杀死未完成的子线程，不汇合会导致解码被静默截断。

### 6.3 用法

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.stream.AsyncFrameStream

main() {
    try (f = AudioFile.open("./long.flac")) {
        // AsyncFrameStream 实现了 Resource，可用 try-with-resources
        try (s = AsyncFrameStream.start(f.stream(), queueCapacity: 4)) {
            while (let Some(chunk) <- s.next()) {
                // 这里的耗时处理与后台解码并行进行
                println("块: ${chunk.frameCount} 帧")
            }
        }
    }
}
```

### 6.4 何时该用

| 场景 | 建议 |
|---|---|
| 消费很快（只统计帧数、求和） | 用 `FrameStream` 即可，异步化没有收益 |
| 消费较慢（编码写出、重采样、推送到设备） | 用 `AsyncFrameStream`，让解码与消费并行 |
| 需要严格控制内存 | 把 `queueCapacity` 调小（最小 `1`，即最严格的背压） |

> **所有权提示**：`source` 的所有权转交 `AsyncFrameStream`，`close()` 会一并关闭源流（进而关闭底层 reader）。
> 因此**不要**在传入之后再使用原 `AudioFile` 的数据方法。
