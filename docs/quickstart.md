# 快速上手

## 一、环境要求

| 项 | 要求 |
|---|---|
| 仓颉 SDK | **1.2.0**（与 `cjpm.toml` 的 `cjc-version = "1.2.0"` 一致） |
| 构建工具 | `cjpm`（随 SDK 提供） |
| 平台 | Windows x86_64（仓库当前只提供了该平台的 C 库产物） |

> **C 库依赖（FLAC / MP3 必需）**
>
> - **WAV** 走纯仓颉实现，**不需要** C 库；
> - **FLAC / MP3** 经 dr_libs 的 FFI 解码，需要 `libs/<平台>/` 下的 `drlibs` 动态库。
>   仓库已提供 Windows x86_64 的产物；Linux / macOS 请先自行编译，
>   编译命令见 `cjpm.toml` 中 `[ffi.c]` 节上方的注释。
> - 以库的形式被**其他工程**引用时，需确保运行期能加载到该动态库
>   （Windows 加载的是**无 `lib` 前缀**的 `drlibs.dll`）。

## 二、引入本项目

audio4cj 是一个 `static` 类型的 cjpm 库工程，尚未发布到中央仓库，使用**本地路径依赖**引入：

```toml
# 你的工程 cjpm.toml
[dependencies]
audio4cj = { path = "../audio4cj" }
```

随后显式导入所需类型（**根包不做聚合导出**，每个类型都要单独 `import`）：

```cangjie
import audio4cj.facade.AudioFile          // 主入口
import audio4cj.core.AudioInfo
import audio4cj.pcm.AudioBuffer
import audio4cj.meta.Tag
import audio4cj.stream.FrameStream
import audio4cj.core.Audio4CjException
```

## 三、构建与测试

```bash
cjpm build          # 构建
cjpm test           # 运行全部单元测试
cjpm test --filter "Wav*.*"       # 只跑 WAV 相关用例
cjpm test --parallel 4            # 并行执行
cjpm clean          # 清理构建产物
```

**不需要手工编译 C 库。** `build.cj` 的 `pre-build` / `pre-test` 钩子会按当前平台
自动准备 dr_libs 薄封装的产物：**优先复用**仓库里 `libs/<平台>/` 的预置产物
（所以即使在没装 C 编译器的 Windows 上也能直接构建），没有预置产物时才现场编译。

`[ffi.c]` 固定指向 `libs/current/`（由该钩子装配），因此**不必**为不同平台改配置。

需要强制重新编译 C 库时（排查构建问题）：

```bash
# Linux / macOS
AUDIO4CJ_FORCE_C_BUILD=1 cjpm build

# Windows PowerShell
$env:AUDIO4CJ_FORCE_C_BUILD="1"; cjpm build
```

> 测试套件**不依赖 ffmpeg**（golden 基准已随仓库入库），也不需要下载任何素材。
> 依赖清单与审计流程见 [LICENSES.md](../LICENSES.md)。

## 四、快速上手示例

> 以下示例对 **WAV / FLAC / MP3** 均适用 —— 三者共用同一套 `AudioFile` API。
> 唯一需留意的是 `bitDepth` 的语义差异：MP3 恒为 `32`（表示输出为 float32，
> 而非 32 位整数 PCM），详见 [`AudioInfo`](api/core.md)。

### 示例 1：读取音频信息

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./demo.wav")) {
        let info = f.info()
        println("采样率: ${info.sampleRate} Hz")
        println("声道数: ${info.channels}")
        println("位深  : ${info.bitDepth} bit")
        println("时长  : ${info.durationMs} ms")
        println("总帧数: ${info.totalFrames}")
    }
}
```

`try (f = ...) { }` 是 `try-with-resources`：离开作用域时自动调用 `f.close()`，无需手写释放，异常路径也不会泄漏。

### 示例 2：流式读取（推荐用法）

处理长音频时用 `stream()` 分块消费，内存占用与音频总时长**无关**：

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./long.wav")) {
        let stream = f.stream()
        var totalFrames: Int64 = 0

        while (let Some(chunk) <- stream.next()) {
            totalFrames += chunk.frameCount
            // chunk.samples 是本块的 f32 交错样本，可直接消费或写出
        }

        println("共读取 ${totalFrames} 帧")
    }
}
```

`next()` 返回 `None` 表示**正常读完**（不是错误）。若需中途取消，调用 `stream.cancel()`，循环会在下一次检查时退出（协作式取消）。

### 示例 3：全量读取（便捷用法，注意内存）

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./short.wav")) {
        // maxFrames 是安全上限，超出会抛异常
        let buf = f.readAll(maxFrames: 1_000_000)

        println("帧数: ${buf.frameCount}，样本数: ${buf.sampleCount}")
        if (buf.sampleCount > 0) {
            println("首个样本: ${buf.samples[0]}")
        }
    }
}
```

> ⚠️ `readAll()` 会把整段音频载入内存。f32 交错下 **44.1 kHz 立体声 1 小时约 1.27 GB**。长音频请改用示例 2。

### 示例 4：按时间寻址

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./demo.wav")) {
        // 跳转到 500 ms 处，返回值是「实际落点」而非请求值
        let actualMs = f.seekTo(500)
        println("实际落点: ${actualMs} ms")

        // 从落点开始读取 100 帧
        let buf = f.readFrames(100)
        println("读到 ${buf.frameCount} 帧")
    }
}
```

