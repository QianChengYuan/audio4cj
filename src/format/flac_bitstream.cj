package audio4cj.format

import audio4cj.core.ClosedResourceException
import audio4cj.core.CorruptedFileException
import audio4cj.core.DecodeException
import audio4cj.pcm.f32ToBytes
import std.fs.*

/* ============================================================================
 * 纯仓颉 FLAC 解码内核（流式）
 *
 * 【本文件的职责】
 *   把 flac_frame.cj 的帧解码接到真实文件与流式消费上，实现 FlacDecodeKernel。
 *   它负责：元数据解析、窗口回填、按请求帧数交付、seek。
 *   它**不含**任何 FLAC 算法 —— 算法全在 flac_frame.cj，且已与 dr_libs 逐样本对齐。
 *
 * 【内存与音频时长无关（库的核心承诺）】
 *   解码只用一块固定容量的窗口，容量由 STREAMINFO 推出（见 worstCaseFrameBytes），
 *   与文件大小、时长都无关。多数文件（4096 块 / 立体声 / 16 位）窗口约 25 KB。
 *
 * 【关键设计：窗口必须装得下"规范允许的最坏一帧"】
 *   FLAC 的帧长不写在流里（只能解完才知道），因此无法"按需只读一帧"。
 *   只要保证窗口容得下最坏一帧，**回填就永远只发生在帧边界**，
 *   位置记账随之变得不可能错位 —— 这是本实现刻意选择的约束，
 *   而不是为了避免扩容逻辑而做的妥协。
 *
 * 【为什么需要 pending 缓冲】
 *   `readF32Into(bytes, frames)` 的 frames 由调用方给（当前是 16384），
 *   不一定正好是帧边界的整数倍；而一帧一旦解码就必须整体消费（游标已推进）。
 *   因此把"本帧装不下"的尾部样本留在 pending 里，下次调用先交付它。
 *   这同时让 seek 到"帧中间"成为可能（见 seekToFrame）。
 *
 * 【本版明确未做】
 *   1. 帧头 CRC-8 与帧尾 CRC-16 的**校验**（flac_frame.cj 只读掉它们以对齐位置）；
 *   2. SEEKTABLE 索引定位 —— 当前 seek 一律"重开文件后向前解码"，
 *      正确但有最坏情况 O(n) 的开销（对无 SEEKTABLE 的文件，这与多数
 *      解码器的行为一致；有 SEEKTABLE 时应利用它。已在开发文档记录为待办）。
 * ========================================================================== */

/// f32 样本的字节数。
private let PCM_BYTES_PER_SAMPLE: Int64 = 4

/// 判定"窗口已无可用数据"的最小剩余字节数。
///
/// 一个 FLAC 帧头最少也要约 5 字节（同步码 + 字段 + CRC-8），
/// 加帧尾 CRC-16 与至少一个样本，取 16 作为保守下限：
/// 剩余不足 16 字节便不可能再构成一帧。
private let FLAC_MIN_FRAME_BYTES: Int64 = 16

/// 窗口容量的下限（避免极短视频或异常 STREAMINFO 给出过小的窗口）。
private let FLAC_MIN_WINDOW_BYTES: Int64 = 8192

/// 规范允许的最坏一帧的字节数 —— 用于确定窗口容量。
///
/// 最坏情况：所有声道都用 VERBATIM（未压缩）存储，且 side 声道多一位。
///   maxBlockSize × channels × 每样本字节数 + 帧头尾余量
///
/// 取规范上限会让窗口偏大（8 声道 32 位下约 2.6 MB），但它**有界且与时长无关**，
/// 这正是本库的内存承诺；多数文件只有几十 KB。
private func worstCaseFrameBytes(info: FlacStreamInfo): Int64 {
    let bits = info.bitsPerSample + 1
    let bytesPerSample = (bits + 7) / 8
    let bytes = info.maxBlockSize * info.channels * bytesPerSample + 64
    if (bytes < FLAC_MIN_WINDOW_BYTES) {
        FLAC_MIN_WINDOW_BYTES
    } else {
        bytes
    }
}

