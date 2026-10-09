package audio4cj.pcm

import audio4cj.core.Audio4CjException

/* ============================================================================
 * AudioBuffer —— 开发文档 §4.2
 *
 * 统一 PCM 表示：f32 交错（interleaved），取值范围 [-1.0, 1.0]。
 *
 * 关键约束（来自 M0/M1 实测）：
 *   仓颉**不存在 `private(set)` 修饰符**（访问修饰符仅 private / internal /
 *   protected / public 四级），因此"对外只读"必须用
 *   「私有字段 + 只读 prop」实现。
 *
 * 内存提示（详见开发文档 §7.3）：
 *   f32 为 4 字节/样本。44.1kHz 立体声 1 小时 ≈ 1.27 GB。
 *   因此对外主 API 是流式 FrameStream，本类型仅承载**单个分块**。
 * ========================================================================== */

/// 一块 f32 交错 PCM 数据（不可变快照，可跨线程读取）。
public class AudioBuffer {
    /// 采样率（Hz）。源文件实际值，本库不统一采样率。
    public let sampleRate: Int64

    /// 声道数。
    public let channels: Int64

    /// f32 交错样本数据（私有存储，对外只读）
    private let _samples: Array<Float32>

    public init(sampleRate: Int64, channels: Int64, samples: Array<Float32>) {
        this.sampleRate = sampleRate
        this.channels = channels
        this._samples = samples
    }

    /// 交错样本数组（返回内部数据的**副本**）。
    ///
    /// 注意：早期实现直接返回内部数组，调用方改写该数组会破坏本类
    /// "不可变快照"的契约，故改为返回副本；库内热路径需要整体搬运时
    /// 请用 `copyInto`（避免这次额外的分配与拷贝）。
    public prop samples: Array<Float32> {
        get() {
            _samples.clone()
        }
    }

    /// 样本总数（= 帧数 * 声道数）。
    public prop sampleCount: Int64 {
        get() {
            _samples.size
        }
    }

    /// 帧数。声道数非正时返回 0（防御性处理，不抛异常）。
    public prop frameCount: Int64 {
        get() {
            if (channels <= 0) {
                0
            } else {
                _samples.size / channels
            }
        }
    }

    /// 是否为空缓冲。
    public func isEmpty(): Bool {
        _samples.size == 0
    }

    /// 把内部样本整块拷入 `dst` 的 `dstOffset` 起始处，返回写入的样本数。
    ///
    /// 供库内热路径使用：`samples` 现在返回副本，内部搬运（如
    /// `AudioFile.mergeChunks`）无须为读取再额外复制一次整块数据。
    ///
    /// 抛出：`Audio4CjException`（`dstOffset` 为负或 `dst` 空间不足）
    public func copyInto(dst: Array<Float32>, dstOffset: Int64): Int64 {
        let need = _samples.size
        if (dstOffset < 0 || dstOffset > dst.size || need > dst.size - dstOffset) {
            throw Audio4CjException(
                "AudioBuffer.copyInto 目标空间不足：需写入 ${need} 个样本，dst 大小 ${dst.size}，偏移 ${dstOffset}")
        }
        var i = 0
        while (i < need) {
            dst[dstOffset + i] = _samples[i]
            i++
        }
        return need
    }
}
