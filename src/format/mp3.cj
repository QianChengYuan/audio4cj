package audio4cj.format

import audio4cj.core.*
import audio4cj.drlibs.*
import audio4cj.meta.*

/* ============================================================================
 * MP3 demuxer —— 压缩数据经 dr_libs FFI 解码（开发文档 §10 M4）
 *
 * 【关于 Xing / VBRI 头与帧同步】
 *   开发文档的 M4 条目列出了「MP3 demuxer（帧同步 + Xing/VBRI 头 + VBR
 *   时长计算）」。但核实 dr_mp3 后确认：这些工作**dr_mp3 内部已经完成** ——
 *   它在初始化时定位第一个 MPEG 帧、跳过 ID3v2 与各类 VBR 标签、解析
 *   Xing/Info/VBRI 头（若存在）并据此得出 totalPCMFrameCount；对没有 VBR 头
 *   的流则依据比特率推算。因此本层**不重复实现**帧同步与头解析：重复实现
 *   既冗余，又容易与 dr_mp3 的判定产生分歧（例如两者对首个有效帧的认定不同）。
 *
 *   未核实项：无 Xing 头的纯 VBR 流，dr_mp3 是否可能返回「总帧数未知」。
 *   若如此，本项目会如实上报 totalFrames = -1（不可知），而不是猜一个值 ——
 *   这与 AudioInfo 的既有约定一致。
 *
 * 【位深语义（易误解，重要）】
 *   MP3 是有损格式，**没有源位深概念**；解码输出恒为 f32。
 *   因此 bitDepth 报告为 **32**，含义是「32 位浮点」——与 AudioInfo 中
 *   「32 代表 float32」的约定一致。调用方**不应**把它理解为 32 位整数 PCM，
 *   也不应据此推断原始编码位深。
 * ========================================================================== */

/// 单次读取的最大帧数（与 WAV / FLAC 的分块策略对齐）。
private let MP3_CHUNK_FRAMES: Int64 = 16384

/// MP3 容器的 FormatReader 实现。
protected class Mp3FormatReader <: FormatReader {
    private let _path: String
    private let _decoder: DrLibsDecoder

    private let _sampleRate: Int64
    private let _channels: Int64

    /// 恒为 32，含义为「float32」（MP3 无源位深）。
    private let _bitsPerSample: Int64

    /// 总帧数；**-1 表示不可知**。
    private let _totalFrames: Int64

    private var _framesConsumed: Int64 = 0
    private var _closed: Bool = false

    /// 打开文件并读取音频参数。数据损坏或编码不受支持时抛异常。
    public init(path: String) {
        this._path = path
        this._decoder = DrLibsDecoder(DrLibsFormat.Mp3, path)

        this._sampleRate = _decoder.sampleRate()
        this._channels = _decoder.channels()
        this._bitsPerSample = _decoder.bitsPerSample()

        // C 侧把「总帧数不可知」统一归零，此处翻译回项目约定的 -1
        let total = _decoder.totalFrames()
        this._totalFrames = if (total > 0) {
            total
        } else {
            -1
        }

        if (_sampleRate <= 0 || _channels <= 0) {
            // 必须**先释放已打开的 dr_libs 句柄再抛异常**：
            // 构造失败后该对象永远不会被使用者持有，也就没人能再调用 close()，
            // 句柄持有的 FILE* 会随之泄漏，导致该文件之后无法删除或移动。
            // （FLAC 侧存在同样的问题，两处修复原因一致。）
            _decoder.close()
            throw CorruptedFileException("MP3 参数非法（rate=${_sampleRate}, ch=${_channels}）")
        }
    }

    // ------------------------------------------------------------------
    // FormatReader 实现
    // ------------------------------------------------------------------

    public func tracks(): Array<Track> {
        [Track(0, "mp3", _sampleRate, _channels)]
    }

    /// 读取下一个数据包。None **严格且仅表示**数据流正常结束。
    ///
    /// `Packet.data` 承载的是**已解码的 f32 交错 PCM 字节**（与 FLAC 实现一致）。
    public func nextPacket(): ?Packet {
        checkOpen()

        let capacity = MP3_CHUNK_FRAMES * _channels * 4 // f32 = 4 字节
        let buf = Array<UInt8>(capacity, repeat: 0)

        let frames = _decoder.readF32Into(buf, MP3_CHUNK_FRAMES)
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
    /// 与 FLAC 同策略：直接委托 dr_mp3 的原生 seek（其内部已处理 CBR 直接
    /// 定位与 VBR 的索引/扫描回退），成功返回即表示精确定位到目标帧，
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
            throw SeekNotSupportedException("MP3 定位失败（目标帧 ${targetFrame}）")
        }

        _framesConsumed = targetFrame
        _framesConsumed * 1000 / _sampleRate
    }

    /// 读取标签：ID3v2（文件头）+ ID3v1（文件尾），前者优先、后者逐字段回填。
    ///
    /// 与 `AudioFile.readTags` 共用 meta 层的文件级读取实现，避免逻辑分叉。
    public func metadata(): Tag {
        checkOpen()
        readMp3TagsFromFile(_path)
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
            throw ClosedResourceException("对已关闭的 MP3 reader 执行操作（${_path}）")
        }
    }
}
