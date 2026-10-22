package audio4cj.format

import audio4cj.core.CorruptedFileException
import std.collection.ArrayList
import std.math.pow

/* ============================================================================
 * Vorbis 音频包解码（纯仓颉）
 *
 * 【范围】
 *   本文件只处理"三个头包之后"的音频包：模式选择、floor1、residue 0/1/2、
 *   反耦合、floor 曲线合成、IMDCT、重叠相加。容器、packet 重组、seek 与
 *   分块交付在 vorbis.cj；二者按 MP3 的同一分工拆开：
 *     Reader 持有本内核 → 内核产出 f32 交错 PCM → Decoder 只做字节视角转换。
 *
 * 【参考实现】
 *   stb_vorbis.c（公有领域 / MIT 双许可）的 vorbis_decode_packet_rest /
 *   vorbis_finish_frame / decode_residue。移植时做了三处按 Vorbis I 规范
 *   修正的边界：
 *     · residue type 0 的 codebook_decode_step 长度取 codebook 维度，
 *       stb 的 `n-offset-k` 对绝对 offset 会算成负数；
 *     · residue type 2 的反交织边界用 `p_inter*ch + c_inter`，
 *       stb 的 `p_inter*ch - c_inter` 会把可写长度多算 2*c_inter；
 *     · 首包的 discard_samples_deferred 只推进输出游标，不移动 overlap-add
 *       的窗口起点（窗口混合必须在原始 left_start 处做）。
 *   除此之外的位序、Bresenham 浮点表与整数插值、耦合公式逐行对照 stb，
 *   因为这些步骤对"差一位就变噪声"极其敏感。
 *
 * 【重叠相加的记账】
 *   每个包解码出 n 个时域样本；本包只输出 [left_start, right_start)，
 *   右半段 [right_start, right_end) 存入 previous_window，等下一个包再混合。
 *   混合窗口长度 = 前后两块中较短块的 1/2，窗口表取较短块的全窗前半段。
 *   首包没有前块，混合窗口长度为 0，输出 0 帧，只保存尾部 —— 这正是
 *   Vorbis 的 priming 样本，不能计入总帧数。
 * ========================================================================== */

/// Vorbis 包解码后的 PCM 片段（f32 交错）。
protected class VorbisPcmChunk {
    protected let frames: Int64
    protected let samples: Array<Float32>

    protected init(frames: Int64, samples: Array<Float32>) {
        this.frames = frames
        this.samples = samples
    }
}

/// Vorbis 音频包解码内核。
protected class VorbisDecoderCore {
    private let _setup: VorbisSetup
    private let _mdct: VorbisMdct

    /// 每个声道的频域/时域复用缓冲，长度均为最大块大小。
    private let _spectra: Array<Array<Float32>>

    /// 上一包留给本包混合的右半段（长度 = 上一包 overlap）。
    private let _prevWindows: Array<Array<Float32>>

    /// 上一包尾部的长度（样本数）；0 表示还没有可混合的前块。
    private var _prevOverlap: Int64 = 0

    /// 是否还在处理第一个音频包（首包只 prime，不输出）。
    private var _firstPacket: Bool = true

    /// 首包为长块而下一包为短块时，需要从后续输出中丢弃的样本数。
    private var _discardDeferred: Int64 = 0

    /// 每声道 floor1 解码的 Y 值与 step2 标志。
    private let _finalY: Array<Array<Int64>>
    private let _step2: Array<Array<Bool>>

