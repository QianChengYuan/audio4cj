package audio4cj.format

import std.core.*
import std.collection.*
import std.fs.*
import std.time.*

/* ============================================================================
 * MP3 解码内核（入口）
 *
 * 【这一族文件是怎么来的：一次"按职责"的拆分】
 *   内核最初是**一个文件**（约 2900 行）—— 它是从单一 C 翻译单元移植来的，
 *   把"C 的单文件"形态一并带了过来，体量约等于整个 FLAC 解码族（10 个文件）。
 *   现按**职责**拆为同包的一组文件，本文件只留**内核入口**：
 *
 *     mp3_decode.cj    本文件：Mp3Dec 状态、Mp3FrameInfo、init/reset 与主解码函数
 *     mp3_header.cj    帧头字段访问 / 合法性判定 / 帧尺寸与采样率计算
 *     mp3_bits.cj      位读取（Mp3Bits + 两级位缓存）
 *     mp3_layer12.cj   Layer I / II（子带分配、标度因子、反量化）
 *     mp3_layer3.cj    Layer III side info 与标度因子读取
 *     mp3_huffman.cj   标度因子解码、反量化（pow43 / 2^q）、Huffman 解码
 *     mp3_stereo.cj    联合立体声工具（MS / 强度）
 *     mp3_transform.cj 重排、抗混叠、IMDCT（长/短/混合块）、位池、Layer III 组装
 *     mp3_synth.cj     DCT-II 与多相合成滤波器组
 *     mp3_anchor.cj    Xing/Info/VBRI 锚点与"连续帧"校验（findFrame）
 *
 * 【拆分是纯代码搬移，且已用基准核过代价】
 *   搬移不改一行逻辑；判据是原有的 228 条用例（含与 ffmpeg 的 golden 包络比对）
 *   全绿。性能用 `cjpm bench --filter BenchDecode.mp3DecodeAll` 实测对照：
 *     单文件（拆分前）        229.9 ms
 *     拆分为本族 10 个文件    229.7 ms
 *   即**拆分本身没有可观测的代价**（差异在 ±0.4% 的测量误差内）。
 *
 * 【一处被实测否定的"优化"，留档以免重蹈】
 *   拆分时曾顺手把 23 张系数表从函数体内**提升到模块级**（设想：省掉每次调用
 *   的重新分配）。实测结果相反：
 *     表留在函数体内          231.3 ms
 *     表提升到模块级          238.2 ms（**+3.0%**）
 *   原因判断：函数内的常量数组可被编译器当作编译期常量优化，且**不存在别名**；
 *   提升到模块级后，热循环（Huffman 查表、合成滤波）里每次访问都要多一层全局
 *   取值，且编译器不能再假设它与其他全局缓冲互不别名。既然收益为负，
 *   **已回退**：这 23 张表仍留在各自的函数体内（只有 `G_EXPFRAC` / `G_POW43`
 *   两张原本就在模块级的表维持原样）。这条记下来，是因为"提升常量表"看起来
 *   总是对的 —— 只有测过才知道不是。
 *
 * 【可见性为什么是 protected，而不是 private】仓颉的顶层 `private` 是
 *   **文件级**的：拆分后跨文件使用的符号必须放宽。这里放宽到 `protected`
 *   （模块内可见，仍**不是** `public`，未进入对外 API），与本包既有惯例一致
 *   （`BitReader`、`FlacFrame`、`parseFrameHeader` 都是这个级别）；
 *   仅在本文件内使用的符号仍保持 `private`。
 *   解码器状态仍是**每实例独立**：`Mp3Dec` 持有全部可变状态，
 *   模块级的 `let` 表全部只读，因此多线程各持一个 Mp3Dec 仍然安全。
 * ========================================================================== */
protected let MP3_MAX_SAMPLES_PER_FRAME: Int64 = 1152 * 2

protected class Mp3FrameInfo {
    /// 本帧在输入缓冲中占用的字节数（含此前被跳过的垃圾字节）。
    protected var frameBytes: Int64 = 0

    /// 声道数（1 或 2）。
    protected var channels: Int64 = 0

    /// 采样率（Hz）。
    protected var hz: Int64 = 0

    /// MPEG 层号（1 / 2 / 3）。
    protected var layer: Int64 = 0

    /// 比特率（kbps）。
    protected var bitrateKbps: Int64 = 0

    public init() {}
}

protected class Mp3Dec {
    var mdctOverlap: Array<Array<Float64>>
    var qmfState: Array<Float64>
    var reserv: Int64
    var freeFormatBytes: Int64
    var header: Array<UInt8>
    var reservBuf: Array<UInt8>

