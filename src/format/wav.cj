package audio4cj.format

import std.fs.*
import std.io.* // SeekPosition 定义于 std.io（Seekable 接口所在包）
import audio4cj.core.*
import audio4cj.meta.Tag
import audio4cj.meta.parseWavInfo
import audio4cj.pcm.*

/* ============================================================================
 * WAV demuxer —— 纯仓颉实现（开发文档 §2.1「数据解析自研」）
 *
 * 为什么 WAV 走纯仓颉而非 FFI：
 *   WAV 是**未压缩**容器，其「解码」本质是位深转换（属数据解析），
 *   不含浮点 DSP。按 §2.1 的分工，数据解析自研、浮点 DSP 外包，
 *   因此 WAV 用原生实现；dr_libs 的 WAV 通路在本阶段作为**交叉验证基准**
 *   （见 test 目录的对照测试），并为 M4 的压缩格式铺路。
 *
 * RIFF 结构：
 *   "RIFF" <size:4LE> "WAVE"
 *     "fmt " <size:4LE> <wFormatTag:2LE> <nChannels:2LE> <nSamplesPerSec:4LE>
 *                       <nAvgBytesPerSec:4LE> <nBlockAlign:2LE> <wBitsPerSample:2LE>
 *                       [<cbSize:2LE> <extension...>]
 *     "data" <size:4LE> <PCM bytes>
 *     [其他 chunk：LIST/INFO、fact、cue 等]
 *
 * 注意：chunk 长度为奇数时，其后有 1 字节填充（对齐到偶数字节）。
 *
 * M3 补充（标签）：`LIST/INFO` 标签块按规范**可以出现在 data chunk 之后**，
 *   因此 chunk 遍历不能再"遇到 data 就停" —— 改为"集齐 fmt + data + INFO
 *   三者才提前退出"，并以迭代上限兜住畸形文件。
 * ========================================================================== */

/// RIFF chunk 遍历的迭代上限（防畸形文件造成长循环）。
private let MAX_RIFF_CHUNKS: Int64 = 4096

/// LIST/INFO 块的最大可接受字节数（1 MB）。超出即视为畸形，不予解析。
private let MAX_INFO_CHUNK_SIZE: Int64 = 1024 * 1024

/// WAV 容器的 FormatReader 实现。
protected class WavFormatReader <: FormatReader {
    private let _path: String
    private var _file: File

    /// wFormatTag：1 = PCM 整型，3 = IEEE float，0xFFFE = extensible
    private var _audioFormat: Int64 = 0
    private var _channels: Int64 = 0
    private var _sampleRate: Int64 = 0
    private var _bitsPerSample: Int64 = 0

    /// data chunk 的起始文件偏移与字节长度
    private var _dataOffset: Int64 = 0
    private var _dataSize: Int64 = 0

    /// 已消费的 data 字节数（游标）
    private var _bytesConsumed: Int64 = 0

    /// LIST/INFO 标签块的块体（含开头的 "INFO" 标识）；
    /// None 表示文件不含 INFO 标签（此时 metadata() 返回空 Tag）
    private var _infoBody: ?Array<UInt8> = None

    private var _closed: Bool = false

    /// 打开并解析 WAV 头。文件不存在或结构非法时抛出异常。
    public init(path: String) {
        this._path = path
        this._file = File(path, Read)
        parseHeader()
    }

    // ------------------------------------------------------------------
    // FormatReader 实现
    // ------------------------------------------------------------------

    public func tracks(): Array<Track> {
        [Track(0, "pcm", _sampleRate, _channels)]
    }

    /// 读取下一个数据包。None **严格且仅表示**数据流正常结束。
    public func nextPacket(): ?Packet {
        checkOpen()

        if (_bytesConsumed >= _dataSize) {
            return None
        }

        let frameSize = frameSizeBytes()
        if (frameSize <= 0) {
            throw CorruptedFileException("WAV 帧长非法（channels=${_channels}, bits=${_bitsPerSample}）")
        }

        // 每包上限 64 KiB，并向下对齐到整帧边界
        let wanted = min(_dataSize - _bytesConsumed, 65536)
        let aligned = (wanted / frameSize) * frameSize
        if (aligned <= 0) {
            // 剩余数据不足一帧：视为流结束（尾部残缺字节忽略）
            return None
        }

        let buf = Array<UInt8>(aligned, repeat: 0)
        _file.seek(SeekPosition.Begin(_dataOffset + _bytesConsumed))
        let got = _file.read(buf)
        if (got <= 0) {
            return None // 意外 EOF：按流结束处理
        }

        let startFrame = _bytesConsumed / frameSize
        _bytesConsumed += got
        let frames = got / frameSize
        let timestampMs = startFrame * 1000 / _sampleRate
        let durationMs = frames * 1000 / _sampleRate

        Packet(0, buf, timestampMs, durationMs)
    }