    protected init(setup: VorbisSetup) {
        _setup = setup
        _mdct = VorbisMdct(setup.blocksize0, setup.blocksize1)
        let channels = setup.channels

        _spectra = Array<Array<Float32>>(channels, repeat: Array<Float32>(0, repeat: 0.0))
        _prevWindows = Array<Array<Float32>>(channels, repeat: Array<Float32>(0, repeat: 0.0))
        var ch: Int64 = 0
        while (ch < channels) {
            _spectra[ch] = Array<Float32>(setup.blocksize1, repeat: 0.0)
            _prevWindows[ch] = Array<Float32>(setup.blocksize1 / 2, repeat: 0.0)
            ch += 1
        }

        var maxValues: Int64 = 2
        var f: Int64 = 0
        while (f < setup.floors.size) {
            if (setup.floors[f].values > maxValues) {
                maxValues = setup.floors[f].values
            }
            f += 1
        }
        _finalY = Array<Array<Int64>>(channels, repeat: Array<Int64>(0, repeat: 0))
        _step2 = Array<Array<Bool>>(channels, repeat: Array<Bool>(0, repeat: false))
        ch = 0
        while (ch < channels) {
            _finalY[ch] = Array<Int64>(maxValues, repeat: 0)
            _step2[ch] = Array<Bool>(maxValues, repeat: false)
            ch += 1
        }
    }

    /// 重置到"流首"状态；seek 重开后调用。
    protected func reset(): Unit {
        _prevOverlap = 0
        _firstPacket = true
        _discardDeferred = 0
        var ch: Int64 = 0
        while (ch < _spectra.size) {
            var i: Int64 = 0
            while (i < _spectra[ch].size) {
                _spectra[ch][i] = 0.0
                i += 1
            }
            i = 0
            while (i < _prevWindows[ch].size) {
                _prevWindows[ch][i] = 0.0
                i += 1
            }
            ch += 1
        }
    }