### 示例 5：读取标签

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./demo.wav")) {
        let tag = f.metadata()

        if (tag.hasNoStandardFields()) {
            println("该文件没有标准标签字段")
        } else {
            let title = tag.title ?? "(无)"
            let artist = tag.artist ?? "(无)"
            println("标题: ${title}")
            println("艺术家: ${artist}")
        }
    }
}
```

> `metadata()` **绝不返回 `None`**。文件没有标签时，返回的是一个各字段为 `None` 的**空 `Tag`**，用 `hasNoStandardFields()` 判断即可。

### 示例 6：只读标签（不需要解码能力）

MP3、FLAC 等**尚无解码实现**的格式，也能用 `readTags` 读出标签：

```cangjie
import audio4cj.facade.AudioFile

main() {
    let tag = AudioFile.readTags("./song.mp3")      // 不需要 open()，也不要求可解码

    let title = tag.title ?? "(无标题)"
    let artist = tag.artist ?? "(无艺术家)"
    println("标题: ${title}")
    println("艺术家: ${artist}")

    // 冷门字段在 extra 中（键为原始帧 ID / 评论键名）
    for ((k, v) in tag.extra) {
        println("  ${k} = ${v}")
    }
}
```

支持 **MP3**（ID3v2 + ID3v1 合并）、**FLAC**（Vorbis comment）、**WAV**（LIST/INFO）。
无法识别的格式、或尚未覆盖标签的容器（如 OGG）会抛 `FormatNotSupportedException`。

### 示例 7：异步流式读取（解码与消费并行）

`FrameStream` 是同步拉取——**调用 `next()` 时才解码**。如果消费侧较慢（写磁盘、重采样、推送设备），解码与消费就在互相等待。`AsyncFrameStream` 让解码在后台线程进行，用**有界队列**把数据交给消费线程，两侧并行；队列满时后台线程自动停下，这就是**背压**，内存占用由队列容量封顶。

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.stream.AsyncFrameStream

main() {
    try (f = AudioFile.open("./long.flac")) {
        // queueCapacity 是「允许后台超前解码多少块」，也就是内存上限
        try (s = AsyncFrameStream.start(f.stream(), queueCapacity: 4)) {
            while (let Some(chunk) <- s.next()) {
                // 这里的耗时处理与后台解码是并行的
                println("块: ${chunk.frameCount} 帧")
            }
        }
    }
}
```

> 每块最多 16384 帧，立体声下约 128 KiB。因此 `queueCapacity: 4` 的内存上限约 0.5 MB，
> **与音频总时长无关**。`close()` 会等待后台线程真正退出（不汇合会导致解码被静默截断）。

### 示例 8：从 OGG / MP4 读标签（不需要能解码）

`readTags()` **不要求容器可解码**。Ogg/Vorbis、Opus、MP4 这些尚不能解码的容器也能读出标签 —— 因为它们与可解码格式共用同一套解析器（Vorbis comment / `ilst` 原子）。

```cangjie
import audio4cj.facade.AudioFile

main() {
    // Ogg/Vorbis 当前不能解码，但标签可读
    let ogg = AudioFile.readTags("./song.ogg")
    let oggTitle = ogg.title ?? "(无)"
    println("OGG 标题: ${oggTitle}")

    // MP4 / M4A：读 ilst 原子（moov 在文件头或文件尾都能定位）
    let mp4 = AudioFile.readTags("./song.m4a")
    let mp4Title = mp4.title ?? "(无)"
    println("M4A 标题: ${mp4Title}")

    // 封面：MP4 的 covr、ID3v2 的 APIC 都映射到同一对字段
    if (let Some(art) <- mp4.coverArt) {
        let mime = mp4.coverMime ?? "未知"
        println("封面: ${art.size} 字节（${mime}）")
    }
}
```

> **容器可识别但读不出标签时会怎样？** 返回**空 `Tag`**，不抛异常（契约 1）。
> 只有**无法识别**的容器、或**结构损坏到无法继续**才会抛异常。
> 例如 Speex 的注释机制尚未覆盖，读它得到的就是空 `Tag` 而非报错。

## 五、异常处理范式

全部库内异常都继承自 `Audio4CjException`，可以用单条 `catch` 兜住：

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import audio4cj.core.FormatNotSupportedException
import audio4cj.core.CorruptedFileException

main() {
    try (f = AudioFile.open("./maybe.mp3")) {
        println(f.info().sampleRate)
    } catch (e: FormatNotSupportedException) {
        println("格式不支持: ${e.message}")
    } catch (e: CorruptedFileException) {
        println("文件已损坏: ${e.message}")
    } catch (e: Audio4CjException) {
        println("audio4cj 错误: ${e.message}")
    }
}
```

`catch` 按书写顺序匹配，**子类要写在父类之前**（否则父类会遮蔽子类）。

若同时使用 `try-with-resources`，资源会在 `catch` 执行**之前**关闭。

## 六、限制与注意事项

1. **当前可解码 WAV / FLAC / MP3**。OGG / AAC 虽能被探测层识别，但 `AudioFile.open()` 会抛 `FormatNotSupportedException`。仅需读取标签时请用 `AudioFile.readTags()`（支持 MP3 / FLAC / WAV，不要求可解码）。
2. **32-bit float PCM 暂不支持**，`isSupportedPcmFormat(bits, isFloatFormat: true)` 返回 `false`。
3. **`AudioFile` 不跨线程共享**。多文件并行处理请为每个文件创建独立实例。
4. **库不统一采样率**。输出统一为 f32 交错，但采样率沿用源文件，混合不同采样率的音频需自行重采样。
5. **`None` 不代表错误**。它只表示「该字段不存在」或「流已结束」；错误一律以异常形式抛出。
