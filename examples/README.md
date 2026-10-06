# audio4cj 示例

一个**独立可运行**的 cjpm 工程，用 path 依赖引入仓库根目录的 audio4cj。

它同时也是「消费者视角」的参考：依赖怎么声明、构建期与运行期各有什么要求、
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
| `verify` | **端到端验证**：声明帧数 vs 实际解出帧数 + 一行可判读的结论 |

直接拿仓库自带的测试素材试：

```bash
cjpm run -- ../testdata/flac/flac_s16_44100_stereo.flac
cjpm run -- ../testdata/flac/flac_tagged.flac tags
cjpm run -- ../testdata/flac/flac_s16_44100_stereo.flac async
cjpm run -- ../testdata/flac/flac_s16_44100_stereo.flac info

# MP3 同样可解码（素材入库，任何人都能复现）
cjpm run -- ../testdata/mp3/mp3_cbr_128k.mp3 verify
cjpm run -- ../testdata/mp3/mp3_vbr_q4.mp3 verify
cjpm run -- ../testdata/wav/wav_s16_44100_stereo.wav verify
```

## 示例 `verify`：把「解码对不对」变成一行结论

`info` 只回答"是什么格式"，`stream` 只回答"能读完" —— 但**能读不等于读对**：
帧数少了一段，前两个示例都不会吭声。`verify` 把**声明值与实际值**摆在一起对照：

```text
[verify] 容器      : mp3
[verify] 编码      : (无，容器本身即编码) → mp3（audio/mpeg）
[verify] 参数      : 44100 Hz / 2 声道 / 位深 32
[verify] 声明时长  : 1044 ms
[verify] 声明帧数  : 46080
[verify] 实际帧数  : 47232
[verify] 结论      : 通过 —— 有损格式：实际 47232 ≥ 声明 46080，多出 1152 帧
                     （编码器延迟 + 末尾填充，属正常现象；上限 2304 帧）
```

判据**不是示例自创的**，与库内既有口径同源（详见 `src/example_verify.cj` 的文件头）：
无损（wav / flac / ogg+flac）要求「声明 == 实际」；有损（mp3）允许"实际 ≥ 声明"
且多出不超过 2 个压缩帧 —— 多出来的那部分是**编码器延迟与末尾填充帧**，
是有损格式的固有现象，不是缺陷。文件未声明总帧数（如无 Xing 头的流）时只报实际值、不判差值。

**实测（2026-10-06）**：`testdata/mp3/mp3_cbr_128k.mp3` 与两首真实歌曲都**恰好只多出 1152 帧**
（1 个压缩帧）；三首真实 FLAC（含 48 kHz/24 位与 **6 声道**素材）则**声明与实际完全相等**。

> **峰值可以超过 1.0（有损格式）**：MP3 解码不做削顶，素材本身的过冲会原样保留。
> 实测真实歌曲峰值 1.237 / 1.057 —— 用 ffmpeg 在浮点域测同一素材同样 > 1.0（1.096），
> 因此这是**素材事实**而非缺陷。无损格式则必然 ≤ 1.0（16 位下 -32768 恰好对应 -1.0，
> 所以"峰值 = 1.000000"是正常值）。

> **退出码**：示例自身在「不通过」时返回 1（直接运行 `target/release/bin/` 下的可执行文件时可用），
> 但 **`cjpm run` 不会透传程序的退出码**（实测始终为 0）。因此在 CI 里当守卫用时要断言**输出**
> 而不是退出码，见 `.github/workflows/ci.yml` 的示例步骤。

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

另外，**识别与解码是两件事**：Ogg/Vorbis、Ogg/Opus、MP4/AAC 等会被准确识别（连子编码一起），
只是 `open()` 会抛 `FormatNotSupportedException`，其信息里写的就是
`format().codecId` 那套标识。要读它们的**标签**请用示例 `tags`。

当前**可解码**的范围是：WAV / FLAC / MP3 / Ogg 封装的 FLAC（四者都是纯仓颉实现）。
MP3 不在这类"识别得出但不支持"的格式里 —— 它已回到解码范围，用 `verify` 可直接验证。

详见 [`src/example_info.cj`](src/example_info.cj)。

## 用真实歌曲试跑（`musics/`）

合成素材（`testdata/`）是用来做**逐样本比对**的，其价值在于可控；
但真正的"消费者场景"是整首歌曲：几十 MB、带 ID3 标签、联合立体声、数分钟长。
仓库根目录的 `musics/` 就是为此准备的（真实歌曲 + 歌词）。

> ⚠ **`musics/` 不随仓库分发** —— 它是第三方版权内容，已被 `.gitignore` 排除。
> 因此下面这些命令**需要你自备歌曲**（放到 `musics/` 下），CI 也不会跑它们；
> CI 里的可重复验证一律用 `testdata/`。

```bash
cd examples

# 两首 MP3（真实歌曲：ID3v2.4 标签 + 数分钟长）
cjpm run -- "../musics/陈瑞 白狐 - .mp3" verify
cjpm run -- "../musics/大鱼（cover 周深） - Ciky心心.mp3" verify
cjpm run -- "../musics/大鱼（cover 周深） - Ciky心心.mp3" tags

# FLAC 真实歌曲（无损：声明帧数与实际帧数应完全相等）
cjpm run -- "../musics/青花瓷 - 周杰伦.flac" verify
cjpm run -- "../musics/恋人 - 李荣浩.flac" verify
```

> **路径里有空格与全角括号，务必整体加引号** —— 否则会被 shell 拆成多个参数，
> `cjpm run` 只取第一个，表现为"文件不存在"。
>
> ⚠ **Windows + 非 UTF-8 系统代码页下的已知限制（实测，2026-10-06）**：
> 上面的命令若路径含中文，在简体中文 Windows 上会**在进入 `main` 之前**抛
> `IllegalArgumentException: Invalid utf8 byte sequence` —— 原因是运行时把进程命令行
> 参数按 UTF-8 解码，而 Windows 给出的 `GetCommandLineA` 字节是本地代码页（GBK）。
> 这与本库无关（连 `UnknownExample` 这类参数都到不了程序），`chcp 65001` 也不解决问题
> （控制台代码页 ≠ 进程 ANSI 代码页）。
>
> **绕过办法（本次验证就是这么做通的）**：把歌曲复制/重命名为 **ASCII 名**再跑，例如
>
> ```powershell
> $d="$env:TEMP\a4cj_verify"; New-Item -ItemType Directory -Force $d | Out-Null
> Copy-Item "..\musics\陈瑞 白狐 - .mp3" "$d\baihu.mp3"
> cjpm run -- "$d\baihu.mp3" verify
> ```
>
> 内容完全相同（复制不改变码流），因此结论对原歌曲同样成立。若必须在原文件名上跑，
> 可改用 WSL / Git Bash（其 argv 按 UTF-8 传递）。

## 更多文档

- [快速上手](../docs/quickstart.md)
- [API 参考](../docs/README.md)
- [发布打包](../docs/release.md)
- [解码 → 播放（Windows）](windows_playback/README.md) —— 独立模块，用 winsound4cj 把解码结果真正放出来