    /// 解码一个音频包；首包 / 丢弃期返回 None。
    protected func decodePacket(packet: Array<UInt8>): ?VorbisPcmChunk {
        if (packet.size == 0) {
            return None
        }
        let br = VorbisBitReader(packet)

        // 音频包类型位必须为 0；为 1 的是头包，按规范忽略。
        if (br.getBits(1) != 0) {
            return None
        }

        let modeCount = _setup.modes.size
        let modeBits = vorbisIlog(modeCount - 1)
        let modeIndex = if (modeBits > 0) {
            br.getBits(modeBits)
        } else {
            0
        }
        if (modeIndex < 0 || modeIndex >= modeCount) {
            throw CorruptedFileException("Vorbis 音频包 mode 索引越界：${modeIndex} / ${modeCount}")
        }
        let mode = _setup.modes[modeIndex]
        let blockFlag = mode.blockFlag
        let n = if (blockFlag) {
            _setup.blocksize1
        } else {
            _setup.blocksize0
        }
        let n2 = n / 2

        var prevFlag = false
        var nextFlag = false
        if (blockFlag) {
            prevFlag = br.getBits(1) != 0
            nextFlag = br.getBits(1) != 0
        }

        // 窗口区域的起点（stb vorbis_decode_initial 的 left_start / right_start）
        let windowCenter = n / 2
        let leftStart = if (blockFlag && !prevFlag) {
            (_setup.blocksize1 - _setup.blocksize0) / 4
        } else {
            0
        }
        let rightStart = if (blockFlag && !nextFlag) {
            (3 * n - _setup.blocksize0) / 4
        } else {
            windowCenter
        }
        let rightEnd = if (blockFlag && !nextFlag) {
            (3 * n + _setup.blocksize0) / 4
        } else {
            n
        }

        let mapping = _setup.mappings[mode.mapping]
        let channels = _setup.channels

        // ---- floor ----
        let zero = Array<Bool>(channels, repeat: false)
        var ch: Int64 = 0
        while (ch < channels) {
            let mux = mapping.mux[ch]
            let floor = _setup.floors[mapping.submapFloor[mux]]
            zero[ch] = !decodeFloor(br, floor, ch)
            ch += 1
        }

        // ---- 耦合声道重新启用 residue ----
        let reallyZero = Array<Bool>(channels, repeat: false)
        ch = 0
        while (ch < channels) {
            reallyZero[ch] = zero[ch]
            ch += 1
        }
        var cs: Int64 = 0
        while (cs < mapping.couplingSteps) {
            let mag = mapping.couplingMag[cs]
            let angle = mapping.couplingAngle[cs]
            if (!zero[mag] || !zero[angle]) {
                zero[mag] = false
                zero[angle] = false
            }
            cs += 1
        }

        // ---- residue（按 submap 分组）----
        var submap: Int64 = 0
        while (submap < mapping.submaps) {
            let buffers = ArrayList<Array<Float32>>()
            let flags = ArrayList<Bool>()
            ch = 0
            while (ch < channels) {
                if (mapping.mux[ch] == submap) {
                    buffers.add(_spectra[ch])
                    flags.add(zero[ch])
                }
                ch += 1
            }
            if (buffers.size > 0) {
                let residueIndex = mapping.submapResidue[submap]
                let residue = _setup.residues[residueIndex]
                decodeResidue(
                    br,
                    residue,
                    _setup.codebooks,
                    buffers.toArray(),
                    n2,
                    flags.toArray()
                )
            }
            submap += 1
        }

        // ---- 反耦合（必须逆序）----
        var ci = mapping.couplingSteps - 1
        while (ci >= 0) {
            let mag = mapping.couplingMag[ci]
            let angle = mapping.couplingAngle[ci]
            let m = _spectra[mag]
            let a = _spectra[angle]
            var j: Int64 = 0
            while (j < n2) {
                let mv = m[j]
                let av = a[j]
                var m2: Float32
                var a2: Float32
                if (mv > 0.0) {
                    if (av > 0.0) {
                        m2 = mv
                        a2 = mv - av
                    } else {
                        a2 = mv
                        m2 = mv + av
                    }
                } else {
                    if (av > 0.0) {
                        m2 = mv
                        a2 = mv + av
                    } else {
                        a2 = mv
                        m2 = mv - av
                    }
                }
                m[j] = m2
                a[j] = a2
                j += 1
            }
            ci -= 1
        }

        // ---- floor 曲线乘到 residue 上 ----
        ch = 0
        while (ch < channels) {
            let mux = mapping.mux[ch]
            let floor = _setup.floors[mapping.submapFloor[mux]]
            if (reallyZero[ch]) {
                var j: Int64 = 0
                while (j < n2) {
                    _spectra[ch][j] = 0.0
                    j += 1
                }
            } else {
                applyFloor(floor, _spectra[ch], _finalY[ch], n2)
            }
            ch += 1
        }

        // ---- IMDCT ----
        ch = 0
        let blockType = if (blockFlag) {
            1
        } else {
            0
        }
        while (ch < channels) {
            _mdct.inverse(_spectra[ch], n, blockType)
            ch += 1
        }

        // ---- 重叠相加 + 保存下一包所需的尾部 ----
        let overlap = _prevOverlap
        if (overlap > 0) {
            let w = windowForOverlap(overlap)
            ch = 0
            while (ch < channels) {
                let buf = _spectra[ch]
                let prev = _prevWindows[ch]
                var j: Int64 = 0
                while (j < overlap) {
                    buf[leftStart + j] = buf[leftStart + j] * w[j] + prev[j] * w[overlap - 1 - j]
                    j += 1
                }
                ch += 1
            }
        }

        let newOverlap = rightEnd - rightStart
        ch = 0
        while (ch < channels) {
            let buf = _spectra[ch]
            let prev = _prevWindows[ch]
            var j: Int64 = 0
            while (j < newOverlap) {
                prev[j] = buf[rightStart + j]
                j += 1
            }
            ch += 1
        }
        _prevOverlap = newOverlap

        if (_firstPacket) {
            _firstPacket = false
            _discardDeferred = n - rightEnd
            return None
        }

        var outStart = leftStart
        if (_discardDeferred > 0) {
            let available = rightStart - outStart
            if (_discardDeferred >= available) {
                _discardDeferred -= available
                outStart = rightStart
            } else {
                outStart += _discardDeferred
                _discardDeferred = 0
            }
        }
        if (outStart >= rightStart) {
            return None
        }

        let frames = rightStart - outStart
        let samples = Array<Float32>(frames * channels, repeat: 0.0)
        var i: Int64 = 0
        while (i < frames) {
            ch = 0
            while (ch < channels) {
                samples[i * channels + ch] = _spectra[ch][outStart + i]
                ch += 1
            }
            i += 1
        }
        VorbisPcmChunk(frames, samples)
    }