/// 窗口容量 = 最坏一帧的字节数 × 4，且不低于 64 KiB。
///
/// 【为什么必须大于"最坏一帧"】
///   解码前要保证的不变式是「从游标起到窗口末端至少还有最坏一帧的空间」
///   （见 decodeNextFrame）。而每次回填都要把未消费数据前移到窗口头部，
///   回填越频繁、这份拷贝开销越大。窗口取 4 倍于最坏帧后，
///   平均每约 3 帧才回填一次（每帧摊到的拷贝量约为 1/4 个窗口），
///   而内存仍是有界的、与时长无关 —— 多数文件的窗口为 64 KiB。
private func windowBytes(info: FlacStreamInfo): Int64 {
    let byMultiple = worstCaseFrameBytes(info) * 4
    let preferred: Int64 = 64 * 1024
    if (byMultiple < preferred) {
        preferred
    } else {
        byMultiple
    }
}

/// 精确读取 n 字节；不足则抛异常。
///
/// 注意 `File.read` 只能从数组**起始处**写入，因此分次读取时须经临时缓冲
/// 拼接 —— 不能靠切片（仓颉的切片是拷贝，写进去不会回到原数组）。
private func ffReadExact(file: File, n: Int64): Array<UInt8> {
    let buf = Array<UInt8>(n, repeat: 0)
    var got: Int64 = 0
    while (got < n) {
        let scratch = Array<UInt8>(n - got, repeat: 0)
        let r = file.read(scratch)
        if (r <= 0) {
            throw CorruptedFileException("FLAC 文件意外结束（还需 ${n - got} 字节）")
        }
        var i: Int64 = 0
        while (i < r) {
            buf[got + i] = scratch[i]
            i += 1
        }
        got += r
    }
    buf
}

/// 跳过 n 字节（分块读掉，避免为巨大的元数据块分配内存）。
private func ffSkip(file: File, n: Int64): Unit {
    var left = n
    let chunkSize: Int64 = 65536
    while (left > 0) {
        let chunk = if (left > chunkSize) {
            chunkSize
        } else {
            left
        }
        let scratch = Array<UInt8>(chunk, repeat: 0)
        let r = file.read(scratch)
        if (r <= 0) {
            throw CorruptedFileException("FLAC 元数据块声明的长度超出文件末尾")
        }
        left -= r
    }
}

/// 纯仓颉 FLAC 解码内核。
protected class PureFlacKernel <: FlacDecodeKernel {
    private let _path: String
    private let _info: FlacStreamInfo

    /// 固定容量窗口（与时长无关）。
    private let _window: Array<UInt8>

    /// 规范允许的最坏一帧的字节数。
    ///
    /// 它是窗口不变式的基准：**从游标起到窗口有效末端，必须至少有这么多字节**，
    /// 或者已到文件末尾。少了就会出现"帧起点在窗口内、终点在窗口外"，
    /// 而 decodeFrame 会读到窗口有效长度之外并报截断 —— 这正是本实现初版
    /// 的缺陷成因（详见 decodeNextFrame 的说明）。
    private let _worstFrameBytes: Int64

    /// 窗口上的位读取器（每次回填后重设位置与有效长度）。
    private let _reader: BitReader

    /// 归一化分母 2^(位深-1)，与 dr_flac 口径一致。
    private let _scale: Float32

    /// 窗口 [0, _valid) 为有效数据。
    private var _valid: Int64 = 0

    /// 窗口第 0 字节对应的文件偏移。
    private var _windowFileOffset: Int64 = 0

    /// 下一个待解帧的字节偏移（始终落在帧边界上）。
    private var _cursor: Int64 = 0

    /// 首个音频帧的字节偏移（seek 回退时用）。
    private let _firstFrameOffset: Int64

