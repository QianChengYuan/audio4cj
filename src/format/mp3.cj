package audio4cj.format

import audio4cj.core.*
import audio4cj.meta.*
import audio4cj.pcm.f32ToBytes
import std.fs.*
import std.io.*
import std.time.*

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
/// 注意读取只能从数组**起始处**写入，故分次读取需经临时缓冲拼接。
private func mp3FillWindow(src: ByteSource, buf: Array<UInt8>, len: Int64): (Int64, Bool) {
    var n = len
    var eof = false
    while (n < buf.size && !eof) {
        // 直接把数据读进窗口尾部：`buf[n..]` 是**共享视图**（不是拷贝），
        // 因此既不需要临时数组、也不需要逐字节搬运。原先每读一次都要
        // 分配一块 `want` 大小（最大 64 KB）的临时数组再把内容逐字节拷进窗口，
        // 而这是**每帧**一次的量级 —— 实测流层占了墙钟近四成（见文档性能节）。
        let r = src.readSome(buf.slice(n, buf.size - n))
        if (r <= 0) {
            eof = true
            break
        }
        n += r
    }
    (n, eof)
}

/// MP3 容器的 FormatReader 实现。
protected class Mp3FormatReader <: FormatReader {
    private let _path: String
    private var _src: SeekableByteSource
    private let _dec: Mp3Dec

    private let _sampleRate: Int64
    private let _channels: Int64

    /// 总帧数；**-1 表示不可知**（无 Xing/VBRI 且无法估算）。
    /// 有 LAME 头时为裁剪后的有效帧数（init 末尾收紧，故为 var）。
    private var _totalFrames: Int64

    /// 总帧数是否为估算值（无 Xing/VBRI 时按首帧比特率估算）。
    private let _durationEstimated: Bool

    /// 首帧锚点元数据（v0.1.6 起经 info() 暴露）
    private let _bitrateKbps: Int64
    private let _isVbr: Bool
    private let _mpegVersion: String
    private let _layer: Int64
    private let _channelMode: String

    /// gapless（v0.1.6）：交付层裁剪参数。
    /// 解码器输出的流首 delay 帧、流尾 padding 帧是编码器填充（LAME 头声明），
    /// 不裁剪则连续播放有可闻咔哒/静音缝。二者未知（-1）时全部按 0 处理。
    /// 口径：`_skipFrames` = 输出流起点要丢弃的 PCM 帧；`_deliverFrames` =
    /// 应交付的有效 PCM 帧总数（-1 = 未知，不设上限）。
    private let _skipFrames: Int64
    private let _deliverFrames: Int64
    private var _deliveredFrames: Int64 = 0

    /// 前向回填的读取窗口。
    private var _buf: Array<UInt8>
    private var _bufLen: Int64 = 0
    private var _eof: Bool = false

    /// 音频数据起点（跳过 ID3v2 标签后的偏移；无标签为 0）。
    /// rewind 重开文件后必须先 seek 到这里，再回填窗口。
    private var _audioStart: Int64 = 0

    /// 单帧解码输出缓冲（复用，避免每帧分配）。
    private var _pcm: Array<Float32>

    /// 已交付的帧数（用于计算时间戳与定位落点）。
    private var _framesConsumed: Int64 = 0

    private var _closed: Bool = false

    /// 打开文件并解析首帧锚点。数据里没有合法帧、或不是 Layer III 时抛异常。
    protected init(path: String) {
        this(FileByteSource(path), path)
    }

