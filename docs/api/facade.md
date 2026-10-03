# `audio4cj.facade` API 参考

> 门面层。库的唯一对外入口 `AudioFile`。
>
> ```cangjie
> import audio4cj.facade.AudioFile
> ```

## 一、`AudioFile`

```cangjie
public class AudioFile <: Resource {
    public static func open(path: String): AudioFile
    public static func readTags(path: String): Tag
    public prop path: String
    public func metadata(): Tag
    public func info(): AudioInfo
    public func stream(): FrameStream
    public func readAll(maxFrames!: Int64 = 10_000_000): AudioBuffer
    public func readFrames(count: Int64): AudioBuffer
    public func seekTo(timestampMs: Int64): Int64
    public func isClosed(): Bool
    public func close(): Unit
}
```

`AudioFile` 实现了 `Resource` 接口，因此支持 `try-with-resources` 自动释放。

## 二、生命周期

```text
open(path)  →  使用（info / metadata / stream / readAll / seekTo）  →  close()
   ↑                                                                     ↑
探测 + 绑定后端                                            try-with-resources 自动调用
```

**推荐用法**：

```cangjie
try (f = AudioFile.open("./demo.wav")) {
    // 使用 f
}   // 离开作用域自动 close()
```

**关于终结器**：本库**明确禁止**依赖终结器（`~init`）兜底释放资源。原因是终结器触发时机不确定、可能在任意线程运行、带终结器的类不能声明为 `open`，且构造失败对象的终结器不会执行。请始终使用 `try-with-resources` 或显式 `close()`。

## 三、API 详解

### 3.1 `open`

```cangjie
public static func open(path: String): AudioFile
```

打开音频文件：**魔数探测 → 选择实现 → 绑定后端**。

| 参数 | 说明 |
|---|---|
| `path` | 文件路径 |

**抛出**：

| 情形 | 异常 |
|---|---|
| 文件不存在 / 无访问权限 | `std.fs` 的 **`FSException`**（`IOException` 子类，**不是** `Audio4CjException`） |
| 该「容器 + 子编码」组合不受支持 | `FormatNotSupportedException`（信息**精确到编码级**，如 `ogg/opus`） |
| 容器结构损坏 | `CorruptedFileException` |

> ⚠️ **注意第一行**：文件不存在抛的是 `std.fs` 的 `FSException`。若只 `catch (e: Audio4CjException)`，**会漏掉这个最常见的失败情形**。

**当前支持的容器**：

| 容器 | 解码实现 | `bitDepth` 语义 |
|---|---|---|
| `wav` | 纯仓颉（未压缩容器，其「解码」本质是位深转换） | `fmt` 中的真实位深（8 / 16 / 24 / 32） |
| `flac` | dr_libs（FFI，`dr_flac`） | `STREAMINFO` 中的真实位深（通常 16 / 24） |
| `mp3` | dr_libs（FFI，`dr_mp3`） | **恒为 32**，含义是「输出为 float32」—— MP3 是有损格式，无源位深 |
| `ogg` + `flac` | dr_libs（FFI，`dr_flac`）—— **Ogg 封装的 FLAC** 由 dr_flac 原生支持，与原生 FLAC **共用同一套读取器** | `STREAMINFO` 中的真实位深 |

