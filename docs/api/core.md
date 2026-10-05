# `audio4cj.core` API 参考

> 基础契约层：异常体系、音频基础类型、泛型注册表。
>
> ```cangjie
> import audio4cj.core.*
> ```

## 一、异常体系

### 1.1 层次结构

```text
Exception                            （仓颉内置基类）
└── Audio4CjException                （open class，本库异常根类型）
    ├── FormatNotSupportedException
    ├── CorruptedFileException
    ├── DecodeException
    ├── SeekNotSupportedException
    └── ClosedResourceException
```

全部库内异常都继承自 `Audio4CjException`，因此可以用**单条 `catch` 兜住所有库异常**：

```cangjie
try (f = AudioFile.open(path)) {
    // ...
} catch (e: Audio4CjException) {
    println("audio4cj 错误: ${e.message}")
}
```

### 1.2 `Audio4CjException`

异常根类型。

```cangjie
public open class Audio4CjException <: Exception {
    public init(message: String)
    public override func toString(): String
}
```

| 成员 | 说明 |
|---|---|
| `init(message: String)` | 构造，`message` 应描述出错的具体原因 |
| `override func toString(): String` | 返回 `"audio4cj: ${message}"`（带库前缀，便于日志区分） |
| `message: String` | 继承自 `Exception`，可读的详细消息 |

### 1.3 各异常类型

#### `FormatNotSupportedException`

格式不受支持。`message` 中包含探测到的容器 / 编码名，便于定位。

**何时抛出**：

- `AudioFile.open()` 遇到探测层不支持的容器（如 MP3 —— 其解码已移出本版本范围、Ogg/Vorbis、未知格式）；
- 容器虽被识别，但尚无对应实现。

```cangjie
public class FormatNotSupportedException <: Audio4CjException {
    public init(message: String)
}
```

#### `CorruptedFileException`

文件损坏或结构非法。典型触发场景：RIFF 标识缺失、chunk 长度非法、`data` chunk 出现在 `fmt` 之前、文件长度不足。

```cangjie
public class CorruptedFileException <: Audio4CjException {
    public init(message: String)
}
```

#### `DecodeException`

解码失败（坏帧、数据不完整等）。与 `CorruptedFileException` 的区别：前者是**容器结构**问题，后者是**编码数据**问题。

```cangjie
public class DecodeException <: Audio4CjException {
    public init(message: String)
}
```

#### `SeekNotSupportedException`

该格式不支持按时间戳寻址。

```cangjie
public class SeekNotSupportedException <: Audio4CjException {
    public init(message: String)
}
```

#### `ClosedResourceException`

对已关闭的资源执行操作。典型场景：在 `try-with-resources` 块之外继续调用已 `close()` 的 `AudioFile` 方法。

```cangjie
public class ClosedResourceException <: Audio4CjException {
    public init(message: String)
}
```

### 1.4 异常选择速查

| 场景 | 应抛出的异常 |
|---|---|
| 容器无法识别（未知魔数） | `FormatNotSupportedException` |
| 容器已识别但无实现（如当前 MP3） | `FormatNotSupportedException` |
| 容器结构非法（RIFF 标识缺失、chunk 长度非法） | `CorruptedFileException` |
| 编码数据损坏（坏帧） | `DecodeException` |
| 格式不支持 seek | `SeekNotSupportedException` |
| 操作已关闭的对象 | `ClosedResourceException` |

## 二、音频基础类型

### 2.1 `AudioInfo`

音频流的基本信息（**不可变快照**）。

```cangjie
public class AudioInfo {
    public let sampleRate: Int64
    public let channels: Int64
    public let bitDepth: Int64
    public let durationMs: Int64
    public let totalFrames: Int64

    public init(
        sampleRate: Int64,
        channels: Int64,
        bitDepth: Int64,
        durationMs: Int64,
        totalFrames: Int64
    )
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `sampleRate` | `Int64` | 采样率（Hz）。**源文件实际值**，本库不统一采样率 |
| `channels` | `Int64` | 声道数 |
| `bitDepth` | `Int64` | **源位深**：`16` / `24` / `32`；值 `32` 也用于表示 float32。有损格式（当前解码范围内没有）恒为 32 —— 无源位深，该值表示「解码输出为 float32」，**不应**理解为 32 位整数 PCM |
| `durationMs` | `Int64` | 时长（毫秒） |
| `totalFrames` | `Int64` | 总帧数；**`-1` 表示不可知**（如无索引的流式来源） |

> `totalFrames` 的 `-1` 是一个**哨兵值**而非 `Option`。判断时请显式检查 `>= 0`。

### 2.2 `Track`

轨道描述。当前仅单轨（音频）场景使用。

```cangjie
public class Track {
    public let index: Int64
    public let codecId: String
    public let sampleRate: Int64
    public let channels: Int64