    /// 取长度为 `2*overlap` 的块窗前半段（overlap 等于短块或长块的一半）。
    private func windowForOverlap(overlap: Int64): Array<Float32> {
        if (overlap * 2 == _setup.blocksize0) {
            _mdct.window(0)
        } else if (overlap * 2 == _setup.blocksize1) {
            _mdct.window(1)
        } else {
            throw CorruptedFileException("Vorbis 重叠窗口长度非法：${overlap * 2}")
        }
    }

    // ------------------------------------------------------------------
    // floor1 包解码
    // ------------------------------------------------------------------

    private func decodeFloor(br: VorbisBitReader, floor: VorbisFloor1, ch: Int64): Bool {
        if (br.getBits(1) == 0) {
            return false
        }
        let range = vorbisFloor1Range(floor.multiplier)
        let bits = vorbisIlog(range) - 1
        let finalY = _finalY[ch]
        let step2 = _step2[ch]

        finalY[0] = br.getBits(bits)
        finalY[1] = br.getBits(bits)
        if (br.isEop()) {
            return false
        }

        var offset: Int64 = 2
        var part: Int64 = 0
        while (part < floor.partitions) {
            let cls = floor.partitionClasses[part]
            let cdim = floor.classDimensions[cls]
            let cbits = floor.classSubclasses[cls]
            let csub = (Int64(1) << cbits) - 1
            var cval: Int64 = 0
            if (cbits > 0) {
                let master = floor.classMasterbooks[cls]
                if (master < 0) {
                    return false
                }
                cval = _setup.codebooks[master].decodeSymbol(br)
                if (cval < 0) {
                    return false
                }
            }
            var k: Int64 = 0
            while (k < cdim) {
                let book = floor.subclassBooks[cls][cval & csub]
                cval >>= cbits
                if (book >= 0) {
                    let value = _setup.codebooks[book].decodeSymbol(br)
                    if (value < 0) {
                        return false
                    }
                    finalY[offset] = value
                } else {
                    finalY[offset] = 0
                }
                offset += 1
                k += 1
            }
            part += 1
        }
        if (br.isEop()) {
            return false
        }

        step2[0] = true
        step2[1] = true
        var j: Int64 = 2
        while (j < floor.values) {
            let low = floor.neighborLow[j]
            let high = floor.neighborHigh[j]
            let pred = predictPoint(floor.xList[j], floor.xList[low], floor.xList[high], finalY[low], finalY[high])
            let value = finalY[j]
            let highroom = range - pred
            let lowroom = pred
            let room = if (highroom < lowroom) {
                highroom * 2
            } else {
                lowroom * 2
            }
            if (value != 0) {
                step2[low] = true
                step2[high] = true
                step2[j] = true
                if (value >= room) {
                    if (highroom > lowroom) {
                        finalY[j] = value - lowroom + pred
                    } else {
                        finalY[j] = pred - value + highroom - 1
                    }
                } else {
                    if ((value & 1) != 0) {
                        finalY[j] = pred - ((value + 1) >> 1)
                    } else {
                        finalY[j] = pred + (value >> 1)
                    }
                }
            } else {
                step2[j] = false
                finalY[j] = pred
            }
            j += 1
        }

        // 延迟 floor：step2_flag 为 0 的点不参与曲线绘制，用 -1 标记。
        j = 2
        while (j < floor.values) {
            if (!step2[j]) {
                finalY[j] = -1
            }
            j += 1
        }
        true
    }

    private func predictPoint(x: Int64, x0: Int64, x1: Int64, y0: Int64, y1: Int64): Int64 {
        let dy = y1 - y0
        let adx = x1 - x0
        if (adx == 0) {
            return y0
        }
        var ady = dy
        if (ady < 0) {
            ady = -ady
        }
        let err = ady * (x - x0)
        let off = err / adx
        if (dy < 0) {
            y0 - off
        } else {
            y0 + off
        }
    }