    /// 已交付（或已跳过）的样本数（每声道计时）。seek 与结束判断都用它。
    private var _deliveredFrames: Int64 = 0

    private var _file: File
    private var _closed: Bool = false

    /// pending：上一帧未能交付的交错 f32 样本，及其已读位置。
    private var _pending: Array<Float32> = Array<Float32>(0, repeat: 0.0)
    private var _pendingRead: Int64 = 0

    protected init(path: String) {
        this._path = path
        let file = File(path, Read)
        let (info, firstFrameOffset) = PureFlacKernel.readMetadata(file)

        this._info = info
        this._file = file
        this._firstFrameOffset = firstFrameOffset
        this._cursor = firstFrameOffset
        this._windowFileOffset = firstFrameOffset
        this._worstFrameBytes = worstCaseFrameBytes(info)
        this._window = Array<UInt8>(windowBytes(info), repeat: 0)
        this._reader = BitReader(this._window)
        this._scale = Float32(Int64(1) << (info.bitsPerSample - 1))
    }

    // ------------------------------------------------------------------
    // 元数据：流式解析（不把整个头部载入内存 —— 封面块可达 MB 级）
    // ------------------------------------------------------------------

    /// 解析元数据块链，返回 (STREAMINFO, 首帧字节偏移)。
    /// 返回时文件位置恰好落在首帧起点。
    private static func readMetadata(file: File): (FlacStreamInfo, Int64) {
        // 标记 + 首块头（复用经过测试的 parseStreamInfo，故按它期望的布局拼接）
        let prefix = ffReadExact(file, FLAC_MARKER_SIZE + 4)
        let firstLen = (Int64(prefix[FLAC_MARKER_SIZE + 1]) << 16) | (Int64(prefix[FLAC_MARKER_SIZE + 2]) << 8) | Int64(prefix[FLAC_MARKER_SIZE +
                3])
        if (firstLen <= 0 || firstLen > 4096) {
            throw CorruptedFileException("FLAC 首块长度 ${firstLen} 异常")
        }
        let body = ffReadExact(file, firstLen)

        let assembled = Array<UInt8>(FLAC_MARKER_SIZE + 4 + firstLen, repeat: 0)
        var i: Int64 = 0
        while (i < FLAC_MARKER_SIZE + 4) {
            assembled[i] = prefix[i]
            i += 1
        }
        i = 0
        while (i < firstLen) {
            assembled[FLAC_MARKER_SIZE + 4 + i] = body[i]
            i += 1
        }
        let info = parseStreamInfo(assembled)

        // 跳过其余元数据块
        var isLast = (Int64(prefix[FLAC_MARKER_SIZE]) & 0x80) != 0
        var offset = FLAC_MARKER_SIZE + 4 + firstLen
        var guard: Int64 = 0
        while (!isLast) {
            guard += 1
            if (guard > 1024) {
                throw CorruptedFileException("FLAC 元数据块数量异常（超过 1024 块）")
            }
            let h = ffReadExact(file, 4)
            isLast = (Int64(h[0]) & 0x80) != 0
            let len = (Int64(h[1]) << 16) | (Int64(h[2]) << 8) | Int64(h[3])
            ffSkip(file, len)
            offset += 4 + len
        }
        (info, offset)
    }

    // ------------------------------------------------------------------
    // 窗口回填
    // ------------------------------------------------------------------

    /// 从游标到窗口有效末端的字节数。
    private func remainingFromCursor(): Int64 {
        _windowFileOffset + _valid - _cursor
    }

    /// 窗口内是否还有未消费的字节。
    private func hasBuffered(): Bool {
        remainingFromCursor() > 0
    }