    /// 按毫秒寻址。WAV 为线性布局，可直接定位；返回**实际落点毫秒**。
    public func seekTo(timestampMs: Int64): Int64 {
        checkOpen()

        let frameSize = frameSizeBytes()
        if (frameSize <= 0) {
            throw CorruptedFileException("WAV 帧长非法，无法寻址")
        }

        var byteOffset = timestampMs * _sampleRate / 1000 * frameSize
        if (byteOffset > _dataSize) {
            byteOffset = _dataSize
        }
        if (byteOffset < 0) {
            byteOffset = 0
        }
        // 对齐到帧边界
        byteOffset = (byteOffset / frameSize) * frameSize
        _bytesConsumed = byteOffset

        let actualFrame = byteOffset / frameSize
        actualFrame * 1000 / _sampleRate
    }

    /// 读取标签：解析 LIST/INFO 子块（M3 落地，取代 M2 的空 Tag 占位）。
    ///
    /// 文件不含 INFO 标签时返回**空 Tag**（各字段为 None），而不是 None —— 见 §4.1 铁律 1。
    public func metadata(): Tag {
        checkOpen()
        match (_infoBody) {
            case Some(body) => parseWavInfo(body)
            case None => Tag()
        }
    }

    /// 读取并记录 LIST chunk 的块体（仅接受类型标识为 "INFO" 的 LIST）。
    ///
    /// RIFF 中 LIST 块可承载多种内容（"INFO" 标签、"adtl" 关联数据等），
    /// 此处只认 "INFO"。块体大小超限（> MAX_INFO_CHUNK_SIZE）时直接忽略。
    private func readInfoChunk(bodyOffset: Int64, size: Int64): Unit {
        if (size < 4 || size > MAX_INFO_CHUNK_SIZE) {
            return
        }

        let body = Array<UInt8>(size, repeat: 0)
        _file.seek(SeekPosition.Begin(bodyOffset))
        let got = _file.read(body)
        if (got < 4) {
            return
        }
        if (!matchTag(body, 0, "INFO")) {
            return // 非 INFO 类型的 LIST（如 "adtl"），跳过
        }
        _infoBody = body
    }

    public func info(): AudioInfo {
        checkOpen()

        let frameSize = frameSizeBytes()
        let totalFrames = if (frameSize > 0) {
            _dataSize / frameSize
        } else {
            0
        }
        let durationMs = if (_sampleRate > 0) {
            totalFrames * 1000 / _sampleRate
        } else {
            0
        }

        AudioInfo(_sampleRate, _channels, declaredBitDepth(), durationMs, totalFrames)
    }

    // ------------------------------------------------------------------
    // Resource
    // ------------------------------------------------------------------

