package audio4cj.pcm

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

    /// 交错样本数组（只读视图）。
    public prop samples: Array<Float32> {
        get() {
            _samples
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
}