    public init() {
        mdctOverlap = Array<Array<Float64>>(2, {_: Int64 => Array<Float64>(9 * 32, repeat: 0.0)})
        qmfState = Array<Float64>(15 * 2 * 32, repeat: 0.0)
        reserv = 0
        freeFormatBytes = 0
        header = Array<UInt8>(4, repeat: 0)
        reservBuf = Array<UInt8>(511, repeat: 0)
    }
}

/// 分段计时（诊断用）：受 `testdata/diag/phase_timing.on` 这个 sentinel 文件守卫。
///
/// 【为什么用 sentinel 文件而不是环境变量】
///   仓库既有的诊断开关就是这个约定（`src/test/diag_dump_test.cj` 由 `testdata/diag/dump.list`
///   触发），导入面与"默认关闭"的保证完全一致；且 `testdata/diag/` 已在 .gitignore 里，
///   sentinel 不会被误提交。
///
/// 【为什么用顶层 `let` + 类字段】
///   仓颉不允许顶层 `var`，但允许顶层 `let` 绑定一个**类实例**、再改它的字段 ——
///   这是表达"进程级统计"的常规做法，不必把计数器塞进公开 API。
protected class Mp3PhaseStats {
    var checked: Bool = false
    var enabled: Bool = false
    var frames: Int64 = 0
    var decodeNs: Int64 = 0
    var synthNs: Int64 = 0
    var lastDecodeNs: Int64 = 0
    var lastSynthNs: Int64 = 0
}

protected let mp3Phase = Mp3PhaseStats()

/// 每帧调用一次：首次调用时探测 sentinel，之后只做一次布尔判断。
protected func mp3PhaseTick(): Unit {
    if (!mp3Phase.checked) {
        mp3Phase.checked = true
        mp3Phase.enabled = exists(Path("testdata/diag/phase_timing.on"))
        if (mp3Phase.enabled) {
            println("PHASE 分段计时已开启（每 100 帧一行，单位 ms）")
        }
    }
}

/// 每帧一次：累计帧数并按固定间隔打印**区间增量**（打印累计值会被误读成瞬时值）。
protected func mp3PhaseFrameDone(): Unit {
    if (!mp3Phase.enabled) {
        return
    }
    mp3Phase.frames += 1
    if (mp3Phase.frames % 100 != 0) {
        return
    }
    let dDec = mp3Phase.decodeNs - mp3Phase.lastDecodeNs
    let dSyn = mp3Phase.synthNs - mp3Phase.lastSynthNs
    mp3Phase.lastDecodeNs = mp3Phase.decodeNs
    mp3Phase.lastSynthNs = mp3Phase.synthNs
    let total = dDec + dSyn
    let pct = if (total <= 0) {
        0.0
    } else {
        100.0 * Float64(dDec) / Float64(total)
    }
    println("PHASE ${mp3Phase.frames} 帧：频谱链 ${dDec / 1000000} ms、" +
        "合成 ${dSyn / 1000000} ms、合计 ${total / 1000000} ms（频谱链占 ${pct}%）")
}

protected func mp3DecInit(dec: Mp3Dec): Unit {
    dec.header[0] = 0
}

protected func mp3DecReset(dec: Mp3Dec): Unit {
    dec.reserv = 0
    dec.freeFormatBytes = 0

    dec.header.fill(0)
    dec.reservBuf.fill(0)

    for (ch in Range<Int64>(0, 2, 1, true, true, false)) {
        dec.mdctOverlap[ch].fill(0.0)
    }

    dec.qmfState.fill(0.0)
}

/// 把解码得到的定标整数样本（int16 量纲）转为库统一的 f32（取值 [-1.0, 1.0]）。
///
/// 【与参照实现的差别】原实现按编译选项输出 Int16（带饱和）；本库统一输出 f32 交错，
/// 因此这里只做 1/32768 的定标 —— 不饱和、不取整，保留全部有效位（这正是 float 解码
/// 路径存在的意义）。后续 `AudioBuffer` 直接承接该值。
protected func scalePcm(sample: Float64): Float32 {
    Float32(sample * (1.0 / 32768.0))
}

