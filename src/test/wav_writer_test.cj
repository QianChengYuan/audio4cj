package audio4cj.test

import audio4cj.pcm.*
import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import std.fs.*

/* ============================================================================
 * WAV 写出（pcm.f32ToPcm / pcm.wavBytes）
 *
 * 测试策略：**让读取侧来证明写出侧**。
 *   字节级的头部契约单独钉住（写错头部时播放器往往只是"没声音"，极难反查），
 *   而样本数据的正确性则交给最强的验证方式 —— 把写出的 WAV 交回本库自己的
 *   WAV 读取器读一遍，逐样本比对。两侧独立实现，能互相证伪。
 *
 * 临时文件写在 target/ 下（构建产物目录，已被版本控制忽略）。
 * ========================================================================== */
@Test
class WavWriterTest {
    /// 头部字段逐项核对（PCM 整型、44 字节头）。
    @TestCase
    func headerFields(): Unit {
        // 2 个交错样本 = 立体声 1 帧
        let wav = wavBytes(AudioBuffer(44100, 2, [0.0, 0.0]), bitsPerSample: 16)

        @Expect(wav.size, 48) // 44 头 + 2 样本 × 2 字节
        @Expect(matchesAscii(wav, 0, "RIFF"), true)
        @Expect(readUInt32LE(wav, 4), 40u32) // RIFF 块长 = 总长 48 - 8
        @Expect(matchesAscii(wav, 8, "WAVE"), true)
        @Expect(matchesAscii(wav, 12, "fmt "), true)
        @Expect(readUInt32LE(wav, 16), 16u32) // fmt 块长
        @Expect(readUInt16LE(wav, 20), 1u16) // wFormatTag = 1（PCM 整型）
        @Expect(readUInt16LE(wav, 22), 2u16) // 声道数
        @Expect(readUInt32LE(wav, 24), 44100u32) // 采样率
        @Expect(readUInt32LE(wav, 28), 44100u32 * 2 * 2) // nAvgBytesPerSec
        @Expect(readUInt16LE(wav, 32), 4u16) // nBlockAlign = 声道 × 每样本字节
        @Expect(readUInt16LE(wav, 34), 16u16) // 位深
        @Expect(matchesAscii(wav, 36, "data"), true)
        @Expect(readUInt32LE(wav, 40), 4u32) // 数据区
    }

    /// `f32ToPcm` 与 `pcmToF32` 精确互逆（取 2 的幂次组合，可精确表示）。
    @TestCase
    func f32RoundTripsExactly(): Unit {
        let samples: Array<Float32> = [-1.0, -0.5, -0.25, 0.0, 0.25, 0.5]
        let back = pcmToF32(f32ToPcm(samples, 16), 16)

        @Expect(back.size, samples.size)
        var i: Int64 = 0
        while (i < samples.size) {
            @Expect(back[i], samples[i])
            i += 1
        }
    }

    /// 正满量程不可精确表示 —— 这是整型 PCM 的固有性质，显式钉住以免被误当缺陷。
    @TestCase
    func positiveFullScaleIsNotExactlyOne(): Unit {
        let pcm = f32ToPcm([1.0], 16)
        @Expect(readUInt16LE(pcm, 0), 32767u16) // 编码为 32767 而非 32768

        // 读回是 32767/32768 ≈ 0.99997，不是 1.0
        @Expect(pcmToF32(pcm, 16)[0] < 1.0, true)
    }

    /// 超量程必须**钳位**而不是回绕：回绕会把过冲变成反相爆音。
    @TestCase
    func clampsInsteadOfWrapping(): Unit {
        let pcm = f32ToPcm([1.5, -1.5], 16)
        @Expect(readUInt16LE(pcm, 0), 32767u16) // +1.5 → 正满量程（而非回绕成负值）
        @Expect(readUInt16LE(pcm, 2), 32768u16) // -1.5 → 0x8000，即负满量程
    }

    /// 最强的验证：写出的 WAV 由本库自己的读取器读回，逐样本比对。
    /// 写出侧与读取侧是两套独立实现，能互相证伪。
    @TestCase
    func writtenWavIsReadableByThisLibrary(): Unit {
        let frames: Int64 = 100
        let samples = Array<Float32>(frames * 2, repeat: 0.0)
        for (i in 0..frames) {
            let v = Float32(i) / Float32(frames)
            samples[i * 2] = v
            samples[i * 2 + 1] = -v
        }

        let wav = wavBytes(AudioBuffer(44100, 2, samples), bitsPerSample: 16)
        let path = "target/a4cj_wav_writer_roundtrip.wav"
        File.writeTo(path, wav)

        try (f = AudioFile.open(path)) {
            @Expect(f.format().container, "wav")

            let info = f.info()
            @Expect(info.sampleRate, 44100)
            @Expect(info.channels, 2)
            @Expect(info.bitDepth, 16)

            let back = f.readAll()
            @Expect(back.sampleCount, samples.size)

            // 16 位量化误差不超过 1/32768
            let eps: Float32 = 1.0 / 32768.0
            for (i in 0..samples.size) {
                var d = back.samples[i] - samples[i]
                if (d < 0.0) {
                    d = -d
                }
                @Expect(d <= eps, true)
            }
        }
    }

    /// 位深不受支持时报错，且信息里带上实际取值。
    @TestCase
    func rejectsUnsupportedBitDepth(): Unit {
        var thrown = false
        try {
            wavBytes(AudioBuffer(44100, 1, [0.0]), bitsPerSample: 12)
        } catch (e: Audio4CjException) {
            thrown = true
            @Expect(e.message.contains("12"), true)
        }
        @Expect(thrown, true)
    }
}

/// 判断 data[offset..] 是否以 ASCII 字符串 s 开头。
///
/// 不用 String.fromUtf8 之类的反向 API：字节直接比更确定，
/// 不依赖"字符串构造"与"编码假设"这两处不确定。
private func matchesAscii(data: Array<UInt8>, offset: Int64, s: String): Bool {
    let expected = s.toArray()
    if (offset + expected.size > data.size) {
        return false
    }
    var i: Int64 = 0
    while (i < expected.size) {
        if (data[offset + i] != expected[i]) {
            return false
        }
        i += 1
    }
    true
}
