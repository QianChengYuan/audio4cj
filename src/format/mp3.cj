package audio4cj.format

import audio4cj.core.*
import audio4cj.meta.*
import audio4cj.pcm.f32ToBytes
import std.fs.*

/* ============================================================================
 * MP3 demuxer（FormatReader 实现）
 *
 * 【与 WAV / FLAC 实现的关键差异】
 *   WAV 未压缩、FLAC 有块结构，两者的"读取"都能靠文件内偏移推进；
 *   MP3 的帧数据是**变长 + 带跨帧位池（bit reservoir）**的：第 N 帧的
 *   主数据可能有一部分落在第 N-1 帧的字节里（main_data_begin 指回多远）。
 *   因此**不能凭字节偏移随意跳帧** —— 位池状态是解码推进出来的。
 *   本读取器据此采用两条策略：
 *     · 顺序读取：窗口前向回填，解码器内部维护位池（Mp3Dec.reservBuf）；
 *     · 定位（seek）：向前靠"解码并丢弃"推进，向后靠重开文件 + 复位解码器。
 *   精度代价如实记录：无索引的 MP3 定位最坏是 O(n) 解码，返回的是**实际落点**。
 *
 * 【分块策略】每块累积到约 MP3_CHUNK_FRAMES 帧后交付（约 0.18 秒 @44.1kHz）。
 *   Packet.data 承载的是**已解码的 f32 交错 PCM 字节**（与 FLAC 一致，
 *   而不是压缩数据）—— 因此 Mp3PcmDecoder 只做视角转换。
 *
 * 【容器解析：两处必须共存】
 *   本文件负责**文件级**的字节推进与探测（首帧锚点、Xing/VBRI、ID3 跳过交给
 *   mp3_decode.cj 的帧同步扫描）；真正的帧解码在 mp3_decode.cj。
 *   标签读取复用 meta 层的 readMp3TagsFromFile —— 与 AudioFile.readTags 同一实现。
 * ========================================================================== */

/// 每块目标帧数。取 1152 的整数倍，使 MPEG1 帧恰好整数块。
private let MP3_CHUNK_FRAMES: Int64 = 1152 * 7

/// 读取窗口（字节）。必须远大于单帧最大长度（含自由格式上限 2304），
/// 这样"窗口未满即为文件末尾"这条判据成立，帧不会在窗口边界被截断。
private let MP3_WINDOW_BYTES: Int64 = 65536

/// 无 Xing/VBRI 时的总帧数估算（按首帧比特率；CBR 准确，VBR 仅为近似）。
///
/// 抽成顶层函数而不是实例方法：它在 init 里、部分字段尚未赋值时被调用，
/// 只依赖入参可避免"调用未完成初始化的实例"这类隐患。
private func estimateTotalFrames(fileSize: Int64, anchor: Mp3Anchor): Int64 {
    let audioBytes = fileSize - anchor.frameOffset
    if (anchor.frameBytes <= 0 || audioBytes <= 0) {
        return -1
    }
    (audioBytes / anchor.frameBytes) * anchor.samplesPerFrame
}

/// 把文件剩余数据尽量读满窗口，返回(新的有效长度, 是否到达流末尾)。
///
/// 【为什么是顶层函数而不是实例方法】仓颉规定：**成员变量全部初始化之前
/// 不允许调用实例方法**。init 里就要预读首帧以解析锚点，因此这项操作
/// 只能以"只依赖入参"的形式存在。
///
/// 注意 `File.read` 只能从数组**起始处**写入，故分次读取需经临时缓冲拼接。
private func mp3FillWindow(file: File, buf: Array<UInt8>, len: Int64): (Int64, Bool) {
    var n = len
    var eof = false
    while (n < buf.size && !eof) {
        let want = buf.size - n
        let scratch = Array<UInt8>(want, repeat: 0)
        let r = file.read(scratch)
        if (r <= 0) {
            eof = true
            break
        }
        var i: Int64 = 0
        while (i < r) {
            buf[n + i] = scratch[i]
            i += 1
        }
        n += r
    }
    (n, eof)
}

