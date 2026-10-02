package audio4cj.format

import audio4cj.core.*
import audio4cj.meta.*
import audio4cj.drlibs.*

/* ============================================================================
 * FLAC demuxer —— 压缩数据经 dr_libs FFI 解码（开发文档 §10 M4）
 *
 * 与 WAV 实现的关键差异：
 *   WAV 是**未压缩**容器，其「解码」本质是位深转换，故 M2 走纯仓颉实现；
 *   FLAC 是**压缩**格式（含 LPC 预测与残差解码等，属浮点 DSP 范畴），
 *   按开发文档 §2.1 的「数据解析自研、浮点 DSP 外包」分工，走 dr_libs FFI。
 *
 * 分工（与 WAV 保持一致）：
 *   本类持有 dr_libs 句柄，负责打开、参数、seek 与分块读取；
 *   `FlacPcmDecoder` 只把已解码的 f32 字节重解释为 AudioBuffer。
 *   这样 reader 与 decoder 不共享句柄，避免所有权纠缠。
 *
 * 分块策略：每次最多读取 FLAC_CHUNK_FRAMES 帧（f32 交错下约
 *   4 * 声道数 * 16384 字节，立体声约 128 KiB），内存占用与音频总时长无关。
 * ========================================================================== */

/// 单次读取的最大帧数（与 WAV 的 64 KiB 量级分块策略对齐）。
private let FLAC_CHUNK_FRAMES: Int64 = 16384

/// FLAC 容器的 FormatReader 实现。
protected class FlacFormatReader <: FormatReader {
    private let _path: String
    private let _decoder: DrLibsDecoder

    private let _sampleRate: Int64
    private let _channels: Int64
    private let _bitsPerSample: Int64

    /// 总帧数；**-1 表示不可知**（开发文档 §4.2 的既有约定）。
    private let _totalFrames: Int64

    /// 已交付的帧数（用于计算时间戳）。
    private var _framesConsumed: Int64 = 0

    private var _closed: Bool = false

    /// 打开文件并读取音频参数。数据损坏或编码不受支持时抛异常。
    public init(path: String) {
        this._path = path
        this._decoder = DrLibsDecoder(DrLibsFormat.Flac, path)

        this._sampleRate = _decoder.sampleRate()
        this._channels = _decoder.channels()
        this._bitsPerSample = _decoder.bitsPerSample()

        // C 侧适配层把「总帧数不可知」统一归零，此处翻译回项目约定的 -1
        let total = _decoder.totalFrames()
        this._totalFrames = if (total > 0) {
            total
        } else {
            -1
        }

        if (_sampleRate <= 0 || _channels <= 0 || _bitsPerSample <= 0) {
            // 必须**先释放已打开的 dr_libs 句柄再抛异常**：
            // 构造失败后该对象永远不会被使用者持有，也就没人能再调用 close()，
            // 句柄持有的 FILE* 会随之泄漏。实测表现为：open() 抛异常之后，
            // 该文件无法被删除或移动（Windows 报「文件被其它进程占用」）。
            _decoder.close()
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

        let frames = _decoder.readF32Into(buf, FLAC_CHUNK_FRAMES)
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
    /// SEEKTABLE + 二分」，但 dr_libs 内部已实现该策略并额外处理了无
    /// SEEKTABLE 时的回退，自行重写既冗余又更易出错。因此此处直接委托
    /// dr_libs 的原生 seek —— 其成功返回即表示**精确定位到目标帧**，
    /// 故实际落点等于目标帧。
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

        if (!_decoder.seekToFrame(targetFrame)) {
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

    /// 释放资源（幂等）：关闭 dr_libs 句柄。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _decoder.close()
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