    public init(index: Int64, codecId: String, sampleRate: Int64, channels: Int64)
}
```

| 字段 | 说明 |
|---|---|
| `index` | 轨道索引，从 0 开始 |
| `codecId` | 该轨的编码标识，取值来自**解码读取器**（如 `flac` / `pcm`） |
| `sampleRate` | 该轨采样率（Hz） |
| `channels` | 该轨声道数 |

### 2.3 `FormatInfo`

容器与编码描述，由 `AudioFile.format()` 返回（见 [facade.md](facade.md#312-format-与-tracksm6-新增)）。

```cangjie
public class FormatInfo {
    public let container: String
    public let codec: String
    public let codecId: String
    public let mimeType: String

    public init(container: String, codec: String, codecId: String, mimeType: String)
}
```

| 字段 | 说明 |
|---|---|
| `container` | 容器标识（小写）：`wav` / `flac` / `mp3` / `ogg` / `mp4` / … |
| `codec` | 容器内的**子编码**；只有 Ogg 族非空（`flac` / `vorbis` / `opus` / `speex`，判定不出时为空串） |
| `codecId` | 归一化标识：`flac`、`ogg/flac`、`ogg/opus`。**仅供打印 —— 程序化判断请用上面两个字段** |
| `mimeType` | MIME 类型；无法判定时为 `application/octet-stream` |

> **与 `Track.codecId` 的口径差异（容易误用，故写明）**：
> `Track.codecId` 由**解码读取器**给出，不体现容器封装；而 `FormatInfo.codecId`
> 由**探测层**给出，Ogg 族会带上容器前缀。就 Ogg-FLAC 而言，前者是 `flac`、
> 后者是 `ogg/flac` —— 需要"是什么封装"用后者，需要"用哪个读取器解的"用前者。

### 2.4 `CodecParameters`

解码器参数载体，由解码器填充。

```cangjie
public class CodecParameters {
    public var sampleRate: Int64 = 0
    public var channels: Int64 = 0
    public var bitDepth: Int64 = 0
    public var totalFrames: Int64 = -1
}
```

| 字段 | 默认值 | 说明 |
|---|---|---|
| `sampleRate` | `0` | 采样率（Hz） |
| `channels` | `0` | 声道数 |
| `bitDepth` | `0` | 位深 |
| `totalFrames` | `-1` | 总帧数；`-1` 表示不可知 |

> 所有字段都有初值，编译器自动生成无参 `public init()`，可直接 `CodecParameters()` 构造。
> 与 `AudioInfo` 的区别：`AudioInfo` 是不可变快照（对外报告用），`CodecParameters` 是可变载体（解码器内部用）。

## 三、`Registry<T>`

泛型注册表：字符串键 → 实现对象。用于按名称注册与查找格式读取器 / 解码器工厂。

```cangjie
public class Registry<T> {
    public init()

    public func register(key: String, value: T): Unit
    public func get(key: String): ?T
    public func contains(key: String): Bool
    public prop size: Int64
    public func keys(): Array<String>
    public func clear(): Unit
}
```

| 成员 | 说明 |
|---|---|
| `init()` | 构造空注册表 |
| `register(key, value)` | 注册实现。**同键重复注册时后者覆盖前者** |
| `get(key)` | 按键查找；不存在返回 `None`。**`None` 表示「未注册」，不是错误** |
| `contains(key)` | 键是否已注册 |
| `size` | 已注册条目数（只读属性） |
| `keys()` | 全部已注册的键。**顺序不保证** |
| `clear()` | 清空注册表（主要用于测试隔离） |

### 使用示例

```cangjie
import audio4cj.core.Registry

main() {
    let reg = Registry<String>()
    reg.register("wav", "WavFormatReader")

    if (reg.contains("wav")) {
        let name = reg.get("wav") ?? "?"
        println("已注册: ${name}")
    }
    println("条目数: ${reg.size}")
}
```

### 注意事项

- **非线程安全**。注册操作应集中在初始化阶段，避免运行期并发写入；
- **键的大小写敏感**，建议统一使用小写容器名（与探测层 `ProbeResult.container` 保持一致）。

## 四、版本常量

```cangjie
// package audio4cj（根包）
public let AUDIO4CJ_VERSION = "0.1.1"
```

```cangjie
import audio4cj.AUDIO4CJ_VERSION

main() {
    println("audio4cj 版本: ${AUDIO4CJ_VERSION}")
}
```
