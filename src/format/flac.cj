package audio4cj.format

import audio4cj.core.*
import audio4cj.meta.*

/* ============================================================================
 * FLAC demuxer
 *
 * 与 WAV 实现的关键差异：
 *   WAV 是**未压缩**容器，其「解码」本质是位深转换，故 M2 走纯仓颉实现；
 *   FLAC 是**压缩**格式，需真正解码，故经 FlacDecodeKernel 抽象解耦。
 *
 * 【两个容器的内核现状（本节是"当前用的是哪个实现"的唯一说明处）】
 *   原生 FLAC  → PureFlacKernel（纯仓颉，见 flac_bitstream.cj）← **生产路径**
 *   Ogg 封装   → DrLibsFlacKernel（dr_libs FFI）          ← 暂留，待纯仓颉 Ogg 读取器
 *   也就是说：**原生 FLAC 已零 C 依赖**；Ogg-FLAC 还没有，它是本次纯仓颉化
 *   尚未做完的那一部分（见 docs/codec-expansion-assessment.md 的盘点）。
 *   纯仓颉内核只认以 `fLaC` 开头的原生流，喂 Ogg 会响亮报错而不是静默出错。
 *
 * 分工（与 WAV 保持一致）：
 *   本类持有解码内核，负责打开、参数、seek 与分块读取；
 *   `FlacPcmDecoder` 只把已解码的 f32 字节重解释为 AudioBuffer。
 *   这样 reader 与 decoder 不共享状态，避免所有权纠缠。
 *
 * 【本类不认识 dr_libs】
 *   自 M7 起本类只依赖 FlacDecodeKernel 接口，换内核不需改这里一行 ——
 *   这正是抽接口的目的：本次把原生 FLAC 换成纯仓颉内核，确实只动了 init 中
 *   的一处选择，其余方法一行未改。内核的选取发生在 init 中，
 *   依据是调用方传入的容器信息（不在这里重新识别容器）。
 *
 * 分块策略：每次最多读取 FLAC_CHUNK_FRAMES 帧（f32 交错下约
 *   4 * 声道数 * 16384 字节，立体声约 128 KiB），内存占用与音频总时长无关。
 * ========================================================================== */

/// 单次读取的最大帧数（与 WAV 的 64 KiB 量级分块策略对齐）。
private let FLAC_CHUNK_FRAMES: Int64 = 16384

/// FLAC 容器的 FormatReader 实现。
protected class FlacFormatReader <: FormatReader {
    private let _path: String
    private let _kernel: FlacDecodeKernel

    private let _sampleRate: Int64
    private let _channels: Int64
    private let _bitsPerSample: Int64

    /// 总帧数；**-1 表示不可知**（开发文档 §4.2 的既有约定）。
    private let _totalFrames: Int64

    /// 已交付的帧数（用于计算时间戳）。
    private var _framesConsumed: Int64 = 0

    private var _closed: Bool = false

    /// 打开文件并读取音频参数。数据损坏或编码不受支持时抛异常。
    ///
    /// `oggWrapped` 决定用哪个内核：
    ///   false（原生 FLAC）→ PureFlacKernel，纯仓颉，零 C 依赖；
    ///   true （Ogg 封装）→ DrLibsFlacKernel，暂留。
    ///
    /// 【为什么由调用方传，而不在这里嗅探文件头】"这是什么容器"已经由 facade
    /// 的探测器算过一次；再在读取器里识别一次就是第二份判断依据，两者一旦
    /// 出现分歧，会出现"按 A 判定的容器、按 B 选的内核"这种最难查的错。
    /// 调用方本来就在两个 case 分支里，把已知事实传下来成本为零。
    public init(path: String, oggWrapped: Bool) {
        this._path = path

        // 显式标注类型：两个分支是**不同的类**，若让编译器自行推导
        // if 表达式的类型，得不到 FlacDecodeKernel 这个共同父类型。
        let kernel: FlacDecodeKernel = if (oggWrapped) {
            DrLibsFlacKernel(path)
        } else {
            PureFlacKernel(path)
        }
        this._kernel = kernel

        this._sampleRate = _kernel.sampleRate()
        this._channels = _kernel.channels()
        this._bitsPerSample = _kernel.bitsPerSample()

        // 内核把「总帧数不可知」统一归零，此处翻译回项目约定的 -1
        let total = _kernel.totalFrames()
        this._totalFrames = if (total > 0) {
            total
        } else {
            -1
        }

        if (_sampleRate <= 0 || _channels <= 0 || _bitsPerSample <= 0) {
            // 必须**先释放已打开的内核句柄再抛异常**：
            // 构造失败后该对象永远不会被使用者持有，也就没人能再调用 close()，
            // 句柄持有的 FILE* 会随之泄漏。实测表现为：open() 抛异常之后，
            // 该文件无法被删除或移动（Windows 报「文件被其它进程占用」）。
            _kernel.close()
            throw CorruptedFileException(
                "FLAC 参数非法（rate=${_sampleRate}, ch=${_channels}, bits=${_bitsPerSample}）")
        }
    }