    /// 把 floor 曲线乘到频域缓冲上（residue 已解码、反耦合已完成）。
    private func applyFloor(floor: VorbisFloor1, target: Array<Float32>, finalY: Array<Int64>, n2: Int64): Unit {
        var lx: Int64 = 0
        var ly = finalY[0] * floor.multiplier
        var q: Int64 = 1
        while (q < floor.values) {
            let j = floor.sortedOrder[q]
            if (finalY[j] >= 0) {
                let hy = finalY[j] * floor.multiplier
                let hx = floor.xList[j]
                if (lx != hx) {
                    drawLine(target, lx, ly, hx, hy, n2)
                }
                lx = hx
                ly = hy
            }
            q += 1
        }
        if (lx < n2) {
            let factor = inverseDb(ly)
            var j = lx
            while (j < n2) {
                target[j] *= factor
                j += 1
            }
        }
    }

    /// 按整数 Bresenham 画 floor 线，并把 inverse-dB 增益乘到目标上。
    private func drawLine(
        output: Array<Float32>,
        x0: Int64,
        y0: Int64,
        x1: Int64,
        y1: Int64,
        n: Int64
    ): Unit {
        let dy = y1 - y0
        var adx = x1 - x0
        if (adx <= 0) {
            return
        }
        var ady = dy
        if (ady < 0) {
            ady = -ady
        }
        let base = dy / adx
        let absBase = if (base < 0) {
            -base
        } else {
            base
        }
        ady -= absBase * adx
        let sy = if (dy < 0) {
            base - 1
        } else {
            base + 1
        }
        var x = x0
        var y = y0
        var err: Int64 = 0
        var xEnd = x1
        if (xEnd > n) {
            xEnd = n
        }
        if (x < xEnd) {
            output[x] *= inverseDb(y)
            x += 1
            while (x < xEnd) {
                err += ady
                if (err >= adx) {
                    err -= adx
                    y += sy
                } else {
                    y += base
                }
                output[x] *= inverseDb(y)
                x += 1
            }
        }
    }
}

// ----------------------------------------------------------------------
// residue 解码
// ----------------------------------------------------------------------

/// 解码一个 submap 的 residue 数据。
///
/// `buffers` 只包含该 submap 的声道（按 mapping 的声道顺序），`n` 是半块大小。
private func decodeResidue(
    br: VorbisBitReader,
    residue: VorbisResidue,
    codebooks: Array<VorbisCodebook>,
    buffers: Array<Array<Float32>>,
    n: Int64,
    doNotDecode: Array<Bool>
): Unit {
    let ch = buffers.size
    if (ch == 0) {
        return
    }
    let classbook = codebooks[residue.classbookIndex]
    let actualSize = if (residue.residueType == 2) {
        n * 2
    } else {
        n
    }
    let begin = vorbisMin(residue.begin, actualSize)
    let end = vorbisMin(residue.end, actualSize)
    let nToRead = end - begin
    if (nToRead <= 0) {
        return
    }
    let partSize = residue.partitionSize
    if (partSize <= 0) {
        return
    }
    let partRead = nToRead / partSize
    if (partRead <= 0) {
        return
    }

    // 要参与解码的缓冲先清零；do-not-decode 的缓冲留给调用方在反耦合后清零。
    var any = false
    var j: Int64 = 0
    while (j < ch) {
        if (!doNotDecode[j]) {
            any = true
            var k: Int64 = 0
            while (k < n) {
                buffers[j][k] = 0.0
                k += 1
            }
        }
        j += 1
    }
    if (!any) {
        return
    }

    if (residue.residueType == 2 && ch != 1) {
        decodeResidueInterleaved(br, residue, codebooks, buffers, n, partSize, partRead, begin, doNotDecode)
    } else {
        decodeResidueChannels(br, residue, codebooks, buffers, partSize, partRead, begin, doNotDecode)
    }
}

