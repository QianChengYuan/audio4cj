# audio4cj

> 仓颉（Cangjie）生态的统一音频解析库：**探测容器格式 → 解码为统一的 f32 交错 PCM → 提取统一的标签模型**。

[![CI](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci.yml/badge.svg)](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci.yml)
[![CI Lint](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci-lint.yml/badge.svg)](https://github.com/QianChengYuan/audio4cj/actions/workflows/ci-lint.yml)
[![CodeQL](https://github.com/QianChengYuan/audio4cj/actions/workflows/codeql.yml/badge.svg)](https://github.com/QianChengYuan/audio4cj/actions/workflows/codeql.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## 解决什么问题

仓颉生态里音频格式各自为政：每种容器有自己的头结构、位深约定、标签体系。
audio4cj 把这些差异收敛到三个统一出口，让调用方不必为「换一种格式」重写一遍代码。

| 统一出口 | 类型 | 说明 |
|---|---|---|
| 统一的音频信息 | `AudioInfo` | 采样率、声道数、位深、时长、总帧数 |
| 统一的 PCM 表示 | `AudioBuffer` | **f32 交错**，取值范围 `[-1.0, 1.0]` |
| 统一的标签模型 | `Tag` | 把 ID3 / Vorbis comment / WAV INFO / MP4 `ilst` 收敛为一个类型 |

## 当前能力

| 能力 | 覆盖范围 |
|---|---|
| **解码** | WAV（纯仓颉实现）、FLAC、MP3、**Ogg 封装的 FLAC** |
| **标签读取** | MP3（ID3v1/v2.2/v2.3/v2.4）、FLAC、WAV、**OGG**（Vorbis / Opus / FLAC-in-Ogg）、**MP4**（`ilst`） |
| **容器探测** | 十余种容器，且 Ogg 能**精确识别到子编码**（vorbis / opus / flac / speex） |
| **流式读取** | `FrameStream`（同步拉取）与 `AsyncFrameStream`（后台解码 + 有界队列背压） |

标签读取**不要求容器可解码** —— Ogg/Vorbis、MP4 这类尚无解码实现的容器同样能读出标签。

设计上有六条贯穿全局的契约（`None` 不表示错误、`stream()` 是主 API、资源用
`try-with-resources` 等），使用前请先读[核心契约](docs/README.md#四六条核心契约)。

## 快速开始

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./song.flac")) {
        let info = f.info()
        println("${info.sampleRate} Hz / ${info.channels} 声道")

        // stream() 是主 API：内存占用与音频时长无关
        let s = f.stream()
        while (let Some(chunk) <- s.next()) {
            // chunk.samples 是 f32 交错样本
        }
        s.close()
    }

    // 只读标签：不需要容器可解码
    let tag = AudioFile.readTags("./song.ogg")
    let title = tag.title ?? "(无标题)"
    println("标题: ${title}")
}
```

构建与测试：

```bash
cjpm build      # 首次构建会按平台装配 C 库产物，无需手工编译
cjpm test       # 136 个用例
cjpm check      # 依赖与编译顺序校验（须在 build 之后，原因见下）
```

> **不需要手工编译 C 库**：`build.cj` 的 `pre-build` 钩子会按当前平台自动准备
> 依赖库产物 —— 优先复用 `libs/<平台>/` 的预置产物，没有预置产物时才现场编译。
> 因此 Windows 上即使不装 C 编译器也能直接构建。
>
> **顺序约束**：`cjpm check` 在配置解析阶段就校验 `[ffi.c]` 的库是否存在，
> 而它**不会触发构建脚本**。因此全新克隆后必须先 `cjpm build`、再 `cjpm check`；
> 反过来会报 `can not find the library 'drlibs'`。
> 这是「构建期装配 C 库」的代价，换来的是**仓库不必提交任何平台二进制、
> 永远从源码编译**（也就不会出现「源码改了而入库的库没重编」的陈旧产物问题）。

## 质量保障

库面向**不可信输入**（用户上传、网络下载的音频文件）设计，质量机制包括：

| 防线 | 内容 |
|---|---|
| **golden PCM 比对** | 与 **ffmpeg** 的解码输出逐样本比对（实测最大差 **0**）；另有无损互证：同一段 PCM 的 WAV 与 FLAC 封装解码结果必须**逐位相同** |
| **素材识别矩阵** | 对 `testdata/` 全部素材硬断言探测结果，与**独立实现**的基准交叉检查 |
| **fuzz 测试** | 固定种子的随机与变异输入打到探测层、全部标签解析器与打开链路 |
| **CVE 同类攻击面回归** | 针对「声明长度远超实际数据」「块链永不结束」等攻击面构造畸形容器样本 |
| **长时运行与并发** | 帧数守恒、无句柄泄漏、多线程并行解码与串行结果逐位一致 |
| **静态检查** | `cjfmt` 格式门禁 + 项目级 `cjlint` 规则集（`src/` 实测 0 条告警） |

测试套件**不依赖 ffmpeg、不需要下载素材**，可在任何环境完整运行。

## 文档

- **[文档总览与核心契约](docs/README.md)** —— 强烈建议先读这一篇
- [快速上手](docs/quickstart.md) —— 环境要求、可运行示例、异常处理范式
- API 参考：[`core`](docs/api/core.md) · [`pcm`](docs/api/pcm.md) · [`meta`](docs/api/meta.md) · [`stream`](docs/api/stream.md) · [`facade`](docs/api/facade.md)
- [OGG / AAC 解码扩展可行性评估](docs/codec-expansion-assessment.md) —— 候选库、许可证、构建代价与立项建议

> **关于源码注释里的「开发文档 §X」**：阅读源码时会看到这类指向（例如
> `src/core/exception.cj` 的「开发文档 §4.1」）。那指的是项目的**内部设计留痕**
> —— 设计文档与可行性评估，记录的是决策过程与取舍理由，**不随本仓库分发**。
>
> 这些注释刻意保留：它们记录的是「某处实现依据的是哪条设计决策」，
> 对维护者是有价值的溯源信息。上面的 `docs/` 才是面向使用者的公开文档，
> 其中的结论已自成体系，不依赖那份内部文档。

## 依赖与许可证

本项目采用 **Apache License 2.0**，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

运行时依赖只有一个：[dr_libs](third-party/dr_libs)（公共领域或 MIT-0，二选一），
用于 FLAC / MP3 / Ogg-FLAC 的解码内核。完整的依赖台账、版本锁定与审计流程见
[LICENSES.md](LICENSES.md)。

> 本项目只接受**宽许可**依赖（公共领域 / MIT / BSD / Apache-2.0），
> 且不引入专利费。GPL 系与专有许可一律不可用 —— 这也是 AAC 解码
> 至今未立项的原因（无许可干净的候选，详见可行性评估）。