    public func isClosed(): Bool {
        _closed
    }

    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _file.close()
        }
    }

    // ------------------------------------------------------------------
    // 供解码器读取的元信息
    // ------------------------------------------------------------------

    /// wFormatTag（1 = PCM 整型，3 = IEEE float）。
    public func audioFormat(): Int64 {
        _audioFormat
    }

    /// 是否 IEEE 浮点格式。
    public func isFloatFormat(): Bool {
        _audioFormat == 3
    }

    public func channels(): Int64 {
        _channels
    }

    public func sampleRate(): Int64 {
        _sampleRate
    }

    public func bitsPerSample(): Int64 {
        _bitsPerSample
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    /// 单帧字节数。
    private func frameSizeBytes(): Int64 {
        _channels * bytesPerSample(_bitsPerSample)
    }

    /// 对外声明的位深：32-bit float 对外报告为 32。
    private func declaredBitDepth(): Int64 {
        _bitsPerSample
    }

    private func checkOpen(): Unit {
        if (_closed) {
            throw ClosedResourceException("对已关闭的 WAV reader 执行操作（${_path}）")
        }
    }

    /// 解析 RIFF 头与 fmt / data chunk。
    private func parseHeader(): Unit {
        // ---- 1. RIFF 头（12 字节）----
        let riff = Array<UInt8>(12, repeat: 0)
        _file.seek(SeekPosition.Begin(0))
        if (_file.read(riff) < 12) {
            throw CorruptedFileException("文件过短，不是合法 WAV（${_path}）")
        }
        if (!matchTag(riff, 0, "RIFF") || !matchTag(riff, 8, "WAVE")) {
            throw CorruptedFileException("缺少 RIFF/WAVE 标识（${_path}）")
        }

        // ---- 2. 遍历 chunk ----
        //
        // M3 起不再"遇到 data 就停"：LIST/INFO 按规范允许位于 data 之后，
        // 必须继续向后扫描才能拿到标签。扫描过程只 seek 并读 8 字节 chunk 头，
        // 不触碰 data 内容本身，因此对大文件也只有极小开销。
        var offset: Int64 = 12
        var fmtSeen = false
        var dataSeen = false
        var guard: Int64 = 0

        while (guard < MAX_RIFF_CHUNKS) {
            guard += 1

            let ch = Array<UInt8>(8, repeat: 0)
            _file.seek(SeekPosition.Begin(offset))
            if (_file.read(ch) < 8) {
                break
            }
            let size = Int64(readUInt32LE(ch, 4))
            if (size < 0) {
                throw CorruptedFileException("chunk 长度非法（${_path}）")
            }
            let bodyOffset = offset + 8

            if (matchTag(ch, 0, "fmt ")) {
                if (size < 16 || size > 4096) {
                    throw CorruptedFileException("fmt chunk 长度异常：${size}")
                }
                let fmt = Array<UInt8>(size, repeat: 0)
                _file.seek(SeekPosition.Begin(bodyOffset))
                let got = _file.read(fmt)
                if (got < 16) {
                    throw CorruptedFileException("fmt chunk 内容不完整")
                }
                parseFmt(fmt)
                fmtSeen = true
            } else if (matchTag(ch, 0, "data")) {
                if (!fmtSeen) {
                    throw CorruptedFileException("data chunk 出现在 fmt 之前，结构非法")
                }
                if (!dataSeen) {
                    _dataOffset = bodyOffset
                    _dataSize = size
                    dataSeen = true
                }
            } else if (matchTag(ch, 0, "LIST")) {
                if (_infoBody.isNone()) {
                    readInfoChunk(bodyOffset, size)
                }
            }
            // 其余 chunk（fact/cue/bext 等）无需解析，直接跳过

            // 三类关键 chunk 都拿到后即可停止扫描
            if (fmtSeen && dataSeen && _infoBody.isSome()) {
                break
            }

            // 奇数长度后有 1 字节填充
            offset = bodyOffset + size + (size % 2)
        }

        if (!fmtSeen) {
            throw CorruptedFileException("缺少 fmt chunk（${_path}）")
        }
        if (!dataSeen) {
            throw CorruptedFileException("缺少 data chunk（${_path}）")
        }
        if (_channels <= 0 || _sampleRate <= 0 || _bitsPerSample <= 0) {
            throw CorruptedFileException(
                "WAV 参数非法（channels=${_channels}, rate=${_sampleRate}, bits=${_bitsPerSample}）")
        }
        if (!isSupportedPcmFormat(_bitsPerSample, isFloatFormat())) {
            throw FormatNotSupportedException(
                "暂不支持的 WAV 编码：formatTag=${_audioFormat}, bits=${_bitsPerSample}" +
                    "（当前支持 8/16/24/32 位整型 PCM）")
        }
    }

    /// 解析 fmt chunk 内容。
    private func parseFmt(fmt: Array<UInt8>): Unit {
        _audioFormat = Int64(readUInt16LE(fmt, 0))
        _channels = Int64(readUInt16LE(fmt, 2))
        _sampleRate = Int64(readUInt32LE(fmt, 4))
        _bitsPerSample = Int64(readUInt16LE(fmt, 14))

        // WAVE_FORMAT_EXTENSIBLE(0xFFFE)：真实格式在 SubFormat GUID 首 2 字节
        // 布局：offset 16 = cbSize(2)，18 = wValidBitsPerSample(2)，
        //       20 = dwChannelMask(4)，24 = SubFormat GUID(16)
        if (_audioFormat == 0xFFFE && fmt.size >= 40) {
            let subFormat = Int64(readUInt16LE(fmt, 24))
            _audioFormat = subFormat
        }
    }

    /// 比较字节数组中的 ASCII 标签。
    private func matchTag(data: Array<UInt8>, offset: Int64, tag: String): Bool {
        let t = tag.toArray()
        if (offset < 0 || offset + t.size > data.size) {
            return false
        }
        for (i in 0..t.size) {
            if (data[offset + i] != t[i]) {
                return false
            }
        }
        true
    }
}