/// MP3 容器的 FormatReader 实现。
protected class Mp3FormatReader <: FormatReader {
    private let _path: String
    private var _file: File
    private let _dec: Mp3Dec

    private let _sampleRate: Int64
    private let _channels: Int64

    /// 总帧数；**-1 表示不可知**（无 Xing/VBRI 且无法估算）。
    private let _totalFrames: Int64

    /// 前向回填的读取窗口。
    private var _buf: Array<UInt8>
    private var _bufLen: Int64 = 0
    private var _eof: Bool = false

    /// 单帧解码输出缓冲（复用，避免每帧分配）。
    private var _pcm: Array<Float32>

    /// 已交付的帧数（用于计算时间戳与定位落点）。
    private var _framesConsumed: Int64 = 0

    private var _closed: Bool = false

    /// 打开文件并解析首帧锚点。数据里没有合法帧、或不是 Layer III 时抛异常。
    protected init(path: String) {
        this._path = path
        this._file = File(path, Read)

        let buf = Array<UInt8>(MP3_WINDOW_BYTES, repeat: 0)
        let pcm = Array<Float32>(MP3_MAX_SAMPLES_PER_FRAME, repeat: 0.0)
        let dec = Mp3Dec()
        mp3DecInit(dec)

        // 预读首窗以解析锚点（此时仍不可调用实例方法，故走顶层函数）
        let (filled, eof) = mp3FillWindow(this._file, buf, 0)
        this._buf = buf
        this._pcm = pcm
        this._dec = dec
        this._bufLen = filled
        this._eof = eof

        let anchor = mp3ParseAnchor(this._buf, this._bufLen)
        if (anchor.isNone()) {
            // 构造失败必须**先关句柄再抛**（本项目既有教训：否则文件被占用无法删除）
            this._file.close()
            throw CorruptedFileException("MP3 数据中找不到合法帧：${path}")
        }
        let a = anchor.getOrThrow()
        if (a.layer != 3) {
            this._file.close()
            throw FormatNotSupportedException("MP3 解码仅支持 Layer III（检出 Layer ${a.layer}）：${path}")
        }

        this._sampleRate = a.sampleRate
        this._channels = a.channels
        var total = a.totalFrames
        if (total < 0) {
            total = estimateTotalFrames(this._file.length, a)
        }
        this._totalFrames = total
    }

    // ------------------------------------------------------------------
    // FormatReader 实现
    // ------------------------------------------------------------------

    public func tracks(): Array<Track> {
        [Track(0, "mp3", _sampleRate, _channels)]
    }

    /// 读取下一个数据包。None **严格且仅表示**数据流正常结束。
    ///
    /// 坏帧（同步失败、位池不足）由解码器跳过或抛异常，绝不用 None 表达。
    public func nextPacket(): ?Packet {
        checkOpen()

        let capacity = (MP3_CHUNK_FRAMES + 1152) * _channels
        let acc = Array<Float32>(capacity, repeat: 0.0)
        let startFrame = _framesConsumed
        var framesOut: Int64 = 0

        // 累积到目标帧数或数据结束。期间跳过的垃圾字节不计入输出。
        while (framesOut < MP3_CHUNK_FRAMES) {
            if (_bufLen == 0 && _eof) {
                break
            }
            let info = Mp3FrameInfo()
            let n = mp3DecodeFrame(_dec, _buf[0.._bufLen], _bufLen, _pcm, info)
            let consumed = info.frameBytes
            if (consumed <= 0) {
                break
            }
            if (n > 0) {
                let samples = n * _channels
                var i: Int64 = 0
                while (i < samples) {
                    acc[framesOut * _channels + i] = _pcm[i]
                    i += 1
                }
                framesOut += n
            }
            consume(consumed)
            refill()
        }

        if (framesOut == 0) {
            return None
        }

        _framesConsumed += framesOut
        let data = f32ToBytes(acc[0..framesOut * _channels])
        let timestampMs = startFrame * 1000 / _sampleRate
        let durationMs = framesOut * 1000 / _sampleRate
        Packet(0, data, timestampMs, durationMs)
    }

