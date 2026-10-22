package audio4cj.format

import audio4cj.core.*
import audio4cj.meta.*
import audio4cj.pcm.f32ToBytes
import audio4cj.pcm.readUInt32LE
import std.collection.ArrayList

/* ============================================================================
 * Ogg Vorbis demuxer + 解码装配（FormatReader 实现）
 *
 * 【为什么不能照搬 Ogg-FLAC 的"页体拼接"】
 *   Ogg-FLAC 的解码器只认一条连续字节流，packet 边界对它没有意义，所以
 *   ogg_flac_source.cj 可以直接把所有页体接起来。Vorbis 完全相反：
 *   每个音频 packet 自带 mode/floor/residue 的完整状态，**必须按 packet 边界**
 *   交给解码内核；跨页 packet 的字节要按 lacing 值重组。因此本文件实现
 *   一个真正的 Ogg packet reader，而不是字节源适配器。
 *
 * 【分块交付】
 *   一个 Vorbis packet 通常只产出约 1/2 块大小（几百到一千帧）。若一包一个
 *   Packet，上层 FrameStream 的调用次数会非常多。这里累积到约
 *   VORBIS_CHUNK_FRAMES 帧再交付，Packet.data 是**已解码的 f32 交错 PCM 字节**
 *   （与 MP3 / FLAC 一致），VorbisPcmDecoder 只做字节视角转换。
 *
 * 【总帧数与尾部裁剪】
 *   Ogg 最后一页的 granule position 就是全流 PCM 总帧数（含首包 priming 的
 *   扣除）。初始化时扫描一遍页头（只 seek 过页体，不解码）拿到它，
 *   既用于 info().totalFrames，也用于把最后一包多解出的 padding 裁掉。
 *   这一步是必要的：Vorbis 的最后一个 packet 通常不是整块。
 *
 * 【seek】
 *   第一版刻意不实现 granule 页级定位，而是"重开 + 从流首解码丢弃到目标帧"。
 *   最坏 O(n)，但状态机只有一条路径，正确性容易保证；返回实际落点毫秒。
 *   后续若要做页级定位，只需替换 seekTo 内部的推进方式，decode 内核不变。
 *
 * 【CRC】
 *   每页整页校验（CRC 字段先置零），与 ogg_flac_source.cj 同一套
 *   crc32Ogg。损坏页不会被静默喂给解码器。
 * ========================================================================== */

/// 每块交付的目标帧数（约 0.09 秒 @44.1kHz）。
private let VORBIS_CHUNK_FRAMES: Int64 = 4096

/// Ogg 页头长度。
private let VORBIS_OGG_HEADER_SIZE: Int64 = 27

/// Ogg 页头类型位。
private let VORBIS_OGG_HTYPE_CONTINUED: UInt8 = 0x01
private let VORBIS_OGG_HTYPE_BOS: UInt8 = 0x02
private let VORBIS_OGG_HTYPE_EOS: UInt8 = 0x04

/// Ogg Vorbis 读取器。
protected class VorbisFormatReader <: FormatReader {
    private let _path: String
    private var _src: ByteSource
    private var _closed: Bool = false

    /// 选定逻辑流的 serial（文件中第一个 BOS 页）。
    private var _serial: Int64 = -1

    /// 三个头包解析出的配置与元数据。
    private var _setup: VorbisSetup = VorbisSetup()
    private var _core: ?VorbisDecoderCore = None
    private var _metadata: Tag = Tag()
    private var _sampleRate: Int64 = 0
    private var _channels: Int64 = 0
    private var _totalFrames: Int64 = -1

    // ---- 当前页状态 ----
    private var _pageBody: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    private var _pageLaces: Array<UInt8> = Array<UInt8>(0, repeat: 0)
    private var _pageLaceIndex: Int64 = 0
    private var _pageBodyOffset: Int64 = 0
    private var _curSerial: Int64 = -1
    private var _curHtype: UInt8 = 0
    private var _curGranule: Int64 = -1
    private var _curEos: Bool = false