    /// 回填窗口：把未消费数据前移，再从文件补足。
    ///
    /// 只在帧边界调用（一帧是原子解码的，游标不会停在帧中间）。
    /// 若已到文件末尾则补不进数据，`_valid` 保持为前移后的长度。
    private func pageIn(): Unit {
        let keep = _windowFileOffset + _valid - _cursor
        if (keep < 0) {
            throw CorruptedFileException("FLAC 窗口记账异常（游标越过窗口末端）")
        }

        // 前移未消费数据
        if (keep > 0 && _cursor > _windowFileOffset) {
            let from = _cursor - _windowFileOffset
            var i: Int64 = 0
            while (i < keep) {
                _window[i] = _window[from + i]
                i += 1
            }
        }
        _windowFileOffset = _cursor
        _valid = keep

        // 补足窗口。read 只能写入数组起始处，故经长度恰好为"所需字节数"的
        // 临时缓冲读取 —— 这样不会读过窗口末端而丢掉文件位置。
        while (_valid < _window.size) {
            let need = _window.size - _valid
            let scratch = Array<UInt8>(need, repeat: 0)
            let got = _file.read(scratch)
            if (got <= 0) {
                break
            }
            var i: Int64 = 0
            while (i < got) {
                _window[_valid + i] = scratch[i]
                i += 1
            }
            _valid += got
        }

        _reader.limitTo(_valid)
    }

    /// 是否已到达数据末尾（按 STREAMINFO 的声明，或剩余数据已不足一帧）。
    private func atEnd(): Bool {
        if (_info.totalSamples > 0 && _deliveredFrames >= _info.totalSamples) {
            return true
        }
        // 无总样本数声明（流式编码）：以"剩余不足一帧的下限"作为结束判据
        if (_info.totalSamples <= 0 && remainingFromCursor() < FLAC_MIN_FRAME_BYTES) {
            return true
        }
        false
    }

    /// 解码下一帧（必要时先回填）。
    ///
    /// 【不变式：从游标起到窗口末端，至少要有"最坏一帧"的空间】
    ///
    /// 初版只判断"窗口里还有没有数据"，那是**不够的**。当时的推理是
    /// "窗口容得下最坏一帧，所以回填之后下一帧必然装得下" —— 但这只对
    /// **回填后的第一帧**成立：窗口被后续帧逐段消费后，游标会渐渐逼近窗口
    /// 末端，直到剩余空间装不下一帧；而此时 `hasBuffered()` 仍为真
    /// （游标确实在窗口内），于是根本不触发回填，decodeFrame 一路读到窗口
    /// 有效长度之外，报"FLAC 比特流截断（需 1 位，仅剩 0 位）"。
    ///
    /// 实测证据（diagnosticState 的输出）：
    ///   游标=19794  窗口起点=8286  有效长度=12352
    ///   => 游标在窗口内，但到窗口末端只剩 844 字节，而该帧约 1.1 KB。
    ///
    /// 修正后判据改为"剩余空间是否够一帧"，回填因此发生在真正需要的时候。
    /// 到文件末尾时补不进数据，此时剩余数据本身就是最后一帧（合法文件），
    /// 或文件确实被截断（由 decodeFrame 报错，语义正确）。
    private func decodeNextFrame(): ?FlacFrame {
        if (remainingFromCursor() < _worstFrameBytes) {
            pageIn()
            if (!hasBuffered()) {
                return None
            }
        }
        let startInWindow = _cursor - _windowFileOffset
        _reader.seekToBit(startInWindow * 8)
        let frame = decodeFrame(_reader, _info)

        // 游标推进到帧尾（帧体在 CRC-16 前已按规范字节对齐，这里再向上取整保险）
        let endBit = _reader.bitPosition()
        _cursor = _windowFileOffset + (endBit + 7) / 8
        frame
    }

    // ------------------------------------------------------------------
    // FlacDecodeKernel 实现
    // ------------------------------------------------------------------

    public func sampleRate(): Int64 {
        _info.sampleRate
    }

    public func channels(): Int64 {
        _info.channels
    }

    public func bitsPerSample(): Int64 {
        _info.bitsPerSample
    }

    /// 总帧数；**0 表示不可知**（与内核接口约定一致）。
    public func totalFrames(): Int64 {
        _info.totalSamples
    }

