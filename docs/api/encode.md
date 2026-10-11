# `audio4cj.encode` —— FLAC 编码（v0.1.5 新增）

把 `audio4cj.pcm.AudioBuffer`（f32 交错 PCM）编码为**完整 FLAC 文件映像**。
纯仓颉实现，零 C 依赖；无损性经双重验证（自解码 roundtrip 逐样本零误差 +
ffmpeg 交叉解码 MD5 与原 WAV 一致）。

## flacBytes

```cangjie
import audio4cj.encode.flacBytes

public func flacBytes(buffer: AudioBuffer, bitsPerSample!: Int64 = 16): Array<Byte>
```

- 输入：`AudioBuffer`（f32 交错，[-1.0, 1.0]，采样率/声道数取自 buffer）
- 输出：完整 FLAC 文件映像（`fLaC` 头 + STREAMINFO + 逐帧），可直接写盘
- `bitsPerSample`：目前仅支持 **16**（s16 口径，与 `wavBytes` 的缩放一致），
  其余值抛 `Audio4CjException`；声道数超出 1..8 同样抛出

### 编码策略

| 项 | 行为 |
|---|---|
| 分帧 | 定长 4096 帧，尾帧允许更短（STREAMINFO 的 min/max 块大小按实际值声明） |
| 子帧类型 | 每声道块自动择优：constant / verbatim / fixed 预测阶 0..4 |
| 残差 | 单分区（分区阶 0）Rice 编码，k 参数按最小位长遍历 0..14 |
| CRC | 帧头 CRC-8 / 帧 CRC-16，与解码侧同源（format 包 `crc8Of` / `crc16Of`） |
| MD5 | STREAMINFO 内置 0（规范允许，表示未计算） |

### 已知边界

- 压缩率低于 libFLAC（无立体声 left/side/right 联合编码、搜索阶有限）
- 非实时：逐位写入有优化空间
- 不做重采样：采样率直接透传

### 用法示例

```cangjie
import audio4cj.encode.flacBytes
import std.fs.*

try (f = AudioFile.open("in.wav")) {
    let buf = f.readAll()
    File.writeTo(Path("./out.flac"), flacBytes(buf, bitsPerSample: 16))
}
```
