package audio4cj.pcm

import std.math.*

/* ============================================================================
 * PCM 分析工具包（v0.2.0）
 *
 * 纯 PCM 上层统计：峰值 / RMS / dBFS / LUFS / 波形峰值包络。
 *
 * 设计边界（与六条核心契约一致）：
 *   - 只做**只读统计**，不做重采样、不改统一表示 —— 输入是任意 AudioBuffer
 *     或交错 f32 序列，输出是标量/数组，不产生新的"统一出口"；
 *   - 全部为纯函数，不持有状态，可跨线程并发调用；
 *   - 空输入返回 0 值标量或空数组，绝不抛异常（统计空数据不是错误）。
 *
 * 口径说明：
 *   - dBFS 以满幅正弦（峰值 1.0）为 0 dB 参照：`20*log10(peak)`；
 *   - LUFS 采用 **K 加权瞬时响度的未加权简化**（K权重在 400Hz~2kHz 带内
 *     增益≈0dB，对窄带测试信号与波形概览场景影响可忽略；完整 ITU-R BS.1770
 *     的分频段 K 加权滤波不在本工具包范围内，如需广播级计量请外接专业库）。
 *     计算式：-0.691 + 10*log10(通道能量和/通道数)；
 *   - 峰值包络面向 UI 波形绘制：把整个缓冲按块取绝对值峰值，块数 = 包络长度。
 * ========================================================================== */

/// 一段 PCM 的整体分析结果（不可变快照）。
public class PcmStats {
    /// 峰值绝对值（[0.0, 1.0]；空输入为 0.0）。
    public let peak: Float64

    /// RMS 电平（均方根；空输入为 0.0）。
    public let rms: Float64

    /// 峰值 dBFS（`20*log10(peak)`；全零缓冲为负无穷，此处钳为 -200.0）。
    public let peakDbfs: Float64

    /// RMS dBFS（`20*log10(rms)`；全零缓冲钳为 -200.0）。
    public let rmsDbfs: Float64

    /// 近似综合响度 LUFS（简化口径，见文件头说明；全零钳为 -200.0）。
    public let lufs: Float64

    /// 样本总数（含全部声道；空输入为 0）。
    public let sampleCount: Int64

    public init(peak: Float64, rms: Float64, lufs: Float64, sampleCount: Int64) {
        this.peak = peak
        this.rms = rms
        this.sampleCount = sampleCount
        this.peakDbfs = dbfsOf(peak)
        this.rmsDbfs = dbfsOf(rms)
        this.lufs = lufs
    }

    public static func EMPTY(): PcmStats {
        PcmStats(0.0, 0.0, -200.0, 0)
    }
}

/// 电平 → dBFS，静音（≤ 0）钳为 -200（避免负无穷不可序列化）。
private func dbfsOf(level: Float64): Float64 {
    if (level <= 0.0) {
        -200.0
    } else {
        20.0 * log10(level)
    }
}

/// 分析一整块交错 PCM（便捷入口）。
public func analyzeBuffer(buf: AudioBuffer): PcmStats {
    analyzeSamples(buf.samples, buf.channels)
}

/// 分析交错 f32 样本序列。
///
/// `channels` 用于 LUFS 的通道归一（<=0 时按单声道处理，不影响 peak/rms）。
public func analyzeSamples(samples: Array<Float32>, channels: Int64): PcmStats {
    let n = samples.size
    if (n == 0) {
        return PcmStats.EMPTY()
    }

    var peak: Float64 = 0.0
    var sumSq: Float64 = 0.0
    var i: Int64 = 0
    while (i < n) {
        let v = Float64(samples[i])
        let a = if (v < 0.0) {
            -v
        } else {
            v
        }
        if (a > peak) {
            peak = a
        }
        sumSq += v * v
        i++
    }
    let rms = sqrt(sumSq / Float64(n))

    // LUFS（简化）：-0.691 + 10*log10(总能量 / 通道数 / 帧数)。
    // 分母按**帧数**（= 样本数/通道数）归一，使立体声与等电平单声道的响度读数一致；
    // 若按样本总数归一，立体声会额外被平均一次，读数整体低 3.01 dB。
    let ch = if (channels <= 0) {
        1
    } else {
        channels
    }
    let frames = Float64(n) / Float64(ch)
    let meanSqPerCh = sumSq / Float64(ch) / frames
    let lufs = if (meanSqPerCh <= 0.0) {
        -200.0
    } else {
        -0.691 + 10.0 * log10(meanSqPerCh)
    }

    PcmStats(peak, rms, lufs, n)
}

/// 波形峰值包络：把交错 PCM 按帧分桶，每桶取**所有声道样本**的最大绝对值。
///
/// 面向 UI 波形绘制：`bins` 即期望的包络点数（如进度条宽度像素数），
/// 帧数不足 `bins` 时点数自动缩到帧数；`bins <= 0` 或空缓冲返回空数组。
/// 取值范围 [0.0, 1.0]。
public func peakEnvelope(buf: AudioBuffer, bins: Int64): Array<Float32> {
    let frames = buf.frameCount
    if (bins <= 0 || frames == 0) {
        return Array<Float32>()
    }
    let nBins = if (bins > frames) {
        frames
    } else {
        bins
    }
    let ch = if (buf.channels <= 0) {
        1
    } else {
        buf.channels
    }
    let out = Array<Float32>(nBins, repeat: 0.0)
    let src = buf.samples

    var b: Int64 = 0
    while (b < nBins) {
        // 首（含）尾（不含）帧范围：均分帧数到各桶
        let f0 = frames * b / nBins
        let f1 = frames * (b + 1) / nBins
        var m: Float64 = 0.0
        var f = f0
        while (f < f1) {
            var c: Int64 = 0
            while (c < ch) {
                let v = Float64(src[f * ch + c])
                let a = if (v < 0.0) {
                    -v
                } else {
                    v
                }
                if (a > m) {
                    m = a
                }
                c++
            }
            f++
        }
        out[b] = Float32(m)
        b++
    }
    out
}