    /// 跨页 packet 的暂存区。
    private var _pendingPacket: ArrayList<UInt8> = ArrayList<UInt8>()

    // ---- 交付状态 ----
    private var _framesDelivered: Int64 = 0
    private var _pendingPcm: ArrayList<Float32> = ArrayList<Float32>()
    private var _streamEnded: Bool = false
    private var _drained: Bool = false

    protected init(path: String) {
        _path = path
        _src = FileByteSource(path)
        try {
            openStream()
        } catch (e: Exception) {
            _src.close()
            throw e
        }
    }

    /// 从调用方提供的字节源构造（openBytes 内存直通）。
    protected init(source: ByteSource, path: String) {
        _path = path
        _src = source
        try {
            openStream()
        } catch (e: Exception) {
            source.close()
            throw e
        }
    }

    // ------------------------------------------------------------------
    // FormatReader
    // ------------------------------------------------------------------

    public func tracks(): Array<Track> {
        [Track(0, "vorbis", _sampleRate, _channels)]
    }

    public func nextPacket(): ?Packet {
        if (_closed) {
            throw CorruptedFileException("对已关闭的 Vorbis reader 执行操作：${_path}")
        }
        if (_drained) {
            return None
        }
        let core = decoderCore()

        while (true) {
            let pendingFrames = _pendingPcm.size / _channels
            if (pendingFrames >= VORBIS_CHUNK_FRAMES) {
                break
            }
            if (_streamEnded) {
                break
            }
            match (nextRawPacket()) {
                case Some(raw) => match (core.decodePacket(raw)) {
                    case Some(chunk) =>
                        var i: Int64 = 0
                        while (i < chunk.samples.size) {
                            _pendingPcm.add(chunk.samples[i])
                            i += 1
                        }
                    case None => ()
                }
                case None => _streamEnded = true
            }
        }

        var frames = _pendingPcm.size / _channels
        if (_totalFrames >= 0) {
            let maxFrames = _totalFrames - _framesDelivered
            if (maxFrames <= 0) {
                _drained = true
                _pendingPcm = ArrayList<Float32>()
                return None
            }
            if (frames > maxFrames) {
                frames = maxFrames
            }
        }
        if (frames <= 0) {
            if (_streamEnded) {
                _drained = true
            }
            _pendingPcm = ArrayList<Float32>()
            return None
        }

        let sampleCount = frames * _channels
        let samples = Array<Float32>(sampleCount, repeat: 0.0)
        var i: Int64 = 0
        while (i < sampleCount) {
            samples[i] = _pendingPcm[i]
            i += 1
        }
        let rest = ArrayList<Float32>()
        i = sampleCount
        while (i < _pendingPcm.size) {
            rest.add(_pendingPcm[i])
            i += 1
        }
        _pendingPcm = rest

        let timestampMs = _framesDelivered * 1000 / _sampleRate
        let durationMs = frames * 1000 / _sampleRate
        _framesDelivered += frames
        if (_totalFrames >= 0 && _framesDelivered >= _totalFrames) {
            _drained = true
        }
        Packet(0, f32ToBytes(samples), timestampMs, durationMs)
    }