    public func readF32Into(bytes: Array<UInt8>, frames: Int64): Int64 {
        checkOpen()
        if (frames <= 0 || bytes.size < PCM_BYTES_PER_SAMPLE) {
            return 0
        }
        let channels = _info.channels
        let capacityFrames = bytes.size / (channels * PCM_BYTES_PER_SAMPLE)
        let want = if (frames < capacityFrames) {
            frames
        } else {
            capacityFrames
        }
        if (want <= 0) {
            throw DecodeException("PCM 缓冲区过小（${bytes.size} 字节）")
        }

        var produced: Int64 = 0
        var byteOffset: Int64 = 0

        // 1) 先交付 pending（上一帧的尾部）
        if (_pendingRead < _pending.size) {
            let available = (_pending.size - _pendingRead) / channels
            var take = want
            if (take > available) {
                take = available
            }
            let slice = Array<Float32>(take * channels, repeat: 0.0)
            var i: Int64 = 0
            while (i < take * channels) {
                slice[i] = _pending[_pendingRead + i]
                i += 1
            }
            writeF32(bytes, byteOffset, slice)
            byteOffset += slice.size * PCM_BYTES_PER_SAMPLE
            _pendingRead += slice.size
            produced += take
            if (_pendingRead >= _pending.size) {
                _pending = Array<Float32>(0, repeat: 0.0)
                _pendingRead = 0
            }
        }

        // 2) 逐帧解码
        while (produced < want && !atEnd()) {
            let frame = match (decodeNextFrame()) {
                case Some(f) => f
                case None => break
            }

            let total = frame.blockSize * channels
            let startSample: Int64 = 0
            let needFrames = want - produced
            if (needFrames >= frame.blockSize) {
                // 整帧交付
                let chunk = Array<Float32>(total, repeat: 0.0)
                interleave(frame, chunk, startSample, frame.blockSize)
                writeF32(bytes, byteOffset, chunk)
                byteOffset += chunk.size * PCM_BYTES_PER_SAMPLE
                produced += frame.blockSize
                _deliveredFrames += frame.blockSize
            } else {
                // 只交付前 needFrames 帧，其余留 pending
                let head = Array<Float32>(needFrames * channels, repeat: 0.0)
                interleave(frame, head, 0, needFrames)
                writeF32(bytes, byteOffset, head)
                byteOffset += head.size * PCM_BYTES_PER_SAMPLE
                produced += needFrames

                let rest = frame.blockSize - needFrames
                _pending = Array<Float32>(rest * channels, repeat: 0.0)
                interleave(frame, _pending, needFrames, rest)
                _pendingRead = 0
                _deliveredFrames += frame.blockSize
            }
        }

        produced
    }