    /// 从现成字节源打开（ByteSource 泛化：`openBytes` 走 MemoryByteSource 直通）。
    ///
    /// `path` 仅用于错误信息与关闭后的提示文案；内存源传一个可读的标识即可。
    protected init(source: SeekableByteSource, path: String) {
        this._path = path
        this._src = source

        // 若数据以 ID3v2 开头，跳过标签区再预读锚点窗：
        // 内嵌大封面（APIC）可把标签推到 64KB 预读窗之外——实测一张 80KB 的
        // ID3v2 使窗口内没有任何音频帧，帧同步报"找不到合法帧"（误报损坏）。
        let head = Array<UInt8>(10, repeat: 0)
        let hn = this._src.readSome(head)
        if (hn >= 10 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) { // "ID3"
            // 标签大小为 4×7bit syncsafe 整数；v2.4 可选 10 字节 footer（flags bit4）
            let sz = (Int64(head[6] & 0x7F) << 21) | (Int64(head[7] & 0x7F) << 14) | (Int64(head[8] & 0x7F) << 7) |
                Int64(head[9] & 0x7F)
            let footer = if ((head[5] & 0x10) != 0) {
                10
            } else {
                0
            }
            this._audioStart = 10 + sz + footer
            this._src.seekTo(this._audioStart)
        } else if (hn > 0) {
            this._src.seekTo(0)
        }

        let buf = Array<UInt8>(MP3_WINDOW_BYTES, repeat: 0)
        let pcm = Array<Float32>(MP3_MAX_SAMPLES_PER_FRAME, repeat: 0.0)
        let dec = Mp3Dec()
        mp3DecInit(dec)

        // 预读首窗以解析锚点（此时仍不可调用实例方法，故走顶层函数）
        let (filled, eof) = mp3FillWindow(this._src, buf, 0)
        this._buf = buf
        this._pcm = pcm
        this._dec = dec
        this._bufLen = filled
        this._eof = eof

        let anchor = mp3ParseAnchor(this._buf, this._bufLen)
        if (anchor.isNone()) {
            // 构造失败必须**先关源再抛**（本项目既有教训：否则文件被占用无法删除）
            this._src.close()
            throw CorruptedFileException("MP3 数据中找不到合法帧：${path}")
        }
        let a = anchor.getOrThrow()
        if (a.layer != 3) {
            this._src.close()
            throw FormatNotSupportedException("MP3 解码仅支持 Layer III（检出 Layer ${a.layer}）：${path}")
        }

        this._sampleRate = a.sampleRate
        this._channels = a.channels
        var total = a.totalFrames
        // 无 Xing/VBRI 锚点时按首帧比特率估算：CBR 准确，VBR 仅为近似，
        // 经 durationEstimated 如实告知调用方（v0.2.0）。
        var estimated = false
        if (total < 0) {
            total = estimateTotalFrames(this._src.length(), a)
            estimated = true
        }
        this._totalFrames = total
        this._durationEstimated = estimated
        this._bitrateKbps = a.bitrateKbps
        this._isVbr = a.isVbr
        this._mpegVersion = a.mpegVersion
        this._layer = a.layer
        this._channelMode = match (a.stereoMode) {
            case 0 => "stereo"
            case 1 => "joint stereo"
            case 2 => "dual channel"
            case _ => "mono"
        }
        // gapless 裁剪参数：仅在有 Xing/Info 总帧数与 LAME 头时可用
        this._skipFrames = if (a.lameDelay >= 0) {
            a.lameDelay
        } else {
            0
        }
        let rawTotal = a.totalFrames
        if (rawTotal > 0 && a.lameDelay >= 0 && a.lamePadding >= 0) {
            let effective = rawTotal - this._skipFrames - a.lamePadding
            this._deliverFrames = if (effective > 0) {
                effective
            } else {
                0
            }
            // 时长口径同步收紧（有效时长而非含填充的原始时长）
            this._totalFrames = this._deliverFrames
        } else {
            this._deliverFrames = -1
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
            let tFrame0 = MonoTime.now()
            let n = mp3DecodeFrame(_dec, _buf[0.._bufLen], _bufLen, _pcm, info)
            if (MP3_PHASE.enabled) {
                MP3_PHASE.frameNs += (MonoTime.now() - tFrame0).toNanoseconds()
            }
            let consumed = info.frameBytes
            if (consumed <= 0) {
                break
            }
            if (n > 0) {
                // 同上：整体搬运（逐样本循环每轮还要重算 `framesOut * _channels + i`）
                _pcm.copyTo(acc, 0, framesOut * _channels, n * _channels)
                framesOut += n
            }
            consume(consumed)
            refill()
        }

        let framesOutRaw = framesOut
        if (framesOutRaw == 0) {
            return None
        }

        // ---- gapless 裁剪（v0.1.6）----
        // 解码帧坐标 [startFrame, startFrame+framesOut) 与有效交付区间
        // [_skipFrames, _skipFrames+_deliverFrames) 取交集；交集为空且已越过
        // 区间末端即流结束。_framesConsumed 保持"原始解码帧"口径（seek 用）。
        var lo = startFrame
        var hi = startFrame + framesOut
        if (_deliverFrames >= 0) {
            let limitEnd = _skipFrames + _deliverFrames
            lo = if (startFrame > _skipFrames) {
                startFrame
            } else {
                _skipFrames
            }
            hi = if (hi < limitEnd) {
                hi
            } else {
                limitEnd
            }
        }
        let outFrames = hi - lo
        if (outFrames <= 0) {
            return None
        }
        if (lo != startFrame || hi != startFrame + framesOut) {
            // 把交集样本搬到 acc 头部（区间可能重叠，手动循环最稳）
            let src0 = lo - startFrame
            var k: Int64 = 0
            while (k < outFrames * _channels) {
                acc[k] = acc[src0 * _channels + k]
                k += 1
            }
        }
        framesOut = outFrames

        _framesConsumed = startFrame + framesOutRaw
        let data = f32ToBytes(acc[0..framesOut * _channels])
        // 时间戳用交付口径（减去流首被丢弃的 delay 帧）
        let deliveredStart = lo - _skipFrames
        let timestampMs = if (deliveredStart > 0) {
            deliveredStart * 1000 / _sampleRate
        } else {
            0
        }
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

        // 饱和换算（timestampMs 可能是 Int64.Max，直接相乘会抛标准库
        // OverflowException，而契约要求本库异常）
        var target = msToFramesSaturating(timestampMs, _sampleRate)
        if (_totalFrames > 0 && target >= _totalFrames) {
            target = _totalFrames - 1
        }
        if (target < 0) {
            target = 0
        }
        // 交付帧坐标 → 原始解码帧坐标（流首 delay 帧会被裁掉）
        var rawTarget = target + _skipFrames

        if (rawTarget < _framesConsumed) {
            rewind()
        }

        let info = Mp3FrameInfo()
        while (_framesConsumed < rawTarget) {
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

    /// 读取标签：从字节源读头/尾窗口，交 meta 层纯函数解析（v0.2.0 ByteSource 泛化）。
    ///
    /// 无标签时返回**空 Tag**（各字段为 None），绝不返回 None。
    ///
    /// 【为什么保存/恢复源位置】读取窗口会把源位置拨到别处；而解码窗口的
    /// 逻辑推进（refill）依赖源当前的顺序位置 —— 不恢复则下一次 refill
    /// 从标签区读数据，结果是静默的错位音频。
    public func metadata(): Tag {
        checkOpen()

        let savedPos = _src.pos()
        var head = Array<UInt8>()
        var tail = Array<UInt8>()
        let size = _src.length()

        // 头窗口：覆盖完整 ID3v2（上限 ID3V2_MAX_TAG_SIZE）
        let headLen = if (size < ID3V2_MAX_TAG_SIZE) {
            size
        } else {
            ID3V2_MAX_TAG_SIZE
        }
        if (headLen > 0) {
            _src.seekTo(0)
            head = tryReadWindow(headLen)
        }
        // 尾窗口：覆盖 APEv2 扫描窗（APE_SCAN_LIMIT）；ID3v1 的 128 字节必然在内
        let tailLen = if (size < APE_SCAN_LIMIT) {
            size
        } else {
            APE_SCAN_LIMIT
        }
        if (tailLen > 0 && size > tailLen) {
            _src.seekTo(size - tailLen)
            tail = tryReadWindow(tailLen)
        } else if (tailLen > 0) {
            // 文件比尾窗还短：头窗口已覆盖全文，直接复用
            tail = head
        }

        _src.seekTo(savedPos)
        mp3TagsFromWindows(head, tail)
    }

    /// 从源当前位置尽量读满 n 字节（EOF 处按实际返回）。
    private func tryReadWindow(n: Int64): Array<UInt8> {
        let buf = Array<UInt8>(n, repeat: 0)
        var got: Int64 = 0
        while (got < n) {
            let r = _src.readSome(buf.slice(got, n - got))
            if (r <= 0) {
                break
            }
            got += r
        }
        safeSlice(buf, 0, got)
    }

    public func info(): AudioInfo {
        checkOpen()

        let durationMs = if (_totalFrames > 0 && _sampleRate > 0) {
            _totalFrames * 1000 / _sampleRate
        } else {
            0
        }

        // bitDepth 恒为 32：有损格式不存在源位深，32 表示"输出为 float32"（见 AudioInfo 文档）
        AudioInfo(_sampleRate, _channels, 32, durationMs, _totalFrames, bitrateKbps: _bitrateKbps, isVbr: _isVbr,
            mpegVersion: _mpegVersion, layer: _layer, channelMode: _channelMode, durationEstimated: _durationEstimated)
    }

    // ------------------------------------------------------------------
    // Resource
    // ------------------------------------------------------------------

    public func isClosed(): Bool {
        _closed
    }

    /// 释放资源（幂等）：关闭字节源。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _src.close()
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
            let (n, e) = mp3FillWindow(_src, _buf, _bufLen)
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
        // 整体搬运而不是逐字节：逐字节循环在仓颉里带边界检查，64 KB 窗口下
        // 每帧一次就是可观的开销（见文档性能节）。向左搬移是安全的整体拷贝。
        _buf.copyTo(_buf, n, 0, left)
        _bufLen = left
    }

    /// 回到流起点并把解码器与窗口复位（向后定位用）。
    private func rewind(): Unit {
        _src.reopen()
        if (_audioStart > 0) {
            _src.seekTo(_audioStart)
        }
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
