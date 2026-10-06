package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 Layer I / II —— 比特分配、标度因子与反量化
 *
 * 【为什么与 Layer III 分开】两者共用容器与帧头，**但数据组织完全不同**：
 *   Layer I/II 是"32 个子带 + 线性量化"（每个子带若干样本），Layer III 走
 *   MDCT 频域 + Huffman。把两者放一个文件里容易让人以为共用代码路径 ——
 *   事实上从帧头判定之后就没有共用点了（`mp3DecodeFrame` 按层号分派）。
 *
 * 【本文件的三件事】
 *   1. `l12SubbandAllocTable`：读**比特分配**（每个子带分到几位、多少个样本）；
 *   2. `l12ReadScaleInfo` / `l12ReadScalefactors`：读每子带的标度因子索引；
 *   3. `l12DequantizeGranule` + `l12ApplyScf384`：把量化索引还原为浮点样本。
 *
 * 【与 Layer III 相同的取向：表驱动而非浮点幂运算】反量化系数由三组常数与
 *   2 的幂组合而成，用 `buildGDeqL12` **现场构造**（生成比手抄一张 54 项表更不容易
 *   写错）。代价是它在 `l12ReadScalefactors` 里被调用 —— 也就是**每 granule
 *   重建一次**（实测 Layer I/II 在本库素材里占比很小，故先如实记录、不急于优化；
 *   若将来要动，请先按 `bench_decode_test` 的方式量一次再改）。
 *
 * 【本文件只被 Layer I/II 使用】Layer III 的帧不会走到这里。
 * ========================================================================== */

/// Layer I/II 的标度因子与比特分配状态（**跨子带复用**，按最大规模分配）。
///
/// 字段语义（名字沿用参照实现）：
///   · `scf`：标度因子，按 3 组 × 64 子带预留（Layer II 每 frame 三个 granule）；
///   · `totalBands`：本帧的子带总数（随采样率与层号变）；
///   · `stereoBands`：其中属于立体声扩展的子带数（单声道为 0）；
///   · `bitalloc`：每子带的比特分配值（0 = 该子带无数据）；
///   · `scfcod`：每子带的标度因子编码方式 —— **初值 6 是个约定**：
///     0..2 表示"用 2/3/4 位显式传"，3..5 表示"3 的幂次族"，6 表示无标度因子。
protected class L12ScaleInfo {
    var scf: Array<Float64>
    var totalBands: Int64
    var stereoBands: Int64
    var bitalloc: Array<Int64>
    var scfcod: Array<Int64>
    public init() {
        scf = Array<Float64>(3 * 64, repeat: 0.0)
        totalBands = 0
        stereoBands = 0
        bitalloc = Array<Int64>(64, repeat: 0)
        scfcod = Array<Int64>(64, repeat: 6)
    }
}

/// 一个子带的比特分配结果（值类型：每帧产出几十个，按值传递更直接）。
///
/// `tabOffset` 指向该子带的**码表基址**、`codeTabWidth` 是每样本的位数、
/// `bandCount` 是样本数 —— 三者合起来描述"从哪里、按几位、取几个样本"。
private struct L12SubbandAlloc {
    var tabOffset: Int64 = 0
    var codeTabWidth: Int64 = 0
    var bandCount: Int64 = 0
    public init() {}
    init(tabOffset: Int64, codeTabWidth: Int64, bandCount: Int64) {
        this.tabOffset = tabOffset
        this.codeTabWidth = codeTabWidth
        this.bandCount = bandCount
    }
}

