package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.FormatNotSupportedException
import audio4cj.core.CorruptedFileException
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * WAV 端到端验收测试 —— 开发文档 §10 M2
 *
 * 设计：**测试自包含** —— 在测试内部用仓颉构造最小 WAV 字节流，
 *       写入临时文件后走完整的 open -> info -> stream/readAll 链路，
 *       再与解析式算出的期望值逐样本比对。不依赖任何外部音频素材。
 *
 * 覆盖 M2 验收条件：96 kHz / 24-bit / 多声道 WAV。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// WAV 构造辅助（小端）
// ---------------------------------------------------------------------------

private func appendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func appendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func appendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

/// 构造最小 PCM WAV 文件字节流（单 fmt + data，无其他 chunk）。
private func buildWav(
    sampleRate: Int64,
    channels: Int64,
    bitsPerSample: Int64,
    samples: Array<Int32>
): Array<UInt8> {
    let bytesPerSample = (bitsPerSample + 7) / 8
    let dataSize = samples.size * bytesPerSample
    let fmtSize: Int64 = 16
    // RIFF 长度 = "WAVE"(4) + (8 + fmtSize) + (8 + dataSize)
    let riffSize = 4 + 8 + fmtSize + 8 + dataSize

    let out = ArrayList<UInt8>()

    appendAscii(out, "RIFF")
    appendUInt32LE(out, riffSize)
    appendAscii(out, "WAVE")

    appendAscii(out, "fmt ")
    appendUInt32LE(out, fmtSize)
    appendUInt16LE(out, 1) // wFormatTag = PCM 整型
    appendUInt16LE(out, channels)
    appendUInt32LE(out, sampleRate)
    appendUInt32LE(out, sampleRate * channels * bytesPerSample) // nAvgBytesPerSec
    appendUInt16LE(out, channels * bytesPerSample) // nBlockAlign
    appendUInt16LE(out, bitsPerSample)

    appendAscii(out, "data")
    appendUInt32LE(out, dataSize)

    for (s in samples) {
        if (bitsPerSample == 8) {
            out.add(UInt8(s & 0xFF))
        } else if (bitsPerSample == 16) {
            out.add(UInt8(s & 0xFF))
            out.add(UInt8((s >> 8) & 0xFF))
        } else if (bitsPerSample == 24) {
            out.add(UInt8(s & 0xFF))
            out.add(UInt8((s >> 8) & 0xFF))
            out.add(UInt8((s >> 16) & 0xFF))
        } else {
            // 32 bit
            out.add(UInt8(s & 0xFF))
            out.add(UInt8((s >> 8) & 0xFF))
            out.add(UInt8((s >> 16) & 0xFF))
            out.add(UInt8((s >> 24) & 0xFF))
        }
    }

    out.toArray()
}