// ===== MP3帧解码主函数 =====
protected func mp3DecodeFrame(dec: Mp3Dec, mp3: Array<UInt8>, mp3Bytes: Int64, pcm: Array<Float32>, info: Mp3FrameInfo): Int64 {
    var hdr: Array<UInt8> = []
    mp3PhaseTick()

    var i: Int64 = 0
    var frameSize: Int64 = 0
    if (mp3Bytes > 4 && dec.header[0] == 0xFF && hdrCompare(dec.header, mp3.slice(0, 4))) {
        frameSize = hdrFrameBytes(mp3.slice(0, 4), dec.freeFormatBytes) + hdrPadding(mp3.slice(0, 4))
        if (!(frameSize == mp3Bytes || (frameSize + HDR_SIZE <= mp3Bytes && hdrCompare(mp3.slice(0, 4),
            mp3.slice(frameSize, mp3Bytes - frameSize))))) {
            frameSize = 0
        }
    }
    if (frameSize == 0) {
        mp3DecReset(dec)
        var res = findFrame(mp3, mp3Bytes, dec.freeFormatBytes)
        i = res.offset
        frameSize = res.frameBytes
        dec.freeFormatBytes = res.freeFormatBytes
        if (frameSize == 0 || i + frameSize > mp3Bytes) {
            info.frameBytes = i
            return 0
        }
    }
    hdr = mp3.slice(i, 4)
    dec.header = hdr.clone()
    info.frameBytes = i + frameSize
    if (hdrIsMono(hdr)) {
        info.channels = 1
    } else {
        info.channels = 2
    }
    info.hz = hdrSampleRateHz(hdr)
    info.layer = 4 - hdrGetLayer(hdr)
    info.bitrateKbps = hdrBitrateKbps(hdr)
    if (pcm.size == 0) {
        return hdrFrameSamples(hdr)
    }
    var bsFrame = Mp3Bits()

    bsFrame.buf = mp3.slice(i + HDR_SIZE, frameSize - HDR_SIZE)
    bsFrame.pos = 0
    bsFrame.limit = (frameSize - HDR_SIZE) * 8
    if (hdrIsCrc(hdr)) {
        _ = getBits(bsFrame, 16)
    }
    if (info.layer == 3) {
        var scratch = Mp3Scratch()
        let mainDataBegin = l3ReadSideInfo(bsFrame, scratch.grInfo, hdr)
        if (mainDataBegin < 0 || bsFrame.pos > bsFrame.limit) {
            mp3DecInit(dec);
            return 0
        }
        let ok = l3RestoreReservoir(dec, bsFrame, scratch, mainDataBegin)
        if (ok != 0) {
            var ngr: Int64 = 1
            if (hdrTestMpeg1(hdr)) {
                ngr = 2
            } else {
                ngr = 1
            }
            var igr: Int64 = 0
            while (igr < ngr) {
                var pcmOff = 576 * info.channels * igr

                scratch.grbuf.fill(0.0)
                let tDec0 = MonoTime.now()
                l3Decode(dec, scratch,
                    scratch.grInfo.slice(igr * info.channels, scratch.grInfo.size - (igr * info.channels)),
                    info.channels)
                let tDec1 = MonoTime.now()
                dec.qmfState = synthGranule(dec.qmfState, scratch.grbuf, 18, info.channels,
                    pcm.slice(pcmOff, pcm.size - pcmOff), scratch.syn)
                if (mp3Phase.enabled) {
                    mp3Phase.decodeNs += (tDec1 - tDec0).toNanoseconds()
                    mp3Phase.synthNs += (MonoTime.now() - tDec1).toNanoseconds()
                }
                igr = igr + 1
            }
            mp3PhaseFrameDone()
        }
        l3SaveReservoir(dec, scratch)
        return ok * hdrFrameSamples(dec.header)
    } else {
        var scratch = Mp3Scratch()
        var sci = L12ScaleInfo()
        l12ReadScaleInfo(hdr, bsFrame, sci)
        var iacc: Int64 = 0
        var igr: Int64 = 0
        var pcmLocal = pcm
        while (igr < 3) {
            if (12 == (iacc + l12DequantizeGranule(scratch.grbuf.slice(iacc, scratch.grbuf.size - iacc), bsFrame, sci,
                info.layer | 1))) {
                iacc = 0
                l12ApplyScf384(sci, sci.scf.slice(igr, sci.scf.size - igr), scratch.grbuf)
                dec.qmfState = synthGranule(dec.qmfState, scratch.grbuf, 12, info.channels, pcmLocal, scratch.syn)

                scratch.grbuf.fill(0.0)
                pcmLocal = pcmLocal.slice(384 * info.channels, pcmLocal.size - 384 * info.channels)
            }
            if (bsFrame.pos > bsFrame.limit) {
                mp3DecInit(dec);
                return 0
            }
            igr = igr + 1
        }
        return hdrFrameSamples(dec.header)
    }
}
