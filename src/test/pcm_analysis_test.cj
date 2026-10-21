package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import audio4cj.pcm.*
import std.math.*

/* ============================================================================
 * PCM 分析工具包回归 —— 峰值 / RMS / LUFS / 峰值包络
 *
 * 断言口径：
 *   - 用**解析可算**的素材（常数电平、满幅正弦采样点）核对绝对值，
 *     容差 1e-6（f32 输入经 f64 累加，误差远小于此）；
 *   - LUFS 是简化口径（未做 K 加权分频段），只验「单调性 + 常数电平的
 *     解析值」，不与广播级计量表对标；
 *   - 包络验「桶峰值 ≥ 桶内任意样本」与桶数/边界语义。
 * ========================================================================== */
@Test
class PcmAnalysisTest {
    /// 常数电平 0.5 的单声道：peak=0.5，rms=0.5，dBFS≈-6.0206。
    @TestCase
    func constantLevelHalfMono() {
        let n = 1000
        let samples = Array<Float32>(n, repeat: 0.5)
        let s = analyzeSamples(samples, 1)

        @Expect(s.sampleCount, n)
        @Expect(s.peak, 0.5)
        @Expect(s.rms, 0.5)
        // 20*log10(0.5) = -6.0206
        @Assert(abs(s.peakDbfs - (-6.0206)) < 1e-3)
        @Assert(abs(s.rmsDbfs - (-6.0206)) < 1e-3)
        // LUFS = -0.691 + 10*log10(0.25) = -6.7116
        @Assert(abs(s.lufs - (-6.7116)) < 1e-3)
    }

    /// 满幅方波（全 ±1.0）：peak=1.0，rms=1.0，dBFS=0。
    @TestCase
    func fullScaleSquare() {
        let samples: Array<Float32> = [1.0, -1.0, 1.0, -1.0, 1.0, -1.0]
        let s = analyzeSamples(samples, 1)

        @Expect(s.peak, 1.0)
        @Expect(s.rms, 1.0)
        @Expect(s.peakDbfs, 0.0)
        @Expect(s.rmsDbfs, 0.0)
        @Assert(abs(s.lufs - (-0.691)) < 1e-6)
    }

    /// 全零缓冲：peak/rms 为 0，dBFS/LUFS 钳为 -200，不出现负无穷。
    @TestCase
    func silenceClampsToNegative200() {
        let samples = Array<Float32>(100, repeat: 0.0)
        let s = analyzeSamples(samples, 2)

        @Expect(s.peak, 0.0)
        @Expect(s.rms, 0.0)
        @Expect(s.peakDbfs, -200.0)
        @Expect(s.rmsDbfs, -200.0)
        @Expect(s.lufs, -200.0)
    }

    /// 空输入：返回 EMPTY 快照，不抛异常。
    @TestCase
    func emptyInputReturnsEmptyStats() {
        let s = analyzeSamples(Array<Float32>(), 2)
        @Expect(s.sampleCount, 0)
        @Expect(s.peak, 0.0)
        @Expect(s.peakDbfs, -200.0)

        let e = peakEnvelope(AudioBuffer(44100, 1, Array<Float32>()), 10)
        @Assert(e.size == 0)
    }

    /// 立体声与「双声道同电平的单声道」LUFS 读数应一致（通道归一口径）。
    @TestCase
    func stereoChannelNormalization() {
        let n = 500
        let mono = Array<Float32>(n, repeat: 0.5)
        let stereo = Array<Float32>(n * 2, repeat: 0.5)

        let sm = analyzeSamples(mono, 1)
        let ss = analyzeSamples(stereo, 2)
        @Assert(abs(sm.lufs - ss.lufs) < 1e-6)
        @Expect(ss.peak, 0.5)
        @Expect(ss.rms, 0.5)
    }

    /// 峰值包络：4 帧 × 2 声道分 2 桶，每桶取两声道最大绝对值。
    @TestCase
    func envelopeTwoBinsFromFourFrames() {
        // 帧0:(0.1, 0.9) 帧1:(0.2, 0.3) | 帧2:(0.5,-0.7) 帧3:(0.4, 0.6)
        let buf = AudioBuffer(44100, 2, [0.1, 0.9, 0.2, 0.3, 0.5, -0.7, 0.4, 0.6])
        let env = peakEnvelope(buf, 2)

        @Expect(env.size, 2)
        // 桶0 = max(0.1, 0.9, 0.2, 0.3) = 0.9
        @Expect(env[0], 0.9)
        // 桶1 = max(0.5, 0.7, 0.4, 0.6) = 0.7
        @Expect(env[1], 0.7)
    }

    /// 包络桶数超过帧数时收缩到帧数；bins<=0 返回空。
    @TestCase
    func envelopeBinCountEdgeCases() {
        let buf = AudioBuffer(44100, 1, [0.1, 0.9, 0.2])

        @Expect(peakEnvelope(buf, 10).size, 3)
        @Expect(peakEnvelope(buf, 0).size, 0)
        @Expect(peakEnvelope(buf, -1).size, 0)

        // 单帧单声道 1 桶 = 该样本绝对值
        let one = peakEnvelope(AudioBuffer(44100, 1, [-0.75]), 4)
        @Expect(one.size, 1)
        @Expect(one[0], 0.75)
    }

    /// 包络值必须不小于对应桶内样本绝对值（上界语义），且不超过 1.0。
    @TestCase
    func envelopeBoundsHoldOnRealFile() {
        try (f = AudioFile.open("testdata/wav/wav_s16_44100_stereo.wav")) {
            let head = f.readFrames(8192)
            let env = peakEnvelope(head, 64)

            @Expect(env.size, 64)
            let stats = analyzeBuffer(head)
            for (v in env) {
                @Assert(v >= 0.0 && v <= 1.0)
                @Assert(Float64(v) <= stats.peak + 1e-6)
            }
            // 整体峰值必须等于包络最大值（全帧覆盖时）
            var mx: Float64 = 0.0
            for (v in env) {
                if (Float64(v) > mx) {
                    mx = Float64(v)
                }
            }
            @Assert(abs(mx - stats.peak) < 1e-6)
        }
    }
}