/// type 0/1（以及单声道的 type 2）：每个声道独立解。
private func decodeResidueChannels(
    br: VorbisBitReader,
    residue: VorbisResidue,
    codebooks: Array<VorbisCodebook>,
    buffers: Array<Array<Float32>>,
    partSize: Int64,
    partRead: Int64,
    begin: Int64,
    doNotDecode: Array<Bool>
): Unit {
    let ch = buffers.size
    let classbook = codebooks[residue.classbookIndex]
    let classIndex = Array<Array<Int64>>(ch, repeat: Array<Int64>(0, repeat: 0))
    var j: Int64 = 0
    while (j < ch) {
        classIndex[j] = Array<Int64>(partRead, repeat: 0)
        j += 1
    }

    var pass: Int64 = 0
    while (pass < 8) {
        var pcount: Int64 = 0
        if (pass == 0) {
            while (pcount < partRead) {
                var groupEnd = pcount + residue.classwords
                if (groupEnd > partRead) {
                    groupEnd = partRead
                }
                j = 0
                while (j < ch) {
                    if (!doNotDecode[j]) {
                        let q = classbook.decodeSymbol(br)
                        if (q < 0) {
                            return
                        }
                        let row = residue.classdata[q]
                        var i: Int64 = 0
                        while (pcount + i < groupEnd) {
                            classIndex[j][pcount + i] = row[i]
                            i += 1
                        }
                    }
                    j += 1
                }
                var i: Int64 = 0
                while (i < residue.classwords && pcount < partRead) {
                    j = 0
                    while (j < ch) {
                        if (!doNotDecode[j]) {
                            let c = classIndex[j][pcount]
                            let bookIndex = residue.books[c][pass]
                            if (bookIndex >= 0) {
                                let offset = begin + pcount * partSize
                                let book = codebooks[bookIndex]
                                if (!decodePartition(br, book, buffers[j], offset, partSize, residue.residueType)) {
                                    return
                                }
                            }
                        }
                        j += 1
                    }
                    pcount += 1
                    i += 1
                }
            }
        } else {
            while (pcount < partRead) {
                j = 0
                while (j < ch) {
                    if (!doNotDecode[j]) {
                        let c = classIndex[j][pcount]
                        let bookIndex = residue.books[c][pass]
                        if (bookIndex >= 0) {
                            let offset = begin + pcount * partSize
                            let book = codebooks[bookIndex]
                            if (!decodePartition(br, book, buffers[j], offset, partSize, residue.residueType)) {
                                return
                            }
                        }
                    }
                    j += 1
                }
                pcount += 1
            }
        }
        pass += 1
    }
}

/// type 2 且多声道：先把各声道交织成一条虚拟向量，再按 type 1 解码。
private func decodeResidueInterleaved(
    br: VorbisBitReader,
    residue: VorbisResidue,
    codebooks: Array<VorbisCodebook>,
    buffers: Array<Array<Float32>>,
    n: Int64,
    partSize: Int64,
    partRead: Int64,
    begin: Int64,
    doNotDecode: Array<Bool>
): Unit {
    let ch = buffers.size
    let classbook = codebooks[residue.classbookIndex]
    let classIndex = Array<Int64>(partRead, repeat: 0)

    var pass: Int64 = 0
    while (pass < 8) {
        var pcount: Int64 = 0
        while (pcount < partRead) {
            if (pass == 0) {
                let q = classbook.decodeSymbol(br)
                if (q < 0) {
                    return
                }
                let row = residue.classdata[q]
                var i: Int64 = 0
                while (i < residue.classwords && pcount < partRead) {
                    let c = row[i]
                    classIndex[pcount] = c
                    let bookIndex = residue.books[c][pass]
                    if (bookIndex >= 0) {
                        let z = begin + pcount * partSize
                        let book = codebooks[bookIndex]
                        if (!decodeInterleavedPartition(br, book, buffers, n, z, partSize, doNotDecode)) {
                            return
                        }
                    }
                    pcount += 1
                    i += 1
                }
            } else {
                let c = classIndex[pcount]
                let bookIndex = residue.books[c][pass]
                if (bookIndex >= 0) {
                    let z = begin + pcount * partSize
                    let book = codebooks[bookIndex]
                    if (!decodeInterleavedPartition(br, book, buffers, n, z, partSize, doNotDecode)) {
                        return
                    }
                }
                pcount += 1
            }
        }
        pass += 1
    }
}