/// 写临时 WAV 并返回路径。
private func writeWav(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 浮点近似比较。
private func closeTo(v: Float32, expected: Float32, eps: Float32): Bool {
    var d = v - expected
    if (d < 0.0) {
        d = -d
    }
    d <= eps
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class WavEndToEndTest {
    /// 16 bit 单声道：归一化精度可精确验证
    @TestCase
    func s16MonoNormalization() {
        let samples: Array<Int32> = [-32768, -16384, 0, 16384, 32767]
        let path = writeWav("a4cj_s16_mono.wav", buildWav(44100, 1, 16, samples))

        try (f = AudioFile.open(path)) {
            let info = f.info()
            @Assert(info.sampleRate == 44100)
            @Assert(info.channels == 1)
            @Assert(info.bitDepth == 16)
            @Assert(info.totalFrames == 5)
            @Assert(info.durationMs == 0) // 5 帧 / 44100 ≈ 0 ms

            let buf = f.readAll()
            @Assert(buf.frameCount == 5)
            @Assert(buf.sampleCount == 5)
            @Assert(buf.sampleRate == 44100)
            @Assert(buf.channels == 1)

            // 精确值（分母为 2^15）
            @Assert(buf.samples[0] == -1.0)
            @Assert(buf.samples[1] == -0.5)
            @Assert(buf.samples[2] == 0.0)
            @Assert(buf.samples[3] == 0.5)
            // 32767 / 32768 = 0.999969...
            @Assert(closeTo(buf.samples[4], 0.999969482421875, 0.0000001))
        }
        remove(path)
    }

    /// M2 验收条件：96 kHz / 24-bit / 立体声
    @TestCase
    func s24Stereo96kHz() {
        // 交错排列：L0 R0 L1 R1 L2 R2
        let samples: Array<Int32> = [
            0,
            0,
            8388607,
            -8388608, // 24-bit 正负满量程
            4194304,
            -4194304 // ±0.5
        ]
        let path = writeWav("a4cj_s24_stereo_96k.wav", buildWav(96000, 2, 24, samples))

        try (f = AudioFile.open(path)) {
            let info = f.info()
            @Assert(info.sampleRate == 96000)
            @Assert(info.channels == 2)
            @Assert(info.bitDepth == 24)
            @Assert(info.totalFrames == 3)

            let buf = f.readAll()
            @Assert(buf.frameCount == 3)
            @Assert(buf.sampleCount == 6)

            @Assert(buf.samples[0] == 0.0)
            @Assert(buf.samples[1] == 0.0)
            // 8388607 / 8388608
            @Assert(closeTo(buf.samples[2], 0.9999998807907104, 0.0000001))
            @Assert(buf.samples[3] == -1.0) // -8388608 / 8388608
            @Assert(buf.samples[4] == 0.5) // 4194304 / 8388608
            @Assert(buf.samples[5] == -0.5)
        }
        remove(path)
    }

    /// 8 bit 为无符号，中点为 128
    @TestCase
    func s8MonoUnsignedBias() {
        let samples: Array<Int32> = [0, 64, 128, 192, 255]
        let path = writeWav("a4cj_s8_mono.wav", buildWav(8000, 1, 8, samples))

        try (f = AudioFile.open(path)) {
            @Assert(f.info().bitDepth == 8)
            let buf = f.readAll()
            @Assert(buf.samples[0] == -1.0) // (0 - 128) / 128
            @Assert(buf.samples[1] == -0.5) // (64 - 128) / 128
            @Assert(buf.samples[2] == 0.0)
            @Assert(buf.samples[3] == 0.5)
            @Assert(closeTo(buf.samples[4], 0.9921875, 0.0000001)) // (255-128)/128
        }
        remove(path)
    }

    /// 多包流式读取：不丢帧、不重复，且与 readAll 结果一致
    @TestCase
    func streamingDoesNotLoseFrames() {
        let n: Int64 = 100000 // 远超单个包上限（64 KiB / 2 字节 = 32768 帧）
        let samples = Array<Int32>(n, repeat: 0)
        for (i in 0..n) {
            samples[i] = Int32(i % 2000) - 1000
        }
        let path = writeWav("a4cj_stream_multi.wav", buildWav(44100, 1, 16, samples))

        // 1) 流式读取：累计帧数必须精确等于 n
        try (f = AudioFile.open(path)) {
            let s = f.stream()
            var frames: Int64 = 0
            var chunks: Int64 = 0
            while (let Some(chunk) <- s.next()) {
                frames += chunk.frameCount
                chunks += 1
            }
            @Assert(frames == n) // 关键：分包不丢帧
            @Assert(chunks > 1) // 确认确实发生了分包
        }

        // 2) readAll 结果应与流式一致（帧数）
        try (f2 = AudioFile.open(path)) {
            let all = f2.readAll()
            @Assert(all.frameCount == n)
            // 抽查首尾样本
            @Assert(all.samples[0] == Float32(-1000) / 32768.0)
            let lastIdx = n - 1
            let expectLast = Float32(Int32(lastIdx % 2000) - 1000) / 32768.0
            @Assert(all.samples[lastIdx] == expectLast)
        }
        remove(path)
    }

    /// 线性寻址：返回实际落点毫秒
    @TestCase
    func seekIsLinearAndReturnsActualPosition() {
        let n: Int64 = 44100 // 1 秒 44.1kHz
        let samples = Array<Int32>(n, repeat: 0)
        let path = writeWav("a4cj_seek_linear.wav", buildWav(44100, 1, 16, samples))

        try (f = AudioFile.open(path)) {
            let actual = f.seekTo(500)
            @Assert(actual == 500)

            // seek 后继续读取应从落点开始，且不超过剩余帧数
            let buf = f.readFrames(100)
            @Assert(buf.frameCount == 100)
        }
        remove(path)
    }

    /// 结构不完整的 FLAC（只有 "fLaC" 标识、无 STREAMINFO）应被拒绝
    ///
    /// M4 起 FLAC 已支持解码，因此 8 字节的假 FLAC 不再抛「格式不支持」，
    /// 而是因结构非法在解析层被拒绝 —— 断言随之调整。
    @TestCase
    func truncatedFlacIsRejected() {
        let fakeFlac: Array<UInt8> = [0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 0] // "fLaC"
        let path = writeWav("a4cj_fake.flac", fakeFlac)

        @AssertThrows[CorruptedFileException](AudioFile.open(path))
        remove(path)
    }

    /// 非音频文件应识别为 unknown 并抛 FormatNotSupportedException
    @TestCase
    func unknownContainerThrows() {
        let junk: Array<UInt8> = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        let path = writeWav("a4cj_junk.bin", junk)

        @AssertThrows[FormatNotSupportedException](AudioFile.open(path))
        remove(path)
    }

    /// 结构损坏的 WAV（缺 data chunk）应抛异常
    @TestCase
    func truncatedWavIsRejected() {
        // 只写 RIFF 头，没有 fmt / data
        let broken: Array<UInt8> = [
            0x52,
            0x49,
            0x46,
            0x46,
            0x04,
            0x00,
            0x00,
            0x00,
            0x57,
            0x41,
            0x56,
            0x45
        ]
        let path = writeWav("a4cj_broken.wav", broken)

        @AssertThrows[Exception](AudioFile.open(path))
        remove(path)
    }
}