/// 构造 Layer I/II 的反量化系数表：`c0/x, c1/x, c2/x`（三组系数 × 18 个 x）。
///
/// 【为什么现场构造而不是写死一张表】这三个常数与 x 的取值（3,7,15,…,65535 以及
/// 3,5,9）来自规范，用循环生成比手抄一张 54 项表更不容易出错；嵌套函数
/// `dqAppend` 让"三项一组"的结构在代码里直接可见。
///
/// 【注意它的调用位置】本函数由 `l12ReadScalefactors` 调用，因此**每 granule 会重建
/// 一次**（含一次 `ArrayList` 追加与 `toArray`）。对 Layer I/II 的素材量而言可接受，
/// 如实记录在此；若要优化，先按 `bench_decode_test` 的方式测出收益再动手。
private func buildGDeqL12(): Array<Float64> {
    let c0: Float64 = 9.53674316e-07
    let c1: Float64 = 7.56931807e-07
    let c2: Float64 = 6.00777173e-07 // cjlint-ignore !G.OTH.02 MP3 标准反量化系数，非敏感信息

    var dq = ArrayList<Float64>()
    func dqAppend(dst: ArrayList<Float64>, x: Float64): Unit {
        dst.add(c0 / x)
        dst.add(c1 / x)
        dst.add(c2 / x)
    }

    let xs: Array<Int64> = [3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535, 3, 5, 9]
    for (v in xs) {
        dqAppend(dq, Float64(v))
    }

    return dq.toArray()
}

/// 生成"每子带的比特分配读法"表：哪些子带共用同一段码表、每样本读几位、多少样本。
///
/// 【为什么要先算这张表】比特分配值不是等长编码：低频子带用宽码、高频用窄码，
/// 且不同采样率/声道模式下的"分组方式"完全不同（单声道一组、立体声按
/// `stereoBands` 成对）。表里每一行对应一段连续子带，避免在主循环里写满条件分支。
/// 具体行内容全部来自规范的定义（不同采样率对应不同行）。
private func l12SubbandAllocTable(hdr: Array<UInt8>, sci: L12ScaleInfo): Array<L12SubbandAlloc> {
    let mode = hdrGetStereoMode(hdr)
    var alloc: Array<L12SubbandAlloc> = []
    var nbands: Int64 = 0
    var stereoBands: Int64 = 0
    if (mode == MODE_MONO) {
        stereoBands = 0
    } else {
        if (mode == MODE_JOINT_STEREO) {
            stereoBands = (hdrGetStereoModeExt(hdr) << 2) + 4
        } else {
            stereoBands = 32
        }
    }
    if (hdrIsLayer1(hdr)) {
        alloc = Array<L12SubbandAlloc>(1, {_: Int64 => L12SubbandAlloc(76, 4, 32)})
        nbands = 32
    } else if (!hdrTestMpeg1(hdr)) {
        alloc = Array<L12SubbandAlloc>(3, {
            i: Int64 => if (i == 0) {
                L12SubbandAlloc(60, 4, 4)
            } else if (i == 1) {
                L12SubbandAlloc(44, 3, 7)
            } else {
                L12SubbandAlloc(44, 2, 19)
            }
        })
        nbands = 30
    } else {
        var sampleRateIdx = hdrGetSampleRate(hdr)
        var kbps = hdrBitrateKbps(hdr)
        if (mode != MODE_MONO) {
            kbps = kbps >> 1
        }
        if (kbps == 0) {
            kbps = 192
        }
        alloc = Array<L12SubbandAlloc>(4, {
            i: Int64 => if (i == 0) {
                L12SubbandAlloc(0, 4, 3)
            } else if (i == 1) {
                L12SubbandAlloc(16, 4, 8)
            } else if (i == 2) {
                L12SubbandAlloc(32, 3, 12)
            } else {
                L12SubbandAlloc(40, 2, 7)
            }
        })
        nbands = 27
        if (kbps < 56) {
            alloc = Array<L12SubbandAlloc>(2, {
                i: Int64 => if (i == 0) {
                    L12SubbandAlloc(44, 4, 2)
                } else {
                    L12SubbandAlloc(44, 3, 10)
                }
            })
            if (sampleRateIdx == 2) {
                nbands = 12
            } else {
                nbands = 8
            }
        } else if (kbps >= 96 && sampleRateIdx != 1) {
            nbands = 30
        }
    }
    sci.totalBands = nbands
    sci.stereoBands = min(stereoBands, nbands)
    return alloc
}

