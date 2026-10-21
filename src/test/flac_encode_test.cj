package audio4cj.test

import audio4cj.encode.flacBytes
import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import audio4cj.pcm.AudioBuffer
import std.math.sin

/* ============================================================================
 * FLAC 编码测试（audio4cj.encode.flacBytes）
 *
 * 测试策略：**让读取侧来证明写出侧**（与 wav_writer_test 同一口径）。
 *   编码产物交回本库自己的 FLAC 解码器（AudioFile.openBytes）读一遍：
 *     · 16 位：逐样本零误差（s16 缩放与解码定标严格互逆）
 *     · 24 位：s24 量化误差 ≤ 1/8388608（f32→int 截断的单向损失）
 *   两侧独立实现，能互相证伪；位深元数据（STREAMINFO）同样由解码侧核对。
 * ========================================================================== */
@Test
class FlacEncodeTest {
    /// 正弦 + 阶跃混合激励：既有平滑段（考验 fixed 预测）又有跳变段
    /// （考验 verbatim / 高 k Rice），比纯正弦覆盖的子帧路径更全。
    private func makeSweep(frames: Int64, channels: Int64): AudioBuffer {
        let samples = Array<Float32>(frames * channels, repeat: 0.0)
        for (i in 0..frames) {
            for (ch in 0..channels) {
                let idx = i * channels + ch
                if (i < frames / 2) {
                    samples[idx] = Float32(0.5 * sin(Float64(i) * 0.05 + Float64(ch)))
                } else {
                    samples[idx] = Float32(Float64(i % 7 - 3) / 4.0)
                }
            }
        }
        AudioBuffer(44100, channels, samples)
    }

    /// f32 → 参考整数（与编码器同口径：向零截断 + 钳位），用于逐样本比对
    private func refInt(v: Float32, bits: Int64): Int64 {
        let scale = Float64(Int64(1) << (bits - 1))
        var x = Float64(v) * scale
        let posMax = scale - 1.0
        if (x > posMax) {
            x = posMax
        }
        if (x < -scale) {
            x = -scale
        }
        return Int64(x)
    }

    @TestCase
    func encode16RoundtripExact(): Unit {
        let buf = makeSweep(9000, 2)
        let bytes = flacBytes(buf, bitsPerSample: 16)
        @Expect(bytes[0], 0x66) // 'f'
        @Expect(bytes[1], 0x4C) // 'L'

        try (af = AudioFile.openBytes(bytes)) {
            let info = af.info()
            @Expect(info.sampleRate, 44100)
            @Expect(info.channels, 2)
            @Expect(info.bitDepth, 16)
            @Expect(info.durationEstimated, false)

            let out = af.readAll()
            @Expect(out.frameCount, buf.frameCount)
            let src = buf.samples
            let dst = out.samples
            for (i in 0..src.size) {
                @Assert(dst[i] * 32768.0 == Float32(refInt(src[i], 16)))
            }
        }
    }

    @TestCase
    func encode24RoundtripWithinQuantization(): Unit {
        let buf = makeSweep(9000, 2)
        let bytes = flacBytes(buf, bitsPerSample: 24)
        @Expect(bytes[0], 0x66)

        try (af = AudioFile.openBytes(bytes)) {
            let info = af.info()
            @Expect(info.sampleRate, 44100)
            @Expect(info.channels, 2)
            @Expect(info.bitDepth, 24)
            @Expect(info.durationEstimated, false)

            let out = af.readAll()
            @Expect(out.frameCount, buf.frameCount)
            // 无损性：解码值与参考量化值的偏差必须为 0——FLAC 是无损容器，
            // 唯一损失发生在 f32→s24 装填（截断），而参考值复现了同一截断，
            // 因此 roundtrip 仍应逐样本精确相等。
            let src = buf.samples
            let dst = out.samples
            for (i in 0..src.size) {
                @Assert(dst[i] * 8388608.0 == Float32(refInt(src[i], 24)))
            }
        }
    }

    @TestCase
    func encode24PreservesSub15BitDetail(): Unit {
        // 24 位的核心价值：16 位会归零的微小信号在 s24 下被保留。
        // 取 2^-17：×32768 = 0.25（16 位向零截断 → 0），×8388608 = 64（24 位精确保留）
        let tiny = Float32(1.0 / 131072.0)
        let buf = AudioBuffer(44100, 1, [tiny, -tiny])

        // 句柄不 close 会残留 openBytes 的临时文件（审查修复 P2-1 的前提是
        // close 触发清理），这里必须显式关闭
        let f16 = AudioFile.openBytes(flacBytes(buf, bitsPerSample: 16))
        let out16 = f16.readAll()
        f16.close()
        @Expect(out16.samples[0], 0.0) // 16 位下截断为 0
        @Expect(out16.samples[1], 0.0)

        let f24 = AudioFile.openBytes(flacBytes(buf, bitsPerSample: 24))
        let out24 = f24.readAll()
        f24.close()
        @Expect(out24.samples[0] * 8388608.0, 64.0) // 24 位下精确保留
        @Expect(out24.samples[1] * 8388608.0, -64.0)
    }

    @TestCase
    func encodeMonoAndMultiChannel(): Unit {
        for (ch in 1..8) {
            let buf = makeSweep(300, ch)
            let f = AudioFile.openBytes(flacBytes(buf, bitsPerSample: 24))
            let out = f.readAll()
            f.close()
            @Expect(out.frameCount, 300)
            @Expect(out.channels, ch)
            let src = buf.samples
            let dst = out.samples
            for (i in 0..src.size) {
                @Assert(dst[i] * 8388608.0 == Float32(refInt(src[i], 24)))
            }
        }
    }

    @TestCase
    func encodeRejectsUnsupportedBitDepth(): Unit {
        let buf = makeSweep(10, 1)
        @AssertThrows[Audio4CjException](flacBytes(buf, bitsPerSample: 8))
        @AssertThrows[Audio4CjException](flacBytes(buf, bitsPerSample: 20))
        @AssertThrows[Audio4CjException](flacBytes(buf, bitsPerSample: 32))
    }

    @TestCase
    func encodeTailBlockShorterThanFull(): Unit {
        // 5000 帧 = 1 满块 4096 + 尾块 904，覆盖尾块路径（位深 16 / 24 各一遍）
        for (bits in [16, 24]) {
            let buf = makeSweep(5000, 1)
            let f = AudioFile.openBytes(flacBytes(buf, bitsPerSample: bits))
            let out = f.readAll()
            f.close()
            @Expect(out.frameCount, 5000)
            let src = buf.samples
            let dst = out.samples
            for (i in 0..src.size) {
                @Assert(dst[i] * Float32(Float64(1 << (bits - 1))) == Float32(refInt(src[i], bits)))
            }
        }
    }

    @TestCase
    func encodeConstantAndSilence(): Unit {
        // 恒定值块走 constant 子帧；静音是恒定值特例（全 0）
        let flat = AudioBuffer(44100, 1, Array<Float32>(100, repeat: 0.25))
        let f = AudioFile.openBytes(flacBytes(flat, bitsPerSample: 24))
        let out = f.readAll()
        f.close()
        @Expect(out.samples[0] * 8388608.0, 2097152.0)
        @Expect(out.frameCount, 100)

        let silence = AudioBuffer(44100, 2, Array<Float32>(200, repeat: 0.0))
        let f2 = AudioFile.openBytes(flacBytes(silence, bitsPerSample: 16))
        let out2 = f2.readAll()
        f2.close()
        @Expect(out2.frameCount, 100)
        @Expect(out2.samples[199], 0.0)
    }
}