其余 Ogg 子编码（`vorbis` / `opus` / `speex`）与 `aac` / `mp4` 仍抛 `FormatNotSupportedException`，
但异常信息会写明**具体的子编码**（如 `ogg/opus`），而不是笼统的"不支持"；这些容器的**标签**多数可用
[`readTags`](#311-readtags静态m3-新增) 读取。

> **关于 Ogg-FLAC 的 `totalFrames`**：Ogg 封装 FLAC 的 `STREAMINFO` 常把总样本数写成 0
> （编码器写 Ogg 时未必能预知长度），此时 `info().totalFrames` 如实返回 **`-1`「不可知」**
> —— 这是契约行为（见契约 1），不是缺陷。

> **依赖提示**：`wav` 之外的格式依赖 dr_libs，它已**静态链接**进产物
> （`libs/<平台>/libdrlibs.a`），因此运行期不需要分发或加载任何动态库。

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import std.fs.*
import std.io.*

main() {
    try (f = AudioFile.open("./song.wav")) {
        println(f.info().sampleRate)
    } catch (e: FSException) {
        println("文件无法访问: ${e.message}")
    } catch (e: Audio4CjException) {
        println("音频错误: ${e.message}")
    }
}
```

### 3.2 `path`

```cangjie
public prop path: String
```

返回打开该文件时使用的路径（原样保存，不做规范化）。**只读属性**。

### 3.3 `metadata`

```cangjie
public func metadata(): Tag
```

读取标签。

**返回值**：`Tag`。**绝不返回 `None`** —— 文件没有标签时返回各字段为 `None` 的**空 `Tag`**，用 `Tag.hasNoStandardFields()` 判断是否有内容。

**抛出**：`ClosedResourceException`（对象已关闭）。

> M2 阶段该方法是占位实现，对 WAV 返回空 `Tag`；M3 落地后返回真实解析结果。

### 3.4 `info`

```cangjie
public func info(): AudioInfo
```

读取音频基本信息（不可变快照）。

**抛出**：`ClosedResourceException`。

```cangjie
try (f = AudioFile.open("./demo.wav")) {
    let i = f.info()
    println("${i.sampleRate} Hz / ${i.channels} ch / ${i.bitDepth} bit / ${i.durationMs} ms")
}
```

### 3.5 `stream`

```cangjie
public func stream(): FrameStream
```

获取流式读取器（**主 API**）。

**关键语义**：

- **多次调用 `stream()` 会共享同一底层游标** —— 它们不是独立的迭代器。第二次调用会从第一次的位置继续读，而不是从头开始；
- 返回的 `FrameStream` 与 `AudioFile` 共享 reader，**关闭流会使该 `AudioFile` 的数据方法失效**（详见 [stream.md](stream.md#33-️-close-会关闭底层-reader)）。

**抛出**：`ClosedResourceException`。

### 3.6 `readAll`

```cangjie
public func readAll(maxFrames!: Int64 = 10_000_000): AudioBuffer
```

一次性读取全部剩余帧并合并为单个 `AudioBuffer`（**便捷 API，非主推**）。

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `maxFrames` | `Int64`（命名参数） | `10_000_000` | 读取帧数上限（约 40 MB/声道） |

**行为**：

- 达到 `maxFrames` 后**截断**（超出部分不读取），**不抛异常**；
- `maxFrames <= 0` 时返回**空 `AudioBuffer`**；
- 内部逐块读取后合并，因此**它不是零拷贝操作**。

```cangjie
try (f = AudioFile.open("./short.wav")) {
    let buf = f.readAll(maxFrames: 1_000_000)
    println("${buf.frameCount} 帧 / ${buf.sampleCount} 样本")
}
```

> ⚠️ **内存警告**：f32 交错下 44.1 kHz 立体声 **1 小时约 1.27 GB**。处理长音频请用 `stream()`。

### 3.7 `readFrames`

```cangjie
public func readFrames(count: Int64): AudioBuffer
```

读取至多 `count` 帧。内部走与 `readAll` 相同的路径，只是上限换成 `count`。

| 参数 | 说明 |
|---|---|
| `count` | 期望读取的最大帧数。`<= 0` 时返回空 `AudioBuffer` |

**行为**：若剩余帧数不足 `count`，返回实际读到的帧数（不报错）。

```cangjie
try (f = AudioFile.open("./demo.wav")) {
    let actual = f.seekTo(500)
    let buf = f.readFrames(100)      // 从 500 ms 处读 100 帧
    println("读到 ${buf.frameCount} 帧")
}
```

### 3.8 `readAll` 与 `readFrames` 的副作用

**这是使用本类时最容易踩的坑**：

`readAll()` 与 `readFrames()` 内部会创建一个 `FrameStream`，读完（或截断）后**关闭它** —— 而关闭流会**连带关闭底层 reader**。

因此：

| 操作 | 后果 |
|---|---|
| 调用 `readAll()` / `readFrames()` 之后 | 该 `AudioFile` 的**底层 reader 已被关闭**，后续数据方法（`stream()` / `readAll()` / `readFrames()` / `seekTo()` / `info()` / `metadata()`）会失败 |
| 调用 `stream()` 并手动 `close()` 流之后 | 同上 |

**实践建议**：

- **一个 `AudioFile` 实例只做一次完整的数据读取**。需要重新遍历请重新 `AudioFile.open()`；
- 若需「先 seek 再读取」，请**先 `seekTo()` 再 `readFrames()`**（顺序不能颠倒）；
- 优先使用 `stream()` 并在 `try-with-resources` 中管理 `AudioFile`，不要手动关闭流。

### 3.9 `seekTo`

```cangjie
public func seekTo(timestampMs: Int64): Int64
```

按毫秒寻址。

| 参数 | 说明 |
|---|---|
| `timestampMs` | 目标时间戳（毫秒） |

**返回值**：**实际落点毫秒**（不是请求值）。WAV 为按帧线性定位，二者一致；其他格式若只能近似定位，返回值会与请求值不同。

**抛出**：

| 情形 | 异常 |
|---|---|
| 对象已关闭 | `ClosedResourceException` |
| 该格式不支持寻址 | `SeekNotSupportedException` |

### 3.10 `isClosed` 与 `close`

```cangjie
public func isClosed(): Bool
public func close(): Unit
```

`close()` 释放资源（**幂等**，重复调用无副作用），并**一并关闭底层 reader**。`isClosed()` 查询关闭状态。

### 3.11 `readTags`（静态，M3 新增）

```cangjie
public static func readTags(path: String): Tag
```

**只读标签，不要求容器可解码。**

与 `open()` 的关键区别：本方法**不校验容器的解码支持状态**，因此 Ogg/Vorbis、MP4 等尚无解码实现的容器也能读出标签。这是元数据层的主要入口。

| 参数 | 说明 |
|---|---|
| `path` | 文件路径 |

**支持情况**：

| 容器 | 标签来源 | 合并策略 |
|---|---|---|
| `mp3` | ID3v2（文件头）+ ID3v1（文件尾 128 字节） | ID3v2 优先，其空字段由 ID3v1 回填 |
| `flac` | `VORBIS_COMMENT` 元数据块 | — |
| `wav` | `LIST/INFO` 子块 | — |
| `ogg` | 页重组后取注释头：Vorbis 与 Opus 走 Vorbis comment；FLAC-in-Ogg 复原 FLAC 元数据块链后走块解析 | — |
| `mp4` | `moov / udta / meta / ilst` 原子（`moov` 在**文件头或文件尾**都能定位） | — |

> **OGG 的标签不在固定偏移上**：它散落在最前几个 Ogg 页面里，需要做**页重组**
> （含跨页续传）。这是它无法像 FLAC/MP3 那样"读文件头一段就够"的原因。
>
> **Speex 的注释头未覆盖**：其注释机制与 Vorbis comment 的两种 magic 都不同，
> 因此对 Speex 返回**空 `Tag`**（不是报错）。

**返回值**：`Tag`。无标签、或该容器的标签机制尚未覆盖时，返回**空 `Tag`**，绝不返回 `None`。

**抛出**：

| 情形 | 异常 |
|---|---|
| 文件不存在 / 无权限 | `std.fs` 的 `FSException` |
| **无法识别**的格式（探测结果为 `unknown`） | `FormatNotSupportedException` |
| 已识别但标签读取尚未实现（当前如 APE / WavPack / AIFF 等） | `FormatNotSupportedException` |
| 文件结构损坏（如 WAV 缺 fmt/data chunk） | `CorruptedFileException` |

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.core.FormatNotSupportedException

main() {
    try {
        let tag = AudioFile.readTags("./song.mp3")      // MP3 尚不能解码，但标签可读
        let title = tag.title ?? "(无标题)"
        let track = tag.track ?? 0
        let total = tag.trackTotal ?? 0
        println("标题: ${title}")
        println("音轨: ${track}/${total}")
    } catch (e: FormatNotSupportedException) {
        println("该格式的标签读取尚未支持: ${e.message}")
    }
}
```

> **与 `metadata()` 的关系**：两者返回同一 `Tag` 模型。`metadata()` 需要先成功 `open()`（因而仅对可解码格式有效），`readTags()` 直连解析器、不依赖解码链路。对 WAV 而言两者结果一致（共用同一 INFO 解析）。

## 四、异常对照表

| 调用 | 可能抛出的异常 |
|---|---|
| `AudioFile.open(path)` | `FSException`（std.fs）、`FormatNotSupportedException`、`CorruptedFileException` |
| `AudioFile.readTags(path)` | `FSException`（std.fs）、`FormatNotSupportedException`、`CorruptedFileException` |
| `info()` | `ClosedResourceException` |
| `metadata()` | `ClosedResourceException` |
| `stream()` | `ClosedResourceException` |
| `readAll()` / `readFrames()` | `ClosedResourceException`、`DecodeException`（解码失败） |
| `seekTo()` | `ClosedResourceException`、`SeekNotSupportedException` |
| `close()` | 无（幂等） |

## 五、并发契约

`AudioFile` **非线程安全** —— 其持有的 reader 内部有可变游标（文件偏移、已读字节数）。

**规则**：

1. **单实例单线程**：一个 `AudioFile` 实例只在一个线程内使用；
2. **并行请用独立实例**：处理 N 个文件就创建 N 个 `AudioFile`；
3. **必须汇合**：使用 `spawn` 创建的解码任务必须显式等待（`SyncCounter.waitUntilZero()` 或 `Future.get()`），因为**主线程退出会杀死未完成的子线程**。

```cangjie
import audio4cj.facade.AudioFile
import std.sync.SyncCounter

main() {
    let paths = ["./a.wav", "./b.wav", "./c.wav"]
    let counter = SyncCounter(paths.size)

    for (p in paths) {
        spawn {
            try (f = AudioFile.open(p)) {
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

    counter.waitUntilZero()   // 不可省略
}
```

## 六、完整示例

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import std.fs.*
import std.io.*

main() {
    let path = "./demo.wav"

    try (f = AudioFile.open(path)) {
        // 1. 基本信息
        let info = f.info()
        println("采样率: ${info.sampleRate} Hz")
        println("声道数: ${info.channels}")
        println("位深  : ${info.bitDepth} bit")
        println("时长  : ${info.durationMs} ms")

        // 2. 标签
        let tag = f.metadata()
        if (!tag.hasNoStandardFields()) {
            let title = tag.title ?? "(无)"
            let artist = tag.artist ?? "(无)"
            println("标题: ${title}")
            println("艺术家: ${artist}")
        }

        // 3. 流式消费（读完全部帧）
        let s = f.stream()
        var frames: Int64 = 0
        var peak: Float32 = 0.0

        while (let Some(chunk) <- s.next()) {
            frames += chunk.frameCount
            for (v in chunk.samples) {
                let a = if (v < 0.0) { -v } else { v }
                if (a > peak) {
                    peak = a
                }
            }
        }

        println("共 ${frames} 帧，峰值幅度 ${peak}")
    } catch (e: FSException) {
        println("文件无法访问: ${e.message}")
    } catch (e: Audio4CjException) {
        println("音频处理失败: ${e.message}")
    }
}
```
