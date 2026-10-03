# `audio4cj.pcm` API 参考

> PCM 数据层：统一采样缓冲与位深转换工具。
>
> ```cangjie
> import audio4cj.pcm.*
> ```

## 一、统一 PCM 表示

本库所有解码输出的 PCM 都遵循同一约定：

| 约定 | 值 |
|---|---|
| 样本类型 | **`Float32`** |
| 取值范围 | `[-1.0, 1.0]` |
| 声道布局 | **交错**（interleaved），即 `L R L R ...` |
| 采样率 | **沿用源文件**，不做统一（见 [核心契约 5](../README.md#5-库不统一采样率只统一位深与声道布局)） |

## 二、`AudioBuffer`

一块 f32 交错 PCM 数据（**不可变快照，可跨线程读取**）。

```cangjie
public class AudioBuffer {
    public let sampleRate: Int64
    public let channels: Int64

    public init(sampleRate: Int64, channels: Int64, samples: Array<Float32>)

    public prop samples: Array<Float32>
    public prop sampleCount: Int64
    public prop frameCount: Int64
    public func isEmpty(): Bool
}
```

### 2.1 构造

```cangjie
public init(sampleRate: Int64, channels: Int64, samples: Array<Float32>)
```

| 参数 | 说明 |
|---|---|
| `sampleRate` | 采样率（Hz） |
| `channels` | 声道数 |
| `samples` | **f32 交错**样本数组 |

构造后内部持有传入数组的引用，`samples` 属性返回的是**同一份数据**（未做防御性拷贝）。构造后请勿再修改原数组内容，否则会破坏「不可变快照」的语义。

### 2.2 成员

| 成员 | 类型 | 说明 |
|---|---|---|
| `sampleRate` | `Int64` | 采样率（Hz），源文件实际值 |
| `channels` | `Int64` | 声道数 |
| `samples` | `Array<Float32>`（只读属性） | 交错样本数据 |
| `sampleCount` | `Int64`（只读属性） | **样本总数** = `samples.size` = 帧数 × 声道数 |
| `frameCount` | `Int64`（只读属性） | **帧数**。若 `channels <= 0` 返回 `0`（防御性处理，**不抛异常**） |
| `isEmpty()` | `Bool` | 是否为空缓冲（`samples.size == 0`） |

> ⚠️ 注意区分 `sampleCount` 与 `frameCount`：**立体声下 `sampleCount` 是 `frameCount` 的 2 倍**。

### 2.3 使用示例

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./demo.wav")) {
        let buf = f.readAll()
        println("帧数: ${buf.frameCount}，样本数: ${buf.sampleCount}，声道: ${buf.channels}")

        // 按帧遍历（注意跨声道步长）
        let ch = buf.channels
        for (frame in 0..buf.frameCount) {
            let left = buf.samples[frame * ch]
            // ...
        }
    }
}
```

## 三、位深转换

### 3.1 `isSupportedPcmFormat`

```cangjie
public func isSupportedPcmFormat(bitsPerSample: Int64, isFloatFormat: Bool): Bool
```

判断是否为本模块支持的位深 / 格式组合。

| 参数 | 说明 |
|---|---|
| `bitsPerSample` | 位深 |
| `isFloatFormat` | 是否为 IEEE 浮点格式（WAV 的 `wFormatTag == 3`） |

**返回值**：

- `isFloatFormat == true` → **恒返回 `false`**（32-bit float PCM 暂不支持）；
- `isFloatFormat == false` 且 `bitsPerSample ∈ {8, 16, 24, 32}` → `true`；
- 其他位深 → `false`。

> 调用 `pcmToF32` 之前应先用本函数校验，避免得到空结果。

### 3.2 `bytesPerSample`

```cangjie
public func bytesPerSample(bitsPerSample: Int64): Int64
```

计算单个样本占用的字节数，公式为 `(bitsPerSample + 7) / 8`。

| 输入 | 输出 |
|---|---|
| `8` | `1` |
| `16` | `2` |
| `24` | `3` |
| `32` | `4` |

### 3.3 `pcmToF32`

```cangjie
public func pcmToF32(data: Array<UInt8>, bitsPerSample: Int64): Array<Float32>
```

把交错整型 PCM 转换为 f32 交错样本。

| 参数 | 说明 |
|---|---|
| `data` | 原始 PCM 字节流（**小端**） |
| `bitsPerSample` | 位深：`8` / `16` / `24` / `32` |

**返回值**：f32 交错样本数组。位深不受支持时返回空数组。

**归一化规则**（与 dr_libs / ffmpeg 一致）：

| 位深 | 数据类型 | 归一化公式 |
|---|---|---|
| 8 | **无符号**（中点 128） | `(v - 128) / 128.0` |
| 16 | 有符号 | `v / 32768.0` |
| 24 | 有符号（紧凑 3 字节） | `v / 8388608.0` |
| 32 | 有符号 | `v / 2147483648.0` |

**行为细节**：

- 字节流长度不足一个完整样本时，**尾部多余字节被忽略**（不报错）；
- 负的满量程（如 `-32768`）映射到 `-1.0`，正的满量程（如 `32767`）映射到**略小于 1.0**（`0.99997...`）——这是业界通行做法；
- **不做声道与采样率变换**。

```cangjie
import audio4cj.pcm.pcmToF32
import audio4cj.pcm.isSupportedPcmFormat

