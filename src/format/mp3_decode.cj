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

    /// 解码工作缓冲（side info / 位池主数据 / 频谱 / 标度因子 / 合成输入 / 强度立体声位置）。
    ///
    /// 【为什么放在解码器状态里，而不是每帧新建】
    ///   它是**纯工作缓冲**：一帧内必被覆盖或显式复位（`grbuf.fill(0.0)`、`istPos` 每声道清零、
    ///   `bs` 由 `bitsInit` 重设），**不含跨帧状态**（跨帧状态是上面那几个字段）。
    ///   原先每帧 `Mp3Scratch()` 会重建 `maindata`(2815 B) + `grbuf`(1152×8 B) + `syn`(2112×8 B)
    ///   + `scf` + `grInfo`(4 个对象) + `istPos` —— 实测"每帧分配与准备"占墙钟约 46%，
    ///   见 docs/decode-deviation-localization-evaluation.md 性能节的优化前后对照。
    var scratch: Mp3Scratch

    public init() {
        mdctOverlap = Array<Array<Float64>>(2, {_: Int64 => Array<Float64>(9 * 32, repeat: 0.0)})
        qmfState = Array<Float64>(15 * 2 * 32, repeat: 0.0)
        reserv = 0
        freeFormatBytes = 0
        header = Array<UInt8>(4, repeat: 0)
        reservBuf = Array<UInt8>(511, repeat: 0)
        scratch = Mp3Scratch()
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
    /// 频谱链内部拆分（`-O2` 后频谱链占 67~69%，不切开就不知道该打哪一段）：
    /// `huffNs` = `l3Huffman`（码表取数 + 码字解析 + linbits 逃逸 + 反量化）；
    /// `transNs` = 变换链（抗混叠 + IMDCT + 符号翻转；短块的重排并入 decodeNs 不减除）。
    var huffNs: Int64 = 0
    var transNs: Int64 = 0
    /// 合成段内部拆分（合成占整帧 40.8%，但内部构成不能靠微基准折算 ——
    /// 实测微基准高估整段 2.5 倍，故必须像频谱链那样加子段计时）：
    /// `dctNs` = `dctII` 循环；`loopNs` = `synth` 主循环；
    /// `fixNs` = 每 granule 固定开销（`pcmBuffer` 分配 + 状态拷入 + 拷出与状态回写，三段累计）。
    var dctNs: Int64 = 0
    var loopNs: Int64 = 0
    var fixNs: Int64 = 0
    /// 旁信息 + 位池装配（`l3ReadSideInfo` + `l3RestoreReservoir` + `l3SaveReservoir`）。
    /// 单列出来是为了**归因**：两阶段（频谱链 + 合成）之外还有一笔可观的墙钟差额，
    /// 这笔差额到底落在这里、还是落在门面/调用方，只能靠量。
    var sideNs: Int64 = 0
    /// **整帧调用**（`mp3DecodeFrame` 整函数，由流层 `nextPacket` 计时）。
    /// 它与上面三段的关系是决定性的：整帧 ≈ 三段之和 ⇒ 残差在流层的循环里；
    /// 整帧 ≈ 墙钟 ⇒ 残差在 `mp3DecodeFrame` 内、但不在三段里。
    var frameNs: Int64 = 0
    var lastDecodeNs: Int64 = 0
    var lastSynthNs: Int64 = 0
    var lastSideNs: Int64 = 0
    var lastFrameNs: Int64 = 0
    var lastHuffNs: Int64 = 0
    var lastTransNs: Int64 = 0
    var lastDctNs: Int64 = 0
    var lastLoopNs: Int64 = 0
    var lastFixNs: Int64 = 0
}

protected let MP3_PHASE = Mp3PhaseStats()

/// 每帧调用一次：首次调用时探测 sentinel，之后只做一次布尔判断。
protected func mp3PhaseTick(): Unit {
    if (!MP3_PHASE.checked) {
        MP3_PHASE.checked = true
        MP3_PHASE.enabled = exists(Path("testdata/diag/phase_timing.on"))
        if (MP3_PHASE.enabled) {
            println("PHASE 分段计时已开启（每 10000 帧一行，单位 us）")
        }
    }
}