    public func seekTo(timestampMs: Int64): Int64 {
        if (_closed) {
            throw CorruptedFileException("对已关闭的 Vorbis reader 执行操作：${_path}")
        }
        var targetMs = timestampMs
        if (targetMs < 0) {
            targetMs = 0
        }
        var targetFrame = targetMs * _sampleRate / 1000
        if (_totalFrames >= 0 && targetFrame > _totalFrames) {
            targetFrame = _totalFrames
        }

        // 重开并重新定位到音频数据起点（三个头包之后）。不重新扫描 granule：
        // _setup / _metadata / _totalFrames 已在 init 时固定。
        _src.reopen()
        resetPageState()
        if (!readPage()) {
            throw CorruptedFileException("Vorbis seek 时文件为空：${_path}")
        }
        if ((_curHtype & VORBIS_OGG_HTYPE_BOS) == 0) {
            throw CorruptedFileException("Vorbis seek 时首页缺少 BOS 标志：${_path}")
        }
        _serial = _curSerial
        var headerCount: Int64 = 0
        while (headerCount < 3) {
            match (nextRawPacket()) {
                case Some(_) => headerCount += 1
                case None => throw CorruptedFileException("Vorbis seek 时头包不足：${_path}")
            }
        }

        _core = VorbisDecoderCore(_setup)
        _framesDelivered = 0
        _pendingPcm = ArrayList<Float32>()
        _streamEnded = false
        _drained = false

        let core = decoderCore()
        while (_framesDelivered < targetFrame && !_streamEnded) {
            match (nextRawPacket()) {
                case Some(raw) => match (core.decodePacket(raw)) {
                    case Some(chunk) =>
                        let need = targetFrame - _framesDelivered
                        if (chunk.frames <= need) {
                            _framesDelivered += chunk.frames
                        } else {
                            // 目标落在块中间：把剩余样本留到 _pendingPcm，
                            // 下一次 nextPacket 从 targetFrame 继续交付。
                            let rest = ArrayList<Float32>()
                            var idx = need * _channels
                            while (idx < chunk.samples.size) {
                                rest.add(chunk.samples[idx])
                                idx += 1
                            }
                            _pendingPcm = rest
                            _framesDelivered = targetFrame
                        }
                    case None => ()
                }
                case None => _streamEnded = true
            }
        }

        if (_totalFrames >= 0 && _framesDelivered >= _totalFrames) {
            _drained = true
        }
        _framesDelivered * 1000 / _sampleRate
    }

    public func metadata(): Tag {
        _metadata
    }

    public func info(): AudioInfo {
        let durationMs = if (_totalFrames >= 0 && _sampleRate > 0) {
            _totalFrames * 1000 / _sampleRate
        } else {
            0
        }
        AudioInfo(_sampleRate, _channels, 32, durationMs, _totalFrames)
    }