    /// 按毫秒寻址，返回**实际落点毫秒**。
    ///
    /// 实现说明（开发文档 §10 M4 的既有约定：seekTo 必须返回实际落点）：
    ///   · 向后（目标在当前之后）：解码并丢弃直到目标帧 —— 无索引的 MP3
    ///     只能如此，最坏 O(n)；好处是位池状态天然正确，落点**精确到帧**。
    ///   · 向前（目标在当前之前）：重开文件并复位解码器，再前向推进。
    ///     不能凭字节偏移直接跳：位池是解码推进出来的状态，跳过去会错。
    public func seekTo(timestampMs: Int64): Int64 {
        checkOpen()

        var target = timestampMs * _sampleRate / 1000
        if (target < 0) {
            target = 0
        }
        if (_totalFrames > 0 && target >= _totalFrames) {
            target = _totalFrames - 1
        }
        if (target < 0) {
            target = 0
        }

        if (target < _framesConsumed) {
            rewind()
        }

        let info = Mp3FrameInfo()
        while (_framesConsumed < target) {
            if (_bufLen == 0 && _eof) {
                break
            }
            let n = mp3DecodeFrame(_dec, _buf[0.._bufLen], _bufLen, _pcm, info)
            let consumed = info.frameBytes
            if (consumed <= 0) {
                break
            }
            if (n > 0) {
                _framesConsumed += n
            }
            consume(consumed)
            refill()
        }

        _framesConsumed * 1000 / _sampleRate
    }

    /// 读取标签：委托 meta 层的文件级读取（与 `AudioFile.readTags` 共用同一实现）。
    ///
    /// 无标签时返回**空 Tag**（各字段为 None），绝不返回 None。
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

        // bitDepth 恒为 32：有损格式不存在源位深，32 表示"输出为 float32"（见 AudioInfo 文档）
        AudioInfo(_sampleRate, _channels, 32, durationMs, _totalFrames)
    }

    // ------------------------------------------------------------------
    // Resource
    // ------------------------------------------------------------------

    public func isClosed(): Bool {
        _closed
    }

    /// 释放资源（幂等）：关闭文件句柄。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _file.close()
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

    public func totalFrames(): Int64 {
        _totalFrames
    }

    // ------------------------------------------------------------------
    // 内部：窗口与定位
    // ------------------------------------------------------------------

    /// 补齐窗口数据（已到流末尾时为空操作）。
    private func refill(): Unit {
        if (!_eof) {
            let (n, e) = mp3FillWindow(_file, _buf, _bufLen)
            _bufLen = n
            _eof = e
        }
    }

    /// 丢弃窗口头部 `n` 字节并前移剩余数据。
    private func consume(n: Int64): Unit {
        if (n >= _bufLen) {
            _bufLen = 0
            return
        }
        let left = _bufLen - n
        var i: Int64 = 0
        while (i < left) {
            _buf[i] = _buf[n + i]
            i += 1
        }
        _bufLen = left
    }

    /// 重开文件并把解码器与窗口复位到流起点（向后定位用）。
    private func rewind(): Unit {
        _file.close()
        _file = File(_path, Read)
        _bufLen = 0
        _eof = false
        // 必须用完整复位：位池、MDCT 重叠、QMF 状态都要清，否则新流会带上旧状态
        mp3DecReset(_dec)
        _framesConsumed = 0
        refill()
    }

    private func checkOpen(): Unit {
        if (_closed) {
            throw ClosedResourceException("对已关闭的 MP3 reader 执行操作（${_path}）")
        }
    }
}
