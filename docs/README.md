# audio4cj 文档

> 仓颉生态的统一音频解析库：探测容器格式，解码为统一的 f32 交错 PCM，并提取统一的标签模型。

## 一、项目定位

audio4cj 解决的是仓颉生态中「音频格式各自为政」的问题：把不同容器与编码的差异，收敛到三个统一出口。

| 统一出口 | 类型 | 说明 |
|---|---|---|
| 统一的音频信息 | `AudioInfo` | 采样率、声道数、位深、时长、总帧数 |
| 统一的 PCM 表示 | `AudioBuffer` | **f32 交错**，取值范围 `[-1.0, 1.0]` |
| 统一的标签模型 | `Tag` | 把 ID3 / Vorbis comment / WAV INFO / MP4 `ilst` 等体系收敛为一个类型 |

> **`bitDepth` 的语义提示**：`AudioInfo.bitDepth` 报告**源位深**（16 / 24 / 32）。
> 但对于有损格式（如 MP3）不存在源位深，此时恒为 `32`，含义是「解码输出为 float32」
> ——**不是** 32 位整数 PCM。
>
> **当前可解码格式：WAV / FLAC / Ogg 封装的 FLAC** —— 三者**都是纯仓颉实现**
> （WAV 是未压缩容器，其「解码」本质是位深转换；FLAC 含帧解码、CRC-8/CRC-16 校验与
> SEEKTABLE 定位；Ogg-FLAC 另含页级重组与页 CRC-32 校验）。
> **MP3 自本版本起不在解码范围内**（其解码曾依赖 C 库 dr_mp3），
> 但**仍能被识别、标签仍能读** —— 见下一条。
>
> **标签读取覆盖更广**：WAV / FLAC / MP3 / **OGG**（Vorbis、Opus、FLAC-in-Ogg）/ **MP4**（`ilst`）。

标签读取有两个入口：`AudioFile.metadata()`（打开文件后读取，要求容器可解码）与 **`AudioFile.readTags(path)`**（**不要求解码能力** —— Ogg/Vorbis、MP4 等尚不能解码的容器同样能读出标签）。

