package audio4cj.format

/* ============================================================================
 * Packet —— 开发文档 §4.6
 *
 * demuxer 输出的编码后数据单元，由 Decoder 消费。
 * 属项目内部类型，不对外暴露。
 *
 * 可见性说明（重要）：
 *   使用 `protected` 而非 `internal`。原因：
 *     internal  = 当前包及子包可见
 *     protected = 当前模块（整个 cjpm 项目）可见，模块外不可见
 *   codec 包与 format 包是**兄弟包**，internal 类型互相不可见
 *   （实测教训：父包访问不到子包 internal，见开发文档 §12.4.4）。
 *   因此跨包的内部类型必须用 protected。
 * ========================================================================== */

/// 编码后的数据包。
protected class Packet {
    /// 所属轨道索引。
    public let trackIndex: Int64

    /// 编码数据。
    public let data: Array<UInt8>

    /// 起始时间戳（毫秒）。
    public let timestampMs: Int64

    /// 时长（毫秒）。
    public let durationMs: Int64

    public init(trackIndex: Int64, data: Array<UInt8>, timestampMs: Int64, durationMs: Int64) {
        this.trackIndex = trackIndex
        this.data = data
        this.timestampMs = timestampMs
        this.durationMs = durationMs
    }
}
