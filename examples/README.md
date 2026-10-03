# audio4cj 示例

一个**独立可运行**的 cjpm 工程，用 path 依赖引入仓库根目录的 audio4cj。

它同时也是「消费者视角」的参考：依赖怎么声明、C 库怎么被自动准备、
运行期有什么要求 —— 与真实使用者的处境一致。

## 运行

```bash
cd examples
cjpm run -- <音频文件> [示例名]
```

示例名**缺省为 `stream`** —— 按设计，示例默认展示流式用法。

| 示例 | 内容 |
|---|---|
| `stream`（缺省） | 流式消费：`FrameStream` 同步拉取。**这是本库的主 API**，内存占用与音频时长无关 |
| `async` | 后台解码 + 有界队列背压：`AsyncFrameStream` |
| `tags` | 只读标签：**不要求容器可解码**，因此不受支持的编码通常也能读出标签 |
| `info` | 基本信息（采样率 / 声道 / 位深 / 时长 / 总帧数） |

直接拿仓库自带的测试素材试：

```bash
cjpm run -- ../testdata/flac/flac_s16_44100_stereo.flac
cjpm run -- ../testdata/flac/flac_tagged.flac tags
cjpm run -- ../testdata/flac/flac_s16_44100_stereo.flac async
cjpm run -- ../testdata/flac/flac_s16_44100_stereo.flac info
```

## 两条值得注意的契约

1. **`next()` 返回 `None` 只表示「结束」，绝不表示错误。**
   解码失败会抛异常。因此可以放心把 `None` 当作循环终止条件。
2. **`FrameStream.close()` 会连带关闭底层 reader**，而它与 `AudioFile` 共享同一个
   reader。所以：用 `try-with-resources` 管好 `AudioFile` 即可，不必手动关流；
   要在同一文件上再次遍历，请重新 `AudioFile.open()`，不要复用实例。

## 关于「探测」

本库**当前不暴露**「这是什么容器 / 编码」的查询：容器与子编码只在
`AudioFile.open()` 内部判别，仅当**不受支持**时才通过
`FormatNotSupportedException` 的信息告知使用者（如 `ogg/opus`）。
`AudioInfo` 提供的是采样率、声道、位深、时长、总帧数。

详见 [`src/example_info.cj`](src/example_info.cj) 的说明。

## 更多文档

- [快速上手](../docs/quickstart.md)
- [API 参考](../docs/README.md)
- [发布打包](../docs/release.md)