/// 读取每子带的标度因子索引（`scfcod` 决定该子带的索引用什么码表）。
///
/// 输出同时用于反量化：`scf` 的每一项都是一个"码表下标"，配合
/// `l12ApplyScf384` 在实际使用时才转成系数（延迟到需要时才展开，
/// 因为同一个 granule 里同一子带可能被反复引用）。
private func l12ReadScalefactors(bs: Mp3Bits, pba: Array<Int64>, scfcod: Array<Int64>, bands: Int64, scf: Array<Float64>): Unit {
    let gDeq = buildGDeqL12()

    var i: Int64 = 0
    var m: Int64 = 0
    var scfIdx: Int64 = 0
    while (i < bands) {
        var s: Float64 = 0.0
        let ba = pba[i]
        var mask: Int64 = 0
        if (ba != 0) {
            mask = 4 + ((19 >> scfcod[i]) & 3)
        } else {
            mask = 0
        }
        m = 4
        while (m > 0) {
            if ((mask & m) != 0) {
                let b = getBits(bs, 6)
                let idx = ba * 3 - 6 + (b % 3)
                let sh = (1 << 21) >> (b / 3)
                s = gDeq[idx] * Float64(sh)
            }
            scf[scfIdx] = s
            scfIdx = scfIdx + 1
            m = m >> 1
        }
        i = i + 1
    }
}

/// 读一个 Layer I/II granule 的全部标度信息：**比特分配 → 标度因子编码方式 → 标度因子**。
///
/// 三步的顺序不能变，因为后一步依赖前一步：
///   1. 逐子带读比特分配码，查 `gBitallocCodeTab` 得到实际分配值（该表把"码"映射到
///      "位数"，表内容与偏移全部来自规范）；
///   2. 有分配值的子带再读 2 比特的**标度因子编码方式**（Layer I 固定为 2）；
///   3. 按编码方式读标度因子索引。
///
/// 【立体声的特殊处理】`stereoBands` 以内的子带左右各读一份分配值；
/// 以外的地方：立体声（`stereoBands != 0`）**复用左声道的值**，单声道置 0 ——
/// 所以函数末尾还要把"复用出来的右值"清掉，避免它们被后面的反量化当成真实数据。
protected func l12ReadScaleInfo(hdr: Array<UInt8>, bs: Mp3Bits, sci: L12ScaleInfo): Unit {
    let gBitallocCodeTab: Array<Int64> = [
        0,
        17,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        0,
        17,
        18,
        3,
        19,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        16,
        0,
        17,
        18,
        3,
        19,
        4,
        5,
        16,
        0,
        17,
        18,
        16,
        0,
        17,
        18,
        19,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        0,
        17,
        18,
        3,
        19,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        0,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16
    ]
    let subbandAlloc = l12SubbandAllocTable(hdr, sci)

    var i: Int64 = 0
    var k: Int64 = 0
    var baBits: Int64 = 0
    var baCodeTabOffset: Int64 = 0
    var subIdx: Int64 = 0
    while (i < sci.totalBands) {
        if (i == k) {
            k = k + subbandAlloc[subIdx].bandCount
            baBits = subbandAlloc[subIdx].codeTabWidth
            baCodeTabOffset = subbandAlloc[subIdx].tabOffset
            subIdx = subIdx + 1
        }
        let code = getBits(bs, baBits)
        sci.bitalloc[2 * i] = gBitallocCodeTab[baCodeTabOffset + code]
        if (i < sci.stereoBands) {
            let code2 = getBits(bs, baBits)
            sci.bitalloc[2 * i + 1] = gBitallocCodeTab[baCodeTabOffset + code2]
        } else {
            if (sci.stereoBands != 0) {
                sci.bitalloc[2 * i + 1] = sci.bitalloc[2 * i]
            } else {
                sci.bitalloc[2 * i + 1] = 0
            }
        }
        i = i + 1
    }

    // 第 2 步：有分配值的子带读"标度因子编码方式"（2 比特）。Layer I 没有这个字段，
    // 固定为 2；没有分配值的子带记为 6（= 无标度因子），这样第 3 步无需再判空。
    i = 0
    while (i < 2 * sci.totalBands) {
        let ba = sci.bitalloc[i]
        if (ba != 0) {
            if (hdrIsLayer1(hdr)) {
                sci.scfcod[i] = 2
            } else {
                sci.scfcod[i] = getBits(bs, 2)
            }
        } else {
            sci.scfcod[i] = 6
        }
        i = i + 1
    }

    l12ReadScalefactors(bs, sci.bitalloc, sci.scfcod, sci.totalBands * 2, sci.scf)

    // 清掉"复用出来的右声道分配值"（见函数头第 3 点）：它们只是读取时的占位，
    // 若留着，反量化会把同一份数据当成右声道再解一遍。
    i = sci.stereoBands
    while (i < sci.totalBands) {
        sci.bitalloc[2 * i + 1] = 0
        i = i + 1
    }
}