    public func seekToFrame(index: Int64): Bool {
        checkOpen()
        if (index < 0) {
            return false
        }
        if (_info.totalSamples > 0 && index >= _info.totalSamples) {
            return false
        }

        // 回退需要重开文件：窗口只前向回填，文件流也不支持后退
        // （待办：有 SEEKTABLE 时应从中定位，当前一律重开并向前解码）
        if (index < _deliveredFrames) {
            if (!rewind()) {
                return false
            }
        } else {
            // 即使向前，也要清掉 pending，避免交付错位的样本
            _pending = Array<Float32>(0, repeat: 0.0)
            _pendingRead = 0
        }

        // 逐帧前进到目标：目标可能落在帧中间，此时把该帧的尾部留作 pending。
        // 用显式条件变量而不是 `while (true)`：后者会让函数末端的可达性
        // 依赖编译器的推断，实测在本 SDK 上会报 mismatched types。
        var positioned = false
        while (!positioned) {
            let frameStart = _deliveredFrames
            let frame = match (decodeNextFrame()) {
                case Some(f) => f
                case None => return false
            }
            let frameEnd = frameStart + frame.blockSize
            if (index < frameEnd) {
                let skip = index - frameStart
                if (skip == 0) {
                    // 正好落在帧边界：整帧留作 pending，下次调用原样交付
                    _pending = Array<Float32>(frame.blockSize * _info.channels, repeat: 0.0)
                    interleave(frame, _pending, 0, frame.blockSize)
                } else {
                    // 落在帧中间：丢掉前 skip 个样本，其余留作 pending
                    let rest = frame.blockSize - skip
                    _pending = Array<Float32>(rest * _info.channels, repeat: 0.0)
                    interleave(frame, _pending, skip, rest)
                }
                _pendingRead = 0
                _deliveredFrames = index
                positioned = true
            } else {
                _deliveredFrames = frameEnd
            }
        }
        true
    }

    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _file.close()
        }
    }

    public func isClosed(): Bool {
        _closed
    }

    /// 【仅供诊断】窗口与游标的当前状态。
    ///
    /// 返回 (游标, 窗口起点, 有效长度, 首帧偏移, 已交付样本数)。
    ///
    /// 为什么要暴露这些内部量：`readF32Into` 抛出的"比特流截断"只给一个位偏移，
    /// 无法区分三种完全不同的成因 ——
    ///   (a) 帧跨越了窗口末端（"窗口容得下最坏一帧"这一前提被违反）；
    ///   (b) 游标记账错（少消费了字节，导致下一帧从数据中间开始）；
    ///   (c) 结束判定错（声明的总样本数与实际帧数之和不等，多解了一帧）。
    /// 有了这四个数就能直接判定，而不必靠猜。
    protected func diagnosticState(): (Int64, Int64, Int64, Int64, Int64) {
        (_cursor, _windowFileOffset, _valid, _firstFrameOffset, _deliveredFrames)
    }

    // ------------------------------------------------------------------
    // 内部辅助
    // ------------------------------------------------------------------

    /// 重开文件并回到首帧（同时清空窗口与 pending 状态）。
    private func rewind(): Bool {
        _file.close()
        _file = File(_path, Read)
        let (info, firstFrameOffset) = PureFlacKernel.readMetadata(_file)
        if (info.totalSamples != _info.totalSamples || info.sampleRate != _info.sampleRate || info.channels != _info
            .channels) {
            return false // 文件在两次打开之间被替换
        }
        _windowFileOffset = firstFrameOffset
        _cursor = firstFrameOffset
        _valid = 0
        _deliveredFrames = 0
        _pending = Array<Float32>(0, repeat: 0.0)
        _pendingRead = 0
        _reader.limitTo(0)
        true
    }

    /// 把帧内 [start, start+count) 的样本按声道交错写入 out，并完成 f32 归一化。
    ///
    /// 归一化口径与 dr_flac 一致：sample / 2^(位深-1)。
    /// 注意 FLAC 的 8 位样本是**有符号**的（与 WAV 的无符号 8 位不同），
    /// 因此这里不能复用 pcmToF32。
    private func interleave(frame: FlacFrame, out: Array<Float32>, start: Int64, count: Int64): Unit {
        let channels = _info.channels
        var i: Int64 = 0
        while (i < count) {
            var ch: Int64 = 0
            while (ch < channels) {
                out[i * channels + ch] = Float32(frame.samples[ch][start + i]) / _scale
                ch += 1
            }
            i += 1
        }
    }

    /// 把 f32 样本按位视角写入字节缓冲（保持与既有 f32 路径一致的字节序）。
    private func writeF32(bytes: Array<UInt8>, offset: Int64, samples: Array<Float32>): Unit {
        let raw = f32ToBytes(samples)
        var i: Int64 = 0
        while (i < raw.size) {
            bytes[offset + i] = raw[i]
            i += 1
        }
    }

    private func checkOpen(): Unit {
        if (_closed) {
            throw ClosedResourceException("对已关闭的纯仓颉 FLAC 内核执行操作")
        }
    }
}
