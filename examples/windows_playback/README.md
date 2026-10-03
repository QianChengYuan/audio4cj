# 解码 → 播放（Windows）

演示把 audio4cj 的解码结果交给 [winsound4cj](https://gitcode.com/yuan_1992/winsound4cj) 播放。

## 运行

```bash
cd examples/windows_playback
cjpm run -- ../../testdata/flac/flac_s16_44100_stereo.flac
```

## 这条链路

```
AudioFile.open → readAll() → AudioBuffer（f32 交错）
      ↓  audio4cj.pcm.wavBytes：f32 → 16 位 PCM + 44 字节 WAV 头
  Array<UInt8>
      ↓  winsound4cj.playWavData（SND_MEMORY）
    扬声器
```

audio4cj 提供**写出方向**的能力（`f32ToPcm` / `wavBytes`），因此中间不需要任何第三方转码工具。

## 适用范围的实话

`winsound4cj` 封装的是 Win32 `PlaySound`，`SND_MEMORY` 的语义是**一次性把一整段 WAV 交给系统**。

| 场景 | 是否合适 |
|---|---|
| 提示音、几秒到几十秒的片段 | ✅ 合适 |
| 分钟级以上的长音频 | ❌ 不合适 —— 必须先把整段解码结果驻留内存 |

1 小时 44.1kHz 立体声约占 **300 MB**（16 位）。这恰恰说明 audio4cj 为何把 `FrameStream` 作为主 API：**PlaySound 用不上流式的优势**。

真正与 `FrameStream` 匹配的是 Win32 的 **`waveOut` 系列** —— 打开设备、反复 `waveOutWrite` 小块，边解码边播、内存恒定、支持任意时长。`winsound4cj` 当前只封装了 `PlaySound`，所以本演示只能走"整段"这条路。

## 依赖

| 依赖 | 方式 | 说明 |
|---|---|---|
| `audio4cj` | path | 仓库根目录 |
| `winsound4cj` | **版本 0.1.2** | 来自仓颉中心仓（非 path，故他人克隆后同样可用） |

## 为什么是独立模块

刻意不并进 `examples/`：`winsound4cj` 是 Windows 专属库，若并进去，`examples/` 整体就都会依赖它，Linux / macOS 上便无法构建。

本演示也**不纳入 CI**：它需要访问外部中心仓，且 CI 运行器没有音频设备（即使构建通过，也听不到任何声音，验证不了什么）。