// ===== Layer I/II 反量化 =====
/// 把一个 granule 的量化索引还原成浮点样本（按 4 个"组"处理，返回组数 × 4）。
///
/// 两条分支对应规范的两种量化方式：
///   · `ba < 17`：**线性**（对称偏移）—— `half = 2^(ba-1) - 1` 把无符号码还原成
///     以 0 为中心的有符号值；
///   · `ba >= 17`：**分组打包**（grouping）—— `modv = 2^(ba-17) + 1`（3 / 5 / 9 / 17 …），
///     一组 `groupSize` 个样本整体当作一个混合进制数读进来，再用"取余 → 整除"
///     逐个还原。这是低码率下省比特的手段，也是本函数最绕的一段。
///
/// `choff = 576 / 18` 的翻转是"左右声道交替写"的紧凑写法：每处理完一个声道就把
/// 写入基址在左半区与右半区之间切换，避免为两个声道各写一遍循环。
protected func l12DequantizeGranule(grbuf: Array<Float64>, bs: Mp3Bits, sci: L12ScaleInfo, groupSize: Int64): Int64 {
    var j: Int64 = 0
    var choff: Int64 = 576
    while (j < 4) {
        var dstBase = groupSize * j
        var i: Int64 = 0
        while (i < 2 * sci.totalBands) {
            let ba = sci.bitalloc[i]
            if (ba != 0) {
                // 线性量化：无符号码减去中点 → 以 0 为中心的有符号值
                if (ba < 17) {
                    let half = (1 << (ba - 1)) - 1
                    var k: Int64 = 0
                    while (k < groupSize) {
                        let bits = getBits(bs, ba)
                        grbuf[dstBase + k] = Float64(bits - half)
                        k = k + 1
                    }
                } else {
                    // 分组打包：整组读成一个数，再按基数 modv 逐个"取余"还原
                    let modv = (2 << (ba - 17)) + 1
                    var k: Int64 = 0
                    var c = getBits(bs, modv + 2 - (modv >> 3))
                    while (k < groupSize) {
                        let m = c % modv
                        grbuf[dstBase + k] = Float64(m - modv / 2)
                        c = c / modv
                        k = k + 1
                    }
                }
            }
            dstBase = dstBase + choff
            choff = 18 - choff
            i = i + 1
        }
        j = j + 1
    }
    return groupSize * 4
}

/// 把标度因子乘进频谱，并补齐"立体声扩展带之外"的右声道。
///
/// 两件事：
///   1. **镜像**：`stereoBands` 之外的子带在 Layer II 里是单声道的，解码时只算了一遍，
///      这里把它拷贝到右声道区（偏移 576）—— `copyLen` 就是这些子带的样本总数。
///   2. **定标**：每子带只对前 12 个样本乘标度因子（Layer II 的组大小），
///      余下 6 个是下一组的重叠部分，不属于本 granule。
///
/// 名字里的 384 是"32 子带 × 12 样本"的历史口径（Layer I 的帧样本数），
/// 与函数体的 18/12 并不冲突 —— 保留这个名字是为了与参照实现对应。
protected func l12ApplyScf384(sci: L12ScaleInfo, scf: Array<Float64>, dst: Array<Float64>): Unit {
    let copyLen = (sci.totalBands - sci.stereoBands) * 18

    var t: Int64 = 0
    while (t < copyLen) {
        dst[576 + sci.stereoBands * 18 + t] = dst[sci.stereoBands * 18 + t]
        t = t + 1
    }
    var i: Int64 = 0
    var scfIdx: Int64 = 0
    while (i < sci.totalBands) {
        var k: Int64 = 0
        var base = i * 18
        let s0 = scf[scfIdx + 0]
        let s3 = scf[scfIdx + 3]
        while (k < 12) {
            dst[base + k + 0] = dst[base + k + 0] * s0
            dst[base + k + 576] = dst[base + k + 576] * s3
            k = k + 1
        }
        i = i + 1
        scfIdx = scfIdx + 6
    }
}