/// 每帧一次：累计帧数并按固定间隔打印**区间增量**（打印累计值会被误读成瞬时值）。
protected func mp3PhaseFrameDone(): Unit {
    if (!MP3_PHASE.enabled) {
        return
    }
    MP3_PHASE.frames += 1
    // 【为什么是 10000 而不是 100】100 帧的间隔会把"热身段"和稳态混在同一张表里
    //   （实测同一构建的前几个区间能比稳态高 30%+），据此算占比会偏。10000 帧
    //   （约 4.3 分钟音频）才够一次纯稳态采样；代价是 20 秒的合成素材不再打印，
    //   要看得用真实歌曲跑（约 11700 个 MPEG 帧/首，即一首一次）。
    if (MP3_PHASE.frames % 10000 != 0) {
        return
    }
    let dDec = MP3_PHASE.decodeNs - MP3_PHASE.lastDecodeNs
    let dSyn = MP3_PHASE.synthNs - MP3_PHASE.lastSynthNs
    let dSide = MP3_PHASE.sideNs - MP3_PHASE.lastSideNs
    let dFrame = MP3_PHASE.frameNs - MP3_PHASE.lastFrameNs
    let dHuff = MP3_PHASE.huffNs - MP3_PHASE.lastHuffNs
    let dTrans = MP3_PHASE.transNs - MP3_PHASE.lastTransNs
    let dDct = MP3_PHASE.dctNs - MP3_PHASE.lastDctNs
    let dLoop = MP3_PHASE.loopNs - MP3_PHASE.lastLoopNs
    let dFix = MP3_PHASE.fixNs - MP3_PHASE.lastFixNs
    MP3_PHASE.lastDecodeNs = MP3_PHASE.decodeNs
    MP3_PHASE.lastSynthNs = MP3_PHASE.synthNs
    MP3_PHASE.lastSideNs = MP3_PHASE.sideNs
    MP3_PHASE.lastFrameNs = MP3_PHASE.frameNs
    MP3_PHASE.lastHuffNs = MP3_PHASE.huffNs
    MP3_PHASE.lastTransNs = MP3_PHASE.transNs
    MP3_PHASE.lastDctNs = MP3_PHASE.dctNs
    MP3_PHASE.lastLoopNs = MP3_PHASE.loopNs
    MP3_PHASE.lastFixNs = MP3_PHASE.fixNs
    let total = dDec + dSyn + dSide
    let pct = if (total <= 0) {
        0.0
    } else {
        100.0 * Float64(dDec) / Float64(total)
    }
    // 微秒显示：`-O2` 下每 100 帧只有几毫秒，整数毫秒会把拆分全压成 0。
    // 合成侧三段（dct / 主循环 / 固定开销）之和应与 dSyn 基本相等 —— 差值是三层计时点之间的零头。
    println(
        "PHASE ${MP3_PHASE.frames} 帧：频谱链 ${dDec / 1000} us（其中哈夫曼+反量化 ${dHuff / 1000} us、" +
            "变换链 ${dTrans / 1000} us）、合成 ${dSyn / 1000} us（其中 dctII ${dDct / 1000} us、" +
            "主循环 ${dLoop / 1000} us、固定开销 ${dFix / 1000} us）、旁信息+位池 ${dSide / 1000} us、" +
            "三段合计 ${total / 1000} us、**整帧调用 ${dFrame / 1000} us**" + "（频谱链占 ${pct}%）")
}

/// 子段计时的取时/累加 helper（放这里是因为本文件已 `import std.time.*`；
/// `mp3_transform.cj` 与它同包，直接调用即可，不必再引入时间库）。
/// 开关判断放在 helper 内部 ⇒ 哨兵未开时调用点只有一次函数调用，零账目开销。
///
/// 【为什么返回相对基准的纳秒而不是 `MonoTime`】`toNanoseconds()` 是 `Duration` 的方法，
/// 不是 `MonoTime` 的（实测编译错误：'toNanoseconds' is not a member of struct 'MonoTime'）。
/// 取一个模块级基准时刻、返回差值，调用方就只做 `Int64` 相减，无需 import 时间库。
private let MP3_PHASE_BASE = MonoTime.now()

protected func mp3PhaseNow(): Int64 {
    (MonoTime.now() - MP3_PHASE_BASE).toNanoseconds()
}

protected func mp3PhaseAddHuff(delta: Int64): Unit {
    if (MP3_PHASE.enabled) {
        MP3_PHASE.huffNs += delta
    }
}

protected func mp3PhaseAddTrans(delta: Int64): Unit {
    if (MP3_PHASE.enabled) {
        MP3_PHASE.transNs += delta
    }
}

protected func mp3PhaseAddDct(delta: Int64): Unit {
    if (MP3_PHASE.enabled) {
        MP3_PHASE.dctNs += delta
    }
}

protected func mp3PhaseAddLoop(delta: Int64): Unit {
    if (MP3_PHASE.enabled) {
        MP3_PHASE.loopNs += delta
    }
}

protected func mp3PhaseAddFix(delta: Int64): Unit {
    if (MP3_PHASE.enabled) {
        MP3_PHASE.fixNs += delta
    }
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
        // 工作缓冲随解码器实例存活，跨文件/seek 复用会带入上一段流的残留：
        // 其中 `grbuf` 与 `istPos` 是"必须为 0 才正确"的字段（正常路径每 granule 会复位它们，
        // 但"重新开始"这条路径不应依赖"下面一定会先写"）。
        dec.scratch.istPos[ch].fill(UInt8(0))
    }

    dec.qmfState.fill(0.0)
    dec.scratch.grbuf.fill(0.0)
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
        let scratch = dec.scratch
        let tSide0 = MonoTime.now()
        let mainDataBegin = l3ReadSideInfo(bsFrame, scratch.grInfo, hdr)
        if (mainDataBegin < 0 || bsFrame.pos > bsFrame.limit) {
            mp3DecInit(dec);
            return 0
        }
        let ok = l3RestoreReservoir(dec, bsFrame, scratch, mainDataBegin)
        let tSide1 = MonoTime.now()
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
                if (MP3_PHASE.enabled) {
                    MP3_PHASE.decodeNs += (tDec1 - tDec0).toNanoseconds()
                    MP3_PHASE.synthNs += (MonoTime.now() - tDec1).toNanoseconds()
                }
                igr = igr + 1
            }
            mp3PhaseFrameDone()
        }
        let tSave0 = MonoTime.now()
        l3SaveReservoir(dec, scratch)
        if (MP3_PHASE.enabled) {
            MP3_PHASE.sideNs += (tSide1 - tSide0).toNanoseconds() + (MonoTime.now() - tSave0).toNanoseconds()
        }
        return ok * hdrFrameSamples(dec.header)
    } else {
        let scratch = dec.scratch
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