    // ------------------------------------------------------------------
    // FormatReader 实现
    // ------------------------------------------------------------------

    public func tracks(): Array<Track> {
        [Track(0, "flac", _sampleRate, _channels)]
    }

    /// 读取下一个数据包。None **严格且仅表示**数据流正常结束。
    ///
    /// 注意：`Packet.data` 承载的是**已解码的 f32 交错 PCM 字节**
    /// （而非压缩数据）—— 与 WAV 的 Packet 承载未压缩 PCM 的语义一致。
    public func nextPacket(): ?Packet {
        checkOpen()

        let capacity = FLAC_CHUNK_FRAMES * _channels * 4 // f32 = 4 字节
        let buf = Array<UInt8>(capacity, repeat: 0)

        let frames = _kernel.readF32Into(buf, FLAC_CHUNK_FRAMES)
        if (frames <= 0) {
            return None // 流结束，不是错误
        }

        let samples = frames * _channels
        let payload = if (samples * 4 >= capacity) {
            buf
        } else {
            buf[0..samples * 4]
        }

        let startFrame = _framesConsumed
        _framesConsumed += frames

        let timestampMs = startFrame * 1000 / _sampleRate
        let durationMs = frames * 1000 / _sampleRate

        Packet(0, payload, timestampMs, durationMs)
    }

    /// 按毫秒寻址，返回**实际落点毫秒**。
    ///
    /// 实现说明（开发文档 §10 M4 的一处**有意偏离**）：文档原定「FLAC 用
    /// SEEKTABLE + 二分」，但当时代码走 dr_libs，其内部已实现该策略并额外处理了
    /// 无 SEEKTABLE 时的回退，自行重写既冗余又更易出错，故定位一律委托给内核。
    ///
    /// 该约定在换内核后依然成立，且**偏离本身已经消失**：纯仓颉内核现已自行实现
    /// 「SEEKTABLE 二分定位 + 无表时向前解码」的回退（见 flac_bitstream.cj 的
    /// seekToFrame 与 seekPointAtOrBefore），与文档原定策略一致。
    /// 本类仍不关心策略细节 —— 成功返回即表示**精确定位到目标帧**。
    public func seekTo(timestampMs: Int64): Int64 {
        checkOpen()

        var targetFrame = timestampMs * _sampleRate / 1000
        if (targetFrame < 0) {
            targetFrame = 0
        }
        if (_totalFrames > 0 && targetFrame >= _totalFrames) {
            targetFrame = _totalFrames - 1
        }
        if (targetFrame < 0) {
            targetFrame = 0
        }

        if (!_kernel.seekToFrame(targetFrame)) {
            throw SeekNotSupportedException("FLAC 定位失败（目标帧 ${targetFrame}）")
        }

        _framesConsumed = targetFrame
        _framesConsumed * 1000 / _sampleRate
    }

    /// 读取标签：委托 meta 层的文件级读取（与 `AudioFile.readTags` 共用同一实现）。
    ///
    /// 无标签时返回**空 Tag**（各字段为 None），绝不返回 None。
    public func metadata(): Tag {
        checkOpen()
        readFlacTagsFromFile(_path)
    }

    public func info(): AudioInfo {
        checkOpen()

        let durationMs = if (_totalFrames > 0 && _sampleRate > 0) {
            _totalFrames * 1000 / _sampleRate
        } else {
            0
        }

        AudioInfo(_sampleRate, _channels, _bitsPerSample, durationMs, _totalFrames)
    }

    // ------------------------------------------------------------------
    // Resource
    // ------------------------------------------------------------------

    public func isClosed(): Bool {
        _closed
    }

    /// 释放资源（幂等）：关闭解码内核。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _kernel.close()
        }
    }

    // ------------------------------------------------------------------
    // 供解码器构造参数用
    // ------------------------------------------------------------------

    public func sampleRate(): Int64 {
        _sampleRate
    }

    public func channels(): Int64 {
        _channels
    }

    public func bitsPerSample(): Int64 {
        _bitsPerSample
    }

    public func totalFrames(): Int64 {
        _totalFrames
    }

    private func checkOpen(): Unit {
        if (_closed) {
            throw ClosedResourceException("对已关闭的 FLAC reader 执行操作（${_path}）")
        }
    }
}