/// 解一个 type 0/1 分区。返回 false 表示包尾（正常结束，不再继续）。
private func decodePartition(
    br: VorbisBitReader,
    book: VorbisCodebook,
    target: Array<Float32>,
    offset: Int64,
    partSize: Int64,
    residueType: Int64
): Bool {
    if (residueType == 0) {
        // 规范 8.6.3：step = n / dimensions，第 i 条向量的第 j 个分量
        // 写到 v[offset + i + j*step]。
        let step = partSize / book.dimensions
        if (step <= 0) {
            return true
        }
        var k: Int64 = 0
        while (k < step) {
            if (!book.decodeStep(br, target, offset + k, book.dimensions, step)) {
                return false
            }
            k += 1
        }
    } else {
        // 规范 8.6.4：顺序写满分区；尾部分区只取剩余长度。
        var k: Int64 = 0
        while (k < partSize) {
            var len = partSize - k
            if (len > book.dimensions) {
                len = book.dimensions
            }
            if (!book.decodeVector(br, target, offset + k, len)) {
                return false
            }
            k += book.dimensions
        }
    }
    true
}

/// 解一个 type 2 分区中的交织段。
private func decodeInterleavedPartition(
    br: VorbisBitReader,
    book: VorbisCodebook,
    buffers: Array<Array<Float32>>,
    n: Int64,
    z: Int64,
    total: Int64,
    doNotDecode: Array<Bool>
): Bool {
    let ch = buffers.size
    var cInter = if (ch == 2) {
        z & 1
    } else {
        z % ch
    }
    var pInter = if (ch == 2) {
        z >> 1
    } else {
        z / ch
    }
    var remaining = total
    let totalInterleaved = n * ch

    while (remaining > 0) {
        let symbol = book.decodeSymbol(br)
        if (symbol < 0) {
            return false
        }
        var effective = book.dimensions
        let pos = pInter * ch + cInter
        let available = totalInterleaved - pos
        if (effective > available) {
            effective = available
        }
        if (effective > remaining) {
            effective = remaining
        }
        if (effective <= 0) {
            return false
        }

        let base = symbol * book.dimensions
        if (book.sequenceP) {
            var last: Float32 = 0.0
            var i: Int64 = 0
            while (i < effective) {
                let value = book.multiplicands[base + i] + last
                if (!doNotDecode[cInter]) {
                    buffers[cInter][pInter] += value
                }
                last = value
                cInter += 1
                if (cInter >= ch) {
                    cInter = 0
                    pInter += 1
                }
                i += 1
            }
        } else {
            var i: Int64 = 0
            while (i < effective) {
                if (!doNotDecode[cInter]) {
                    buffers[cInter][pInter] += book.multiplicands[base + i]
                }
                cInter += 1
                if (cInter >= ch) {
                    cInter = 0
                    pInter += 1
                }
                i += 1
            }
        }
        remaining -= effective
    }
    true
}

// ----------------------------------------------------------------------
// 小工具
// ----------------------------------------------------------------------

private func vorbisMin(a: Int64, b: Int64): Int64 {
    if (a < b) {
        a
    } else {
        b
    }
}

private func vorbisFloor1Range(multiplier: Int64): Int64 {
    if (multiplier == 1) {
        256
    } else if (multiplier == 2) {
        128
    } else if (multiplier == 3) {
        86
    } else {
        64
    }
}

/// floor1 的 inverse-dB 表：10^(((y & 255) - 255) * 7 / 256)。
/// stb 用 256 项常量表；这里按同一公式现算，避免了 1KB 的抄表。
private func inverseDb(y: Int64): Float32 {
    let index = y & 255
    let exponent = (Float64(index) - 255.0) * 7.0 / 256.0
    Float32(pow(10.0, exponent))
}