main() {
    let raw: Array<UInt8> = [0x00, 0x80, 0x00, 0x40]   // 16-bit：-32768, 16384
    if (isSupportedPcmFormat(16, false)) {
        let f = pcmToF32(raw, 16)
        println(f[0])   // -1.0
        println(f[1])   // 0.5
    }
}
```

### 3.4 `f32ToPcm`

```cangjie
public func f32ToPcm(samples: Array<Float32>, bitsPerSample: Int64): Array<UInt8>
```

`pcmToF32` 的**逆变换**：把 f32 交错样本写回整型 PCM 字节。归一化与 `pcmToF32`
严格互逆，因此支持「写出 → 读回」的往返验证。取值一律**向零截断**（除数是 2 的幂，
截断即可精确往返），不做四舍五入。

**会钳位，不会回绕。** 超出 `[-1.0, 1.0]` 的输入被夹到量程边界 —— 回绕会把一个轻微
过冲变成刺耳的爆音（正峰变负峰），那是听感上的故障；钳位只是削顶，属可接受的失真。

两处**固有的**不可逆（来自整型 PCM 本身，不是实现缺陷）：

| 情形 | 说明 |
|---|---|
| 正满量程 | 只能编到 `32767`，读回是 `32767/32768 ≈ 0.99997` 而非 `1.0`（负端 `-32768` 才能到 `-1.0`） |
| 32 位 | **不保证往返精确** —— f32 只有 24 位有效位，承载不了 int32 |

## 四、字节解析工具

解析二进制格式时使用的小端读取工具。三者在 `data` 越界时都会抛出仓颉内置的越界异常，**调用方需自行保证 `offset` 合法**。

### 4.1 `readUInt8`

```cangjie
public func readUInt8(data: Array<UInt8>, offset: Int64): UInt8
```

读取 1 字节。

### 4.2 `readUInt16LE`

```cangjie
public func readUInt16LE(data: Array<UInt8>, offset: Int64): UInt16
```

读取 2 字节**无符号小端**。

### 4.3 `readUInt32LE`

```cangjie
public func readUInt32LE(data: Array<UInt8>, offset: Int64): UInt32
```

读取 4 字节**无符号小端**。

### 4.4 关于有符号读取

`signed` 版本（`readInt16LE` / `readInt24LE` / `readInt32LE`）是**包内私有实现**，不对外暴露。若需自行解析有符号 PCM，注意仓颉的数值转换**默认带溢出检查**：

```cangjie
// ❌ 错误：当原始值 > 32767 时会抛 OverflowException
let v = Int16(readUInt16LE(data, 0))

// ✅ 正确：先加宽再手动做符号扩展
let raw = Int32(readUInt16LE(data, 0))
let v = if (raw > 32767) { raw - 65536 } else { raw }
```

`pcmToF32` 内部已按此方式处理，直接调用它即可，无需自己实现。

## 五、WAV 打包

```cangjie
public func wavBytes(buffer: AudioBuffer, bitsPerSample!: Int64 = 16): Array<UInt8>
```

把一个音频缓冲打包成**内存中的 WAV**（PCM 整型）。这是本库的「写出方向」：

| 用途 | 说明 |
|---|---|
| 转存 | 把 FLAC 等解码结果落成 WAV |
| 播放 | 交给只接受 WAV 的播放接口（如 Windows `PlaySound`，见 `examples/windows_playback/`） |
| 自验证 | 写出的字节交回本库自己的 WAV 读取器，构成往返测试 |

| 参数 | 说明 |
|---|---|
| `buffer` | 采样率与声道数取自它；**不做重采样与声道变换**（本库不统一采样率） |
| `bitsPerSample` | 8 / 16 / 24 / 32，缺省 **16**（最通用的交换格式；交给系统播放时比 32 位浮点更少踩驱动差异） |

**抛出**：`Audio4CjException` —— 位深不受支持、声道数非正、数据区超过 WAV 的 32 位长度上限（约 4 GiB）。

> 只产出字节、不写文件：写文件只多一行 `std.fs`，而"拿到字节"能被更多场景复用
> （内存播放、网络发送、二次加工）。产物落到哪里应由使用者决定。

```cangjie
try (f = AudioFile.open("./song.flac")) {
    let wav = wavBytes(f.readAll())        // 缺省 16 位
    File.writeTo("song.wav", wav)
}
```

## 六、完整示例：手工构造 PCM 并转换

```cangjie
import audio4cj.pcm.AudioBuffer
import audio4cj.pcm.pcmToF32

main() {
    // 16-bit 立体声，两帧：L0 R0 L1 R1
    let raw: Array<UInt8> = [
        0x00, 0x80,     // L0 = -32768 → -1.0
        0x00, 0x40,     // R0 =  16384 →  0.5
        0xFF, 0x7F,     // L1 =  32767 →  0.99997...
        0x00, 0x00      // R1 =      0 →  0.0
    ]

    let samples = pcmToF32(raw, 16)
    let buf = AudioBuffer(44100, 2, samples)

    println("帧数: ${buf.frameCount}")        // 2
    println("样本数: ${buf.sampleCount}")     // 4
    println("L0: ${buf.samples[0]}")          // -1.0
    println("R0: ${buf.samples[1]}")          // 0.5
}
```
