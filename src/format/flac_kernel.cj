package audio4cj.format

import audio4cj.drlibs.DrLibsDecoder
import audio4cj.drlibs.DrLibsFormat

/* ============================================================================
 * FLAC 解码内核抽象
 *
 * 【为什么需要这层抽象】
 *   M4 起 FLAC 的解码一直由 dr_libs 经 FFI 承担。要评估并最终落地"纯仓颉
 *   解码"，就必须让「谁来解」成为**可替换的实现细节**，否则业务层与 FFI
 *   直接耦合，任何替换都要动 demuxer 的实现。
 *
 *   抽出本接口后，FlacFormatReader 只依赖接口，不再认识 dr_libs：
 *     - PureFlacKernel   —— 纯仓颉实现（见 flac_bitstream.cj）
 *     - DrLibsFlacKernel —— 经 dr_libs FFI
 *
 *   抽象的回报已经兑现：把原生 FLAC 切到纯仓颉内核，实际只改了
 *   FlacFormatReader.init 里的一处选择，其余方法一行未动。
 *
 * 【当前生产用法（本节是"哪个容器走哪个内核"的唯一说明处）】
 *   原生 FLAC 与 **Ogg 封装的 FLAC** 都走 PureFlacKernel ——
 *   FLAC 这一族无论容器都已零 C 依赖。容器差异**不在两个内核之间**，
 *   而在更下层的**字节源**（flac_source.cj / ogg_flac_source.cj）。
 *   DrLibsFlacKernel 已不在生产路径上，它现在的身份是**独立裁判**：
 *   测试拿它给纯仓颉内核逐样本对账。
 *
 * 【两个实现的关系不是"新旧替换"，而是"互证"】
 *   两者对同一段音频必须产出**逐位相同**的 f32 PCM。这既是对纯仓颉实现的
 *   正确性判据，也让 FFI 路径有了长期存在的理由（保留作对照基准），
 *   与 WAV 侧"纯仓颉为主、dr_libs 作交叉验证"的既有范式一致。
 *
 *   实测中这条互证是**自动发生**的：`probe_matrix` 的
 *   `flacInOggIsDecodableAndMatchesNativeFlac` 打开同一段 PCM 的 Ogg 封装
 *   （走 FFI）与原生 FLAC（走纯仓颉），断言两者逐位相同 —— 它同时成了
 *   两条内核路径的交叉验证，不需要额外写对照用例。
 *
 * 【放在 format 包而非 codec 包的原因】
 *   codec 包已经依赖 format（Codec 需要 format.Packet），若把本接口放进
 *   codec，format 引用它就形成循环依赖。本接口描述的是"如何从 FLAC 比特流
 *   得到 PCM"，与 demuxer 同属一层，放在 format 是依赖方向上的正确位置。
 * ========================================================================== */

/// FLAC 解码内核。
///
/// 契约（与既有 demuxer 约定保持一致）：
///   - `totalFrames()` 返回 0 表示**不可知**，由调用方翻译为 -1；
///   - `readF32Into()` 返回 0 表示**流正常结束**，不是错误；
///   - 数据损坏一律抛异常（绝不用返回值表达错误）。
protected interface FlacDecodeKernel {
    func sampleRate(): Int64

    func channels(): Int64

    func bitsPerSample(): Int64

    /// 总帧数；**0 表示不可知**。
    func totalFrames(): Int64

    /// 定位到指定 PCM 帧索引，返回是否成功。
    func seekToFrame(index: Int64): Bool

    /// 读取至多 `frames` 帧的 f32 交错 PCM，写入 `bytes`
    /// （要求 `bytes.size >= frames * channels * 4`），返回实际读到的帧数。
    func readF32Into(bytes: Array<UInt8>, frames: Int64): Int64

    func close(): Unit

    func isClosed(): Bool
}

/// 经 dr_libs FFI 的 FLAC 解码内核。
///
/// 这一层只做「接口适配」：把 DrLibsDecoder 的方法名映射为内核接口，
/// 不添加任何逻辑 —— 逻辑留在 DrLibsDecoder 里，避免同一件事有两处实现。
protected class DrLibsFlacKernel <: FlacDecodeKernel {
    private let _decoder: DrLibsDecoder

    /// 打开文件。数据损坏或编码不受支持时抛异常。
    protected init(path: String) {
        this._decoder = DrLibsDecoder(DrLibsFormat.Flac, path)
    }

    public func sampleRate(): Int64 {
        _decoder.sampleRate()
    }

    public func channels(): Int64 {
        _decoder.channels()
    }

    public func bitsPerSample(): Int64 {
        _decoder.bitsPerSample()
    }

    public func totalFrames(): Int64 {
        _decoder.totalFrames()
    }

    public func seekToFrame(index: Int64): Bool {
        _decoder.seekToFrame(index)
    }

    public func readF32Into(bytes: Array<UInt8>, frames: Int64): Int64 {
        _decoder.readF32Into(bytes, frames)
    }

    public func close(): Unit {
        _decoder.close()
    }

    public func isClosed(): Bool {
        _decoder.isClosed()
    }
}
