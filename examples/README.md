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

容器与编码通过 `format()` 拿到，且 `container` / `codec` **分开可读**，
因此程序化判断不必去切字符串：

```cangjie
let fmt = f.format()
println("${fmt.codecId}（${fmt.mimeType}）")        // 如 ogg/flac（audio/ogg）
if (fmt.container == "ogg" && fmt.codec == "flac") {
    // Ogg 封装的 FLAC
}
```

`format()` 与 `tracks()` 都是 `open()` 时的**快照**，`close()` 之后仍可读 ——
"先看是什么格式，再决定要不要解码"不必让文件一直开着。

另外，**识别与解码是两件事**：Ogg/Vorbis、MP4 等会被准确识别（连子编码一起），
只是 `open()` 会抛 `FormatNotSupportedException`，其信息里写的就是
`format().codecId` 那套标识。要读它们的**标签**请用示例 `tags`。

详见 [`src/example_info.cj`](src/example_info.cj)。

## 更多文档

- [快速上手](../docs/quickstart.md)
- [API 参考](../docs/README.md)
- [发布打包](../docs/release.md)
- [解码 → 播放（Windows）](windows_playback/README.md) —— 独立模块，用 winsound4cj 把解码结果真正放出来
