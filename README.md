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
| **解码** | WAV、**FLAC**、**Ogg 封装的 FLAC**（三者均为**纯仓颉实现**，不依赖 C 库）。**MP3 不在解码范围内**（解码曾依赖 C 库；其标签读取不受影响，见下行） |
| **标签读取** | MP3（ID3v1/v2.2/v2.3/v2.4）、FLAC、WAV、**OGG**（Vorbis / Opus / FLAC-in-Ogg）、**MP4**（`ilst`） |
| **容器探测** | 十余种容器，且 Ogg 能**精确识别到子编码**（vorbis / opus / flac / speex）；结果经 `AudioFile.format()` 暴露 |
| **流式读取** | `FrameStream`（同步拉取）与 `AsyncFrameStream`（后台解码 + 有界队列背压） |
| **WAV 写出** | `pcm.wavBytes` / `pcm.f32ToPcm`：把解码结果打包成 WAV 字节（8/16/24/32 位），可转存、可直接交给播放接口 |

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

        // 容器与编码（探测结果）：container / codec 分开可读
        let fmt = f.format()
        println("格式: ${fmt.codecId}（${fmt.mimeType}）")

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
cjpm build      # 构建（纯仓颉，不需要任何 C 工具链）
cjpm test       # 206 个用例（源码仓库内，testdata/ 已入库）
cjpm check      # 依赖与配置校验
```

> **不需要任何 C 工具链，也没有构建顺序要求**：解码全部为纯仓颉实现，
> `cjpm build` / `cjpm test` / `cjpm check` 都不需要 C 编译器，
> 且 `check` 与 `build` 的先后随意。
>
> （此前版本依赖 C 库 dr_libs，因而要求"先 `cjpm build` 再 `cjpm check`"，
> 并需要预置各平台的静态库产物。该依赖已**整体移除** —— 见
> [docs/codec-expansion-assessment.md](docs/codec-expansion-assessment.md) 的取舍记录。）

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

测试套件**不依赖 ffmpeg**（基准与素材已随仓库入库），也不需要联网下载任何东西。
但有一处**由分发方式带来的差别**，随包的使用者应当知道：

> **制品包内不含 `testdata/`**（`cjpm bundle` 不打包二进制文件，平台行为），
> 但包内**带** `src/test/` 与两份素材生成脚本 —— 因此**不装 ffmpeg 也不会看到失败**：
> 约 165 条用例照常运行并真实通过（含**不依赖任何素材**的端到端解码：内存中合成 WAV、
> 落盘、经 `AudioFile.open()` 解码并逐样本比对，见 `src/test/async_frame_stream_test.cj`），
> 41 条依赖素材的用例**明确跳过**（原因用 `cjpm test --show-all-output` 查看 —— 框架
> 默认捕获用例输出，不加这个参数看不到）。
>
> **想在包内跑通全部 206 条**：先执行随包分发的素材生成脚本（只需要 ffmpeg），
> 它会就地重建 `testdata/`，然后 `cjpm test`：
>
> ```bash
> # Linux / macOS / Git Bash
> bash scripts/gen_testdata.sh
> # Windows PowerShell
> powershell -ExecutionPolicy Bypass -File scripts\gen_testdata.ps1
>
> cjpm test      # 实测 206 / 206 全通过
> ```
>
> 生成脚本产出的素材全部由**合成信号**编码而来（封面图也由 ffmpeg 现造），
> 不含任何第三方版权内容。不装 ffmpeg 也不影响使用本库 —— 那只是跑不了这些测试而已。
> 要跑全部 206 条而不装 ffmpeg，请从**源码仓库**获取（`testdata/` 已入库）。

## 文档

- **[文档总览与核心契约](docs/README.md)** —— 强烈建议先读这一篇
- [快速上手](docs/quickstart.md) —— 环境要求、可运行示例、异常处理范式
- API 参考：[`core`](docs/api/core.md) · [`pcm`](docs/api/pcm.md) · [`meta`](docs/api/meta.md) · [`stream`](docs/api/stream.md) · [`facade`](docs/api/facade.md)
- [OGG / AAC 解码扩展可行性评估](docs/codec-expansion-assessment.md) —— 候选库、许可证、构建代价与立项建议
- [发布打包](docs/release.md) —— 打包范围白名单、包内容契约、发布元数据与消费者侧要求

> **关于源码注释里的「开发文档 §X」**：阅读源码时会看到这类指向（例如
> `src/core/exception.cj` 的「开发文档 §4.1」）。那指的是项目的**内部设计留痕**
> —— 设计文档与可行性评估，记录的是决策过程与取舍理由，**不随本仓库分发**。
>
> 这些注释刻意保留：它们记录的是「某处实现依据的是哪条设计决策」，
> 对维护者是有价值的溯源信息。上面的 `docs/` 才是面向使用者的公开文档，
> 其中的结论已自成体系，不依赖那份内部文档。

## 依赖与许可证

本项目采用 **Apache License 2.0**，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

运行时依赖：**无**。本库不依赖任何第三方代码 —— 容器探测、各格式解码
（WAV / FLAC / Ogg 封装的 FLAC）、标签解析与 PCM 处理全部为纯仓颉实现。

> **曾有一个依赖**：`dr_libs`（公共领域 / MIT-0），长期承担 FLAC / MP3 / WAV 的解码内核，
> 经 FFI 静态链接。随着各格式陆续改为纯仓颉实现、以及 MP3 解码移出范围，它已被
> **整体移除**（连同 `third-party/`、`build.cj` 与 `cjpm.toml` 的 `[ffi.c]`）——
> 因此本库现在既没有运行时第三方依赖，也没有构建期 C 工具链要求。
> 移除原因与取舍记录见 [docs/codec-expansion-assessment.md](docs/codec-expansion-assessment.md)，
> 依赖台账见 [LICENSES.md](LICENSES.md)。

> 本项目只接受**宽许可**依赖（公共领域 / MIT / BSD / Apache-2.0），
> 且不引入专利费。GPL 系与专有许可一律不可用 —— 这也是 AAC 解码
> 至今未立项的原因（无许可干净的候选，详见可行性评估）。
