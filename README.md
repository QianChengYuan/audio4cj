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
| **解码** | WAV、**FLAC**、**Ogg 封装的 FLAC**、**MP3**（四者均为**纯仓颉实现**，不依赖 C 库） |
| **标签读取** | MP3（ID3v1/v2.2/v2.3/v2.4）、FLAC、WAV、**OGG**（Vorbis / Opus / FLAC-in-Ogg）、**MP4**（`ilst`） |
| **容器探测** | 十余种容器，且 Ogg 能**精确识别到子编码**（vorbis / opus / flac / speex）；结果经 `AudioFile.format()` 暴露 |
| **流式读取** | `FrameStream`（同步拉取）与 `AsyncFrameStream`（后台解码 + 有界队列背压） |
| **WAV 写出** | `pcm.wavBytes` / `pcm.f32ToPcm`：把解码结果打包成 WAV 字节（8/16/24/32 位），可转存、可直接交给播放接口 |

标签读取**不要求容器可解码** —— Ogg/Vorbis、MP4 这类尚无解码实现的容器同样能读出标签。

设计上有六条贯穿全局的契约（`None` 不表示错误、`stream()` 是主 API、资源用
`try-with-resources` 等），使用前请先读[核心契约](docs/README.md#四六条核心契约)。

## 引入方式

三种方式，详细写法见[快速上手](docs/quickstart.md#二引入本项目)：

- **① 中心仓**（已上架时优先）：以制品页给出的版本号为准（当前对外已发布 `0.1.2`）；
- **② Git 引用**（**中心仓未上架或审核未通过时用这种**）：
  `audio4cj = { git = "https://gitcode.com/yuan_1992/audio4cj", tag = "v0.1.0" }`
- **③ 本地路径引用**（本机开发 / 测试）：`audio4cj = { path = "../audio4cj" }`

> 本库是纯仓颉实现，**不依赖任何 C 库、也没有需要预置的二进制产物**，
> 因此方式 ② / ③ **没有额外前置条件**：拿到源码用 SDK 自带的 `cjpm` 即可直接构建。

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
cjpm test       # 246 个用例（源码仓库内）
cjpm check      # 依赖与配置校验
```

> **不需要任何 C 工具链，也没有构建顺序要求**：解码全部为纯仓颉实现，
> `cjpm build` / `cjpm test` / `cjpm check` 都不需要 C 编译器，
> 且 `check` 与 `build` 的先后随意。

## 质量保障

库面向**不可信输入**（用户上传、网络下载的音频文件）设计，质量机制包括：

| 防线 | 内容 |
|---|---|
| **golden PCM 比对** | 与 **独立第三方解码器**的解码输出逐样本比对（实测最大差 **0**）；另有无损互证：同一段 PCM 的 WAV 与 FLAC 封装解码结果必须**逐位相同** |
| **素材识别矩阵** | 对 `testdata/` 全部素材硬断言探测结果，与**独立实现**的基准交叉检查 |
| **随机输入健壮性** | 固定种子的随机与变异输入打到探测层、全部标签解析器与打开链路 |
| **异常输入回归** | 针对「声明长度远超实际数据」「块链永不结束」等极端声明构造容器样本 |
| **长时运行与并发** | 帧数守恒、无句柄泄漏、多线程并行解码与串行结果逐位一致 |
| **静态检查** | `cjfmt` 格式门禁 + 项目级 `cjlint` 规则集（`src/` 实测 0 条告警） |

测试套件**不依赖任何外部工具**，也不需要联网，在**源码仓库内**可完整运行
（当前 **246 个用例**，`SKIPPED = 0`）。分发方式带来一处差别，随包的使用者应当知道：

> **制品包交付源码子集：产品代码、公开文档、许可证，以及一组纯内存用例**
> —— 包内含 **14 个测试文件 / 81 个用例**，这些用例不读 `testdata/` 语料、也不写任何
> 临时文件，解包后 `cjpm test` 即可跑通，**不要求工作目录可写**。
>
> **`testdata/` 语料不随包**（二进制文件，`cjpm bundle` 本就不打包）。
> 想跑含真实语料与外部基准比对的**全量 246 条**，请从**源码仓库**获取
> （`testdata/` 已入库）。

## 文档

- **[文档总览与核心契约](docs/README.md)** —— 强烈建议先读这一篇
- [快速上手](docs/quickstart.md) —— 环境要求、可运行示例、异常处理范式
- [更新记录](CHANGELOG.md) —— 各版本面向使用者的变更
- API 参考：[`core`](docs/api/core.md) · [`pcm`](docs/api/pcm.md) · [`meta`](docs/api/meta.md) · [`stream`](docs/api/stream.md) · [`facade`](docs/api/facade.md)
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
（WAV / FLAC / Ogg 封装的 FLAC / MP3）、标签解析与 PCM 处理全部为纯仓颉实现。

> **曾有一个依赖**：`第三方 C 库`（公共领域 / MIT-0），长期承担 FLAC / MP3 / WAV 的解码内核，
> 经 FFI 静态链接。随着各格式陆续改为纯仓颉实现（**MP3 是最后一块**，其解码内核现为
> `src/format/mp3_*.cj`），它已被**整体移除**（连同 `third-party/`、`build.cj`
> 与 `cjpm.toml` 的 `[ffi.c]`）—— 因此本库现在既没有运行时第三方依赖，
> 也没有构建期 C 工具链要求。
> 依赖台账（含它的移除留痕，以及纯仓颉 MP3 内核的算法参照来源）见 [LICENSES.md](LICENSES.md)。

> 本项目只接受**宽许可**依赖（公共领域 / MIT / BSD / Apache-2.0），
> 且不引入专利费。传染性许可与专有许可一律不可用 —— 这也是 AAC 解码
> 至今未立项的原因（无许可干净的候选）。