    public func isClosed(): Bool {
        _closed
    }

    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _src.close()
        }
    }

    // ------------------------------------------------------------------
    // 装配用只读访问器（facade 在构造 Decoder 时需要）
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
    // 初始化：定位流、扫描 granule、解析三个头包
    // ------------------------------------------------------------------

    private func openStream(): Unit {
        _src.reopen()
        resetPageState()

        if (!readPage()) {
            throw CorruptedFileException("Ogg 文件为空：没有任何页面（${_path}）")
        }
        if ((_curHtype & VORBIS_OGG_HTYPE_BOS) == 0) {
            throw CorruptedFileException("Ogg 首个页面缺少 BOS 标志，不是规范的 Ogg 流（${_path}）")
        }
        _serial = _curSerial

        // 扫描最后一页的 granule。只需页头 + 段表；页体直接 seek 跳过。
        let lastGranule = scanLastGranule()

        // 回到起点，重新读首页并解析头包。
        _src.reopen()
        resetPageState()
        if (!readPage()) {
            throw CorruptedFileException("Ogg 文件在重读时为空：${_path}")
        }
        _serial = _curSerial

        let identification = match (nextRawPacket()) {
            case Some(p) => p
            case None => throw CorruptedFileException("Vorbis identification 头包缺失：${_path}")
        }
        let comment = match (nextRawPacket()) {
            case Some(p) => p
            case None => throw CorruptedFileException("Vorbis comment 头包缺失：${_path}")
        }
        let setupPacket = match (nextRawPacket()) {
            case Some(p) => p
            case None => throw CorruptedFileException("Vorbis setup 头包缺失：${_path}")
        }

        _setup = VorbisSetup.parse(identification, setupPacket)
        VorbisSetup.validateComment(comment)
        _metadata = parseVorbisComment(comment[7..comment.size])
        _sampleRate = _setup.sampleRate
        _channels = _setup.channels
        _totalFrames = lastGranule
        _core = VorbisDecoderCore(_setup)
        _framesDelivered = 0
        _pendingPcm = ArrayList<Float32>()
        _streamEnded = false
        _drained = false
    }

    /// 从当前源位置扫描到文件尾，返回选定流最后一个有效 granule。
    private func scanLastGranule(): Int64 {
        var last = if (_curGranule >= 0) {
            _curGranule
        } else {
            -1
        }
        while (true) {
            let head = readFully(VORBIS_OGG_HEADER_SIZE)
            if (head == None) {
                break
            }
            let h = head.getOrThrow()
            if (!(h[0] == 0x4F && h[1] == 0x67 && h[2] == 0x67 && h[3] == 0x53)) {
                throw CorruptedFileException("Ogg 页起始处缺少 \"OggS\" 捕获模式（${_path}）")
            }
            if (h[4] != 0) {
                throw CorruptedFileException("Ogg 结构版本为 ${h[4]}，本实现只支持 0（${_path}）")
            }
            let serial = Int64(readUInt32LE(h, 14))
            let granule = readGranule(h)
            let segCount = Int64(h[26])
            let table = match (readFully(segCount)) {
                case Some(t) => t
                case None => throw CorruptedFileException("Ogg 段表被截断（${_path}）")
            }
            var bodyLen: Int64 = 0
            var i: Int64 = 0
            while (i < segCount) {
                bodyLen += Int64(table[i])
                i += 1
            }
            if (serial == _serial && granule >= 0) {
                last = granule
            }
            if (bodyLen > 0) {
                _src.skip(bodyLen)
            }
        }
        last
    }

    // ------------------------------------------------------------------
    // Ogg 页读取 / packet 重组
    // ------------------------------------------------------------------

    /// 读下一页到 _pageBody / _pageLaces，并整页校验 CRC。
    /// 返回 false 表示源在页边界处干净结束。
    private func readPage(): Bool {
        let head = readFully(VORBIS_OGG_HEADER_SIZE)
        if (head == None) {
            return false
        }
        let h = head.getOrThrow()
        if (!(h[0] == 0x4F && h[1] == 0x67 && h[2] == 0x67 && h[3] == 0x53)) {
            throw CorruptedFileException("Ogg 页面起始处缺少 \"OggS\" 捕获模式（${_path}）")
        }
        if (h[4] != 0) {
            throw CorruptedFileException("Ogg 结构版本为 ${h[4]}，本实现只支持 0（${_path}）")
        }

        let segCount = Int64(h[26])
        let table = match (readFully(segCount)) {
            case Some(t) => t
            case None => throw CorruptedFileException("Ogg 段表被截断（${_path}）")
        }
        var bodyLen: Int64 = 0
        var i: Int64 = 0
        while (i < segCount) {
            bodyLen += Int64(table[i])
            i += 1
        }
        let body = match (readFully(bodyLen)) {
            case Some(b) => b
            case None => throw CorruptedFileException("Ogg 页体被截断（${_path}）")
        }

        // CRC 覆盖整页，计算前必须把页头里的 CRC 字段置零。
        let page = Array<UInt8>(VORBIS_OGG_HEADER_SIZE + segCount + bodyLen, repeat: 0)
        i = 0
        while (i < VORBIS_OGG_HEADER_SIZE) {
            page[i] = h[i]
            i += 1
        }
        page[22] = 0
        page[23] = 0
        page[24] = 0
        page[25] = 0
        i = 0
        while (i < segCount) {
            page[VORBIS_OGG_HEADER_SIZE + i] = table[i]
            i += 1
        }
        i = 0
        while (i < bodyLen) {
            page[VORBIS_OGG_HEADER_SIZE + segCount + i] = body[i]
            i += 1
        }
        let stored = readUInt32LE(h, 22)
        let actual = crc32Ogg(page, 0, page.size)
        if (stored != actual) {
            throw CorruptedFileException("Ogg 页 CRC 校验失败：页头 ${stored}，实算 ${actual}（${_path}）")
        }

        _pageBody = body
        _pageLaces = table
        _pageLaceIndex = 0
        _pageBodyOffset = 0
        _curSerial = Int64(readUInt32LE(h, 14))
        _curHtype = h[5]
        _curGranule = readGranule(h)
        _curEos = ((_curHtype & VORBIS_OGG_HTYPE_EOS) != 0) && (_curSerial == _serial)
        true
    }

    /// 取下一个完整 packet（只处理选定 serial），None 表示流正常结束。
    private func nextRawPacket(): ?Array<UInt8> {
        while (true) {
            if (_pageLaceIndex < _pageLaces.size) {
                let lace = Int64(_pageLaces[_pageLaceIndex])
                _pageLaceIndex += 1
                var i: Int64 = 0
                while (i < lace) {
                    _pendingPacket.add(_pageBody[_pageBodyOffset + i])
                    i += 1
                }
                _pageBodyOffset += lace
                if (lace < 255) {
                    let packet = _pendingPacket.toArray()
                    _pendingPacket = ArrayList<UInt8>()
                    return packet
                }
                continue
            }

            if (_curEos) {
                if (_pendingPacket.size > 0) {
                    throw CorruptedFileException("Ogg Vorbis 流在 packet 中途结束（EOS 页缺少终止 lacing）")
                }
                return None
            }

            if (!readPage()) {
                if (_pendingPacket.size > 0) {
                    throw CorruptedFileException("Ogg Vorbis 流在文件末尾的 packet 中途结束")
                }
                return None
            }

            if (_curSerial != _serial) {
                // 其他逻辑流的页面：整页跳过（_curEos 已按 serial 过滤）。
                _pageLaceIndex = _pageLaces.size
                continue
            }

            let continued = (_curHtype & VORBIS_OGG_HTYPE_CONTINUED) != 0
            if (_pendingPacket.size > 0 && !continued) {
                throw CorruptedFileException("Ogg Vorbis packet 跨页但下一页缺少 continued 标志")
            }
            if (_pendingPacket.size == 0 && continued) {
                throw CorruptedFileException("Ogg Vorbis 页面续包标志与 packet 边界不一致")
            }
        }
        // 理论不可达（上面的 while true 只会 return / throw）；仅为让返回类型
        // 在所有控制流上都成立。
        None
    }

    private func resetPageState(): Unit {
        _pageBody = Array<UInt8>(0, repeat: 0)
        _pageLaces = Array<UInt8>(0, repeat: 0)
        _pageLaceIndex = 0
        _pageBodyOffset = 0
        _curSerial = -1
        _curHtype = 0
        _curGranule = -1
        _curEos = false
        _pendingPacket = ArrayList<UInt8>()
    }

    /// 精确读 n 字节；一个字节都读不到时返回 None（干净 EOF）。
    private func readFully(n: Int64): ?Array<UInt8> {
        let out = Array<UInt8>(n, repeat: 0)
        var got: Int64 = 0
        while (got < n) {
            let scratch = Array<UInt8>(n - got, repeat: 0)
            let r = _src.readSome(scratch)
            if (r <= 0) {
                if (got == 0) {
                    return None
                }
                throw CorruptedFileException("Ogg 页在文件末尾被截断（需 ${n} 字节，已得 ${got}）：${_path}")
            }
            var i: Int64 = 0
            while (i < r) {
                out[got + i] = scratch[i]
                i += 1
            }
            got += r
        }
        out
    }

    private func decoderCore(): VorbisDecoderCore {
        match (_core) {
            case Some(c) => c
            case None => throw CorruptedFileException("Vorbis 解码内核尚未初始化：${_path}")
        }
    }

    /// 读 8 字节小端 granule position；全 0xFF 表示"无 packet 在此页结束"。
    private func readGranule(h: Array<UInt8>): Int64 {
        let lo = Int64(readUInt32LE(h, 6))
        let hi = Int64(readUInt32LE(h, 10))
        if (hi == 0xFFFFFFFF && lo == 0xFFFFFFFF) {
            return -1
        }
        hi * 4294967296 + lo
    }
}