设计上有六条贯穿全局的契约，使用前请务必先读 [核心契约](#四六条核心契约)。

## 二、当前进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** | FFI 链路可行性验证（dr_libs 编译、绑定、跨语言调用） | ✅ 已完成 |
| **M1** | 契约与骨架（异常体系、`Tag` 模型、接口与注册表、`AudioFile` 门面） | ✅ 已完成 |
| **M2** | 探测层 + WAV 最短闭环（魔数探测、RIFF 解析、流式读取） | ✅ 已完成 |
| **M3** | 元数据层（ID3v1 / ID3v2、Vorbis comment、WAV LIST/INFO） | ✅ 已完成 |
| **M4** | FLAC + MP3 解码（经 dr_libs FFI，dr_flac / dr_mp3）。⚠ MP3 **解码**已在后续版本移出范围（其标签读取保留） | ✅ 已完成 |
| **M5** | 流式与健壮性（有界队列背压 `AsyncFrameStream`、fuzz 与 CVE 同类回归、长时运行与并发测试） | ✅ 已完成 |
| **M6 前置** | 容器与质量基线扩展（OGG 页重组与 MP4 `ilst` 标签读取、**Ogg 封装 FLAC 解码**、探测层 Ogg 子编码区分、golden PCM 三方比对基线） | ✅ 已完成 |
| **M6** | 发布（多平台 CI、`LICENSES.md` 台账、发布配置） | 🚧 进行中 |
| **M7+** | 各格式陆续改为纯仓颉实现，**C 依赖整体移除**（制品包内不再有任何 C 代码） | ✅ 已完成 |

## 三、文档索引

- **[快速上手](quickstart.md)** —— 环境要求、构建命令、可运行示例、异常处理范式
- **API 参考**
  - [`audio4cj.core`](api/core.md) —— 异常体系、`AudioInfo` / `Track` / `CodecParameters`、`Registry<T>`
  - [`audio4cj.pcm`](api/pcm.md) —— `AudioBuffer`、位深转换与字节解析工具
  - [`audio4cj.meta`](api/meta.md) —— 统一标签模型 `Tag` 与各体系解析器
  - [`audio4cj.stream`](api/stream.md) —— `FrameStream` 同步流式读取、`AsyncFrameStream` 异步背压、协作式取消
  - [`audio4cj.facade`](api/facade.md) —— `AudioFile` 门面（主入口）
- **[OGG / AAC 解码扩展可行性评估](codec-expansion-assessment.md)** —— 候选库、许可证、构建代价、接入点与立项建议
- **[依赖许可证台账](../LICENSES.md)** —— 第三方依赖的来源、许可证与审计流程

## 四、六条核心契约

这六条是库的设计红线，也是使用者最容易踩坑的地方。

### 1. `None` 只表示「该字段不存在」，绝不表示错误

`Tag` 的字段与 `FrameStream.next()` 的返回值都是 `Option`。**`None` 永远不代表失败**：

- `metadata()` 在文件无标签时返回**各字段为 `None` 的空 `Tag`**，而不是 `None`；
- `readTags()` 在容器可识别但无标签（或该容器的标签机制尚未覆盖）时，同样返回**空 `Tag`**；
- `FrameStream.next()` 返回 `None` 表示**流正常结束**；
- 真正的错误一律通过**异常**表达（见契约 6）。

### 2. `AudioFile` 不跨线程共享

单个 `AudioFile` 实例持有文件游标，**只允许在单一线程内使用**。多文件并行处理请创建**独立实例**，不要共用一个。

> `AsyncFrameStream` 内部会用一个后台线程持有源流，因此**不要在交给它之后再使用原 `AudioFile` 的数据方法**（详见 [stream.md](api/stream.md)）。

### 3. `stream()` 是主 API，`readAll()` 是便捷 API

`readAll()` 会把整段音频载入内存。以 f32 交错格式计算，**44.1 kHz 立体声 1 小时约 1.27 GB**：

$$
4\ \text{字节} \times 44100 \times 2 \times 3600 \approx 1.27\ \text{GB}
$$

因此 `readAll()` 带有 `maxFrames` 上限（默认 1000 万帧）。处理长音频请用 `stream()` 分块消费。

### 4. `seekTo()` 返回实际落点

签名是 `seekTo(timestampMs: Int64): Int64`，返回的是**实际到达的位置**而非请求位置。对于按帧定位的格式（如 WAV、FLAC、Ogg-FLAC）二者一致。

### 5. 库不统一采样率，只统一位深与声道布局

所有解码输出统一为 **f32 交错**，但**采样率保持源文件原值**。不同采样率的音频不能直接混音或拼接，需要重采样（不在本库范围内）。

### 6. 资源用 `try-with-resources` 释放，错误用异常表达

`AudioFile` 与 `AsyncFrameStream` 实现了 `Resource` 接口：

```cangjie
try (f = AudioFile.open(path)) {
    // 离开作用域自动 close()
}
```

> **注意**：`FrameStream` **未实现 `Resource`**，因此不能写成 `try (s = f.stream()) { ... }`。
> 用 try-with-resources 管理 `AudioFile` 即可（它会连带关闭流）；需要提前停止时手动调用 `s.close()`。

全部库内异常都继承自 `Audio4CjException`，可用单条 `catch` 兜住。

## 五、质量防线

库对**不可信输入**（用户上传、网络下载的音频文件）做了专门的健壮性建设：

| 防线 | 内容 |
|---|---|
| 单元与契约测试 | 异常体系、`AudioBuffer`、`Tag`、`FrameStream`、`Registry` 等契约的独立验证 |
| 端到端测试 | 在内存中构造音频字节流，走完整的 `open → info → stream/readAll` 链路并逐样本比对，不依赖外部素材 |
| **素材识别矩阵** | 对 `testdata/` 全部素材硬断言探测结果（容器 + 子编码 + 可解码性），与**独立实现**的基准交叉检查 |
| **golden PCM 比对** | 与 **ffmpeg 的解码输出**逐样本比对（实测最大差 **0**）；另有无损互证：同一段 PCM 的 WAV 与 FLAC 封装解码结果必须**逐位相同** |
| **fuzz 测试** | 固定种子的随机字节与变异输入打到探测层、全部标签解析器与打开链路，断言「不崩溃，且只抛库内异常」 |
| **CVE 同类攻击面回归** | 针对「声明长度远超实际数据」「块链永不结束」等攻击面构造畸形容器样本。注意：这是**同类攻击面样本，不是漏洞 PoC 复现**（样本针对的是**我们自己的解析器**；所用第三方库早已是修复版，且现已整体移除）。详见测试文件注释 |
| **长时运行与并发** | 完整解码长素材验证帧数守恒；反复开关文件验证无句柄泄漏；多线程并行解码与串行结果逐位一致 |

> **诚实标注 1**：开发文档 M5 条目中的「峰值内存恒定」目前只做到**结构性与正确性证据**
> （分块大小恒定有界、长素材完整解码、反复开关无句柄泄漏），**未做进程 RSS 的量化测量**
> ——仓颉 std 是否提供内存统计 API 尚未核实。未测项不写成已测项。
>
> **诚实标注 2**：测试套件**不依赖 ffmpeg**（golden 基准已随仓库入库，无损互证本身不需要外部工具），
> 因此可在任何环境完整运行。

## 六、尚未实现

以下能力**当前不可用**，请勿按可用状态编写代码：

| 能力 | 现状 |
|---|---|
| **Ogg/Vorbis、Ogg/Opus、Ogg/Speex 的解码** | 探测层能**精确识别到子编码**（错误信息会写明 `ogg/opus` 等），但 `supported` 为 `false`，`open()` 抛出精确的不支持异常。当前可解码 **WAV / FLAC / Ogg 封装的 FLAC**；**MP3 可识别、标签可读，但不可解码** |
| **AAC 解码**（ADTS 与 MP4 封装） | 同上，识别为 `aac` / `mp4` 但不支持解码。可行性结论见[评估报告](codec-expansion-assessment.md)：现有依赖政策下**无许可干净的候选库**（FAAD2 是 GPL、libfdk-aac 是专有许可） |
| **32-bit float PCM** | `isSupportedPcmFormat(bits, isFloatFormat: true)` 返回 `false`，暂不支持 |
| **重采样** | 无。库只统一位深与声道布局，不改变采样率 |
| **标签写入** | 无，只做读取 |
| **Speex 的注释头** | 未覆盖。Speex 的注释机制与 Vorbis comment 的两种 magic（`\x03vorbis` / `OpusTags`）都不同，`readTags` 对其返回**空 `Tag`**（不报错） |
| **Vorbis comment 的 `METADATA_BLOCK_PICTURE`** | 未覆盖（需要 base64 解码），且该条目会被**显式跳过** —— 避免把数十至数百 KB 的 base64 文本塞进 `Tag.extra` |
| **FLAC 的 `PICTURE` 块（封面）** | 未覆盖。原生 FLAC 与 Ogg-FLAC 的封面块均未解析。注意 **MP4 的 `covr` 与 ID3v2 的 `APIC` 已支持** |
| **MP4 的 `moov` 位于文件中部** | 未覆盖。标签读取覆盖 `moov` 在**文件头**（faststart）与**文件尾**（ffmpeg 默认）两种布局；理论上 `moov` 只会在这两端，但若遇到中间布局的文件则读不到标签 |
| **APE / WavPack 等容器的标签** | 未排期。`readTags` 对这些容器抛 `FormatNotSupportedException` |
| **实时流传输（RTP / RTSP / WebRTC 等）** | 无任何规划，整个实时协议栈均缺失 |

## 七、包与导入

库按职责分为多层，**根包不做聚合导出**，因此必须显式 `import` 具体类型：

```cangjie
import audio4cj.facade.AudioFile          // 主入口
import audio4cj.core.AudioInfo            // 音频信息
import audio4cj.pcm.AudioBuffer           // PCM 缓冲
import audio4cj.meta.Tag                  // 标签模型
import audio4cj.stream.FrameStream        // 流式读取（同步拉取）
import audio4cj.stream.AsyncFrameStream   // 流式读取（异步 + 背压）
import audio4cj.core.Audio4CjException    // 异常根类型
```

| 包 | 可见性 | 说明 |
|---|---|---|
| `audio4cj` | public | 仅 `AUDIO4CJ_VERSION` |
| `audio4cj.core` | public | 异常体系、基础类型、注册表 |
| `audio4cj.pcm` | public | PCM 缓冲与转换工具 |
| `audio4cj.meta` | public | 标签模型与各体系解析器（ID3 / Vorbis comment / WAV INFO / Ogg 页 / MP4 原子） |
| `audio4cj.stream` | public | 流式读取器（`FrameStream` 同步拉取 / `AsyncFrameStream` 异步背压） |
| `audio4cj.facade` | public | 门面 |
| `audio4cj.probe` / `audio4cj.format` / `audio4cj.codec` | 模块内可见 | 内部实现层，不对外暴露 |
