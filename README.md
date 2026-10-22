# audio4cj

> 仓颉（Cangjie）生态的统一音频解析库：**探测容器格式 → 解码为统一的 f32 交错 PCM → 提取统一的标签模型**。

[![CI](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci.yml/badge.svg)](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci.yml)
[![CI Lint](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci-lint.yml/badge.svg)](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci-lint.yml)
[![CodeQL](https://github.com/QianChengYuan/audio4cj/actions/workflows/codeql.yml/badge.svg)](https://github.com/QianChengYuan/audio4cj/actions/workflows/codeql.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**纯仓颉实现 · 零 C 依赖 · Apache-2.0**

## 目录

- [为什么是 audio4cj](#为什么是-audio4cj)
- [能力矩阵](#能力矩阵)
- [快速开始](#快速开始)
- [引入方式](#引入方式)
- [六条核心契约](#六条核心契约)
- [质量保障](#质量保障)
- [文档](#文档)
- [依赖与许可证](#依赖与许可证)

## 为什么是 audio4cj

仓颉生态里，每种音频容器都有自己的头结构、位深约定和标签体系。audio4cj 把这些差异收敛到三个统一出口，让调用方不必为「换一种格式」重写一遍代码。

| 统一出口 | 类型 | 说明 |
|---|---|---|
| 统一的音频信息 | `AudioInfo` | 采样率、声道数、位深、时长、总帧数；MP3 另含码率、VBR、MPEG 版本等锚点信息 |
| 统一的 PCM 表示 | `AudioBuffer` | **f32 交错**，取值范围 `[-1.0, 1.0]` |
| 统一的标签模型 | `Tag` | 把 ID3 / APEv2 / Vorbis comment / WAV INFO / MP4 `ilst` 收敛为一个类型 |

## 能力矩阵

| 能力 | 当前支持 | 入口 |
|---|---|---|
| **解码** | WAV（整型 8/16/24/32 位 + **32 位浮点**）、FLAC、Ogg 封装的 FLAC、MP3（Layer III）、Ogg Vorbis | `AudioFile.open` / `openBytes` |
| **标签读取** | MP3（ID3v1/v2.2/2.3/2.4 + APEv2 尾标签）、FLAC（Vorbis comment + `PICTURE`）、WAV（`LIST/INFO`）、OGG（Vorbis / Opus / FLAC-in-Ogg）、MP4（`ilst`） | `metadata()` / `readTags()` |
| **标签写入**（0.2.0） | MP3（ID3v2.3）、原生 FLAC（Vorbis comment）；只写标准字段、音频数据逐位保留、原子落盘 | `writeTags()` |
| **容器探测** | 十余种容器；Ogg 精确识别到子编码（vorbis / opus / flac / speex） | `format()` |
| **流式读取** | `FrameStream` 同步拉取；`AsyncFrameStream` 后台解码 + 有界队列背压 | `stream()` |
| **PCM 工具** | 位深转换、WAV 打包；峰值 / RMS / dBFS / LUFS / 峰值包络分析（0.2.0） | `audio4cj.pcm` |
| **编码** | FLAC 16 位（0.1.5）/ 24 位（0.2.0）；WAV 8/16/24/32 位 | `audio4cj.encode` / `audio4cj.pcm` |
| **内存直通**（0.2.0） | `openBytes` 对全部可解码容器免落盘；传入数组不拷贝 | `AudioFile.openBytes` |

**可解码 ≠ 可读标签**：Ogg/Opus、MP4 目前不能解码，但标签可以用 `readTags()` 读；AAC 目前既不能解码，也不能读标签。

**明确不做**：Ogg/Opus、Ogg/Speex、AAC、MP4 解码；重采样；WAV / OGG / MP4 标签写入；实时流协议（RTP / RTSP / WebRTC）。完整边界见[文档总览](docs/README.md#六尚未实现)。

## 快速开始

### 解码与流式读取

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./song.flac")) {
        let info = f.info()
        println("${info.sampleRate} Hz / ${info.channels} 声道 / ${info.durationMs} ms")

        // 容器与编码分开可读
        let fmt = f.format()
        println("${fmt.container}/${fmt.codec}（${fmt.mimeType}）")

        // stream() 是主 API：内存占用与音频时长无关
        let s = f.stream()
        while (let Some(chunk) <- s.next()) {
            // chunk.samples 是 f32 交错样本
        }
        s.close()
    }
}
```

### 读取标签与写入标签

```cangjie
import audio4cj.facade.AudioFile
import audio4cj.meta.Tag

main() {
    // 只读标签：不要求容器可解码
    let oldTag = AudioFile.readTags("./song.ogg")
    let oldTitle = oldTag.title ?? "(无标题)"
    println("原标题: ${oldTitle}")

    // 写入标签（0.2.0）：MP3 / 原生 FLAC
    let tag = Tag()
    tag.title = "新歌名"
    tag.artist = "新歌手"
    tag.track = 3
    tag.trackTotal = 12
    AudioFile.writeTags("./song.flac", tag)
}
```

> **版本提示**：`writeTags`、FLAC 24 位编码与 `openBytes` 全容器免落盘均为 **0.2.0** 能力，
> 中心仓已上架，可直接使用。

### 内存打开与编码

```cangjie
import audio4cj.encode.flacBytes
import audio4cj.facade.AudioFile
import audio4cj.pcm.wavBytes
import std.fs.*

main() {
    // 也可以来自 HTTP 分片 / asset / 内存缓冲
    let bytes = File.readFrom(Path("./in.wav"))
    try (f = AudioFile.openBytes(bytes)) {
        let pcm = f.readAll()

        File.writeTo(Path("./out16.flac"), flacBytes(pcm))
        File.writeTo(Path("./out24.flac"), flacBytes(pcm, bitsPerSample: 24))
        File.writeTo(Path("./out.wav"), wavBytes(pcm))
    }
}
```

构建与测试：

```bash
cjpm build      # 构建（纯仓颉，不需要任何 C 工具链）
cjpm test       # 仓库侧全量用例
cjpm check      # 依赖与配置校验
```

> **不需要任何 C 工具链，也没有构建顺序要求**：解码、标签、PCM 与编码全部为纯仓颉实现，
> `cjpm build` / `cjpm test` / `cjpm check` 都不需要 C 编译器，且 `check` 与 `build` 的先后随意。

## 引入方式

| 方式 | 写法 | 适用场景 |
|---|---|---|
| **① 中心仓（推荐）** | `audio4cj = "0.2.0"` | **2026-10-21 起已上架**；以[制品页](https://pkg.cangjie-lang.cn/)版本为准 |
| **② Git 引用** | `audio4cj = { git = "https://gitcode.com/yuan_1992/audio4cj", branch = "main" }` | 需要最新源码或尚未发版的提交时；也可换成 `commitId = "..."` 固定提交 |
| **③ 本地路径引用** | `audio4cj = { path = "../audio4cj" }` | 本机开发 / 测试 |

```toml
# 方式 ①：中心仓（推荐）
[dependencies]
audio4cj = "0.2.0"
```

> 本仓库 `cjpm.toml` 的版本是 **0.3.0**（待发布），中心仓已上架 `0.2.0`（2026-10-21）。
> 三种方式都没有额外前置条件：本库不依赖任何 C 库，也没有需要预置的二进制产物。

## 六条核心契约

这六条是库的设计红线，也是使用者最容易踩坑的地方。完整说明见[文档总览](docs/README.md#四六条核心契约)。

| # | 契约 | 一句话 |
|---|---|---|
| 1 | **`None` 只表示「不存在」** | 标签字段缺失、流正常结束都返回 `None`；真正的错误一律用异常表达 |
| 2 | **`AudioFile` 不跨线程共享** | 单实例持有文件游标；多文件并行请创建独立实例 |
| 3 | **`stream()` 是主 API** | `readAll()` 会把整段音频载入内存，并带 `maxFrames` 上限 |
| 4 | **`seekTo()` 返回实际落点** | 返回值是实际到达的位置，不是请求位置 |
| 5 | **不统一采样率** | 只统一位深与声道布局；输出 f32 交错，采样率沿用源文件 |
| 6 | **资源用 `try-with-resources`** | `AudioFile` / `AsyncFrameStream` 实现 `Resource`；`FrameStream` 不实现，需手动 `close()` |

## 质量保障

库面向**不可信输入**（用户上传、网络下载的音频文件）设计，质量机制包括：

| 防线 | 内容 |
|---|---|
| **golden PCM 比对** | 与**独立第三方解码器**的输出逐样本比对（实测最大差 **0**）；另有无损互证：同一段 PCM 的 WAV 与 FLAC 封装解码结果必须**逐位相同** |
| **素材识别矩阵** | 对 `testdata/` 全部素材硬断言探测结果（容器 + 子编码 + 可解码性），与独立实现交叉检查 |
| **随机输入健壮性** | 固定种子的随机与变异输入打到探测层、全部标签解析器与打开链路 |
| **异常输入回归** | 针对「声明长度远超实际数据」「块链永不结束」等极端声明构造容器样本 |
| **标签写入无损性**（0.2.0） | FLAC 写入前后各解码一次，逐样本比对；MP3 断言音频帧与 APEv2 / ID3v1 尾部原样保留 |
| **免落盘守卫**（0.2.0） | `openBytes` 成功与失败路径均断言临时目录无残留 |
| **长时运行与并发** | 帧数守恒、无句柄泄漏、多线程并行解码与串行结果逐位一致 |
| **静态检查** | `cjfmt` 格式门禁 + 项目级 `cjlint` 规则集（`src/` 实测 0 条告警） |

测试套件**不依赖任何外部工具**，也不需要联网，在**源码仓库内**可完整运行：

> **仓库侧全量 `cjpm test`：335 / 335 通过，`SKIPPED = 0`**
> （2026-10-22 实测，SDK 1.2.0；CI 另按最低支持版本 1.1.0 验证同一套用例）。
>
> **制品包内只带 17 个纯内存、零副作用的测试文件**（当前清单见 `cjpm.toml` 的 `include`
> 白名单）：不读 `testdata/` 语料、不写任何文件，解包后 `cjpm test` 即可跑通，
> **不要求工作目录可写**。包内用例数以包内 `cjpm test` 实测输出为准。
>
> **`testdata/` 语料不随包**（二进制文件，`cjpm bundle` 本就不打包）。
> 想跑含真实语料与外部基准比对的**全量用例**，请从**源码仓库**获取（`testdata/` 已入库）。

## 文档

- **[文档总览与核心契约](docs/README.md)** —— 强烈建议先读这一篇
- [快速上手](docs/quickstart.md) —— 环境要求、可运行示例、异常处理范式
- [更新记录](CHANGELOG.md) —— 各版本面向使用者的变更
- API 参考：[`core`](docs/api/core.md) · [`pcm`](docs/api/pcm.md) · [`meta`](docs/api/meta.md) · [`stream`](docs/api/stream.md) · [`facade`](docs/api/facade.md) · [`encode`](docs/api/encode.md)
- [依赖许可证台账](LICENSES.md) —— 第三方依赖来源、许可证与审计流程

> **关于源码注释里的「开发文档 §X」**：那指的是项目的**内部设计留痕**（设计文档与可行性评估），
> 记录决策过程与取舍理由，**不随本仓库分发**。面向使用者的结论以 `docs/` 为准，
> 不依赖那份内部文档。

## 依赖与许可证

本项目采用 **Apache License 2.0**，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

运行时依赖：**无**。容器探测、各格式解码（WAV / FLAC / Ogg-FLAC / MP3 / Ogg Vorbis）、标签读写、
PCM 处理与 FLAC 编码全部为纯仓颉实现，不依赖任何第三方代码，也不要求 C 工具链。
Ogg Vorbis 解码算法参考了公共领域 / MIT 的 stb_vorbis，但代码是纯仓颉重写、不链接其源文件；
来源与许可证说明见 [LICENSES.md](LICENSES.md)。

> **历史留痕**：本库曾通过 FFI 静态链接一个第三方 C 库承担 FLAC / MP3 / WAV 解码内核；
> 随着各格式陆续改为纯仓颉实现（MP3 是最后一块），该依赖已整体移除
> （连同 `third-party/`、`build.cj` 与 `cjpm.toml` 的 `[ffi.c]`）。
> 依赖台账与移除记录见 [LICENSES.md](LICENSES.md)。

> 本项目只接受**宽许可**依赖（公共领域 / MIT / BSD / Apache-2.0），且不引入专利费。
> 传染性许可与专有许可一律不可用 —— 这也是 AAC 解码至今未立项的原因（无许可干净的候选）。
