package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 联合立体声（joint stereo）—— Layer III 的 MS 与强度立体声
 *
 * 【这一层在做什么】Layer III 的立体声是**可按频带选择**的：编码器可以在低频存
 *   真正的左右两声（或中/侧两声），在高频只留一份频谱 + 一个"强度位置"，让解码器
 *   按位置重建左右 —— 后者就是强度立体声（intensity stereo，IS）。
 *   因此本文件的核心不是一次矩阵运算，而是**逐标度因子频带决定该带走哪条路径**。
 *
 * 【两条贯穿本文件的记法】
 *   · 左右声道在同一块内存里首尾相接：`grbuf[0..576)` 是左、`[576..1152)` 是右。
 *     每个函数只拿到一个切片，靠固定的 576 偏移访问另一半 —— 看到 `576` 就是这个意思。
 *   · `sfbtab`（标度因子频带长度表）以 **0 结尾**：`while (sfb[i] != 0)` 是遍历全部
 *     频带的惯用法，**不是**哨兵写错，也不是越界。
 *
 * 【哪些是规范给定的、哪些是实现选择】
 *   规范给定：MS 的加减形式、MPEG1 的 7 档强度位置、MPEG2 的 64 档强度位置、
 *   MPEG1 的左右加权表、MPEG2 由位置算 2 的幂、以及 MPEG2 借用
 *   `scalefac_compress` 最低位做范围扩展（见 `mpeg2Sh`）。这些都不是可调参数。
 *   实现选择：把 MS 与 IS 的处理按**频带**穿插在同一次循环里（而不是整帧两遍扫），
 *   这样可以只遍历一次频带表 —— 代价是判断逻辑需要 `maxBand` 这个前置信息。
 *
 * 【覆盖缺口（诚实标注）】强度立体声分支（`istPos[i] < maxPos` 那一支）只有在编码器
 *   确实使用 IS 的码流上才会进入。本库 MP3 素材是否覆盖它**未经核实** ——
 *   也就是说它属于"实现了、但未被 golden 比对证明"的那部分，与 MS 路径不同。
 *   要确认需要在解码时统计该分支的进入次数（未做）。
 * ========================================================================== */

/// MS（中/侧）解码：把 (M, S) 就地还原为 (L, R)。
///
/// `left[0..n)` 是 M，`left[576..576+n)` 是 S；写回后同样的位置就是 L、R。
/// **本函数只做加减**：MS 与强度立体声并存时的附加定标统一放在 `l3StereoProcess`
/// 的分派里（那里的 `s`），所以单独看这里会"少一步"，那是有意的职责划分。
protected func l3MidsideStereo(left: Array<Float64>, n: Int64): Unit {
    var i: Int64 = 0
    let rightOff = 576
    while (i < n) {
        let a = left[i]
        let b = left[rightOff + i]
        left[i] = a + b
        left[rightOff + i] = a - b
        i = i + 1
    }
}

/// 一个频带的强度立体声重建：左 = 共享频谱 × kl，右 = 共享频谱 × kr。
///
/// 强度立体声的"位置"最终就落在这一对乘数上：频谱只有一份（存在左声道的位置），
/// 靠权重分给两边 —— 所以它是有损的（丢失了左右相位/波形差异），这也是"强度"的含义。
private func l3IntensityStereoBand(left: Array<Float64>, n: Int64, kl: Float64, kr: Float64): Unit {
    var i: Int64 = 0
    while (i < n) {
        left[576 + i] = left[i] * kr
        left[i] = left[i] * kl
        i = i + 1
    }
}

/// 找出右声道**仍有实际内容**的最高频带，写入 `maxBand[0..3)`。
///
/// 【为什么需要它】编码器一旦启用强度立体声，就会把右声道从某个频带起**清零**，
/// 只保留强度位置。于是"右声道从哪一带开始全零"就成了识别 IS 带的可靠判据 ——
/// 这正是本函数扫描 `right` 找非零对的目的。
///
/// 【为什么是三个槽】短块把频谱切成 3 个窗口，三个窗口的频带序列各自独立，
/// 所以按 `i % 3` 分开记录。长块只有一条序列，故 `l3IntensityStereo` 事后会把
/// 三个槽统一成同一个值。初值 -1 表示"整段右声道都为零"。
private func l3StereoTopBand(right: Array<Float64>, sfb: Array<Int64>, nbands: Int64, maxBand: Array<Int64>): Unit {
    var i: Int64 = 0
    var k: Int64 = 0
    maxBand[0] = -1
    maxBand[1] = -1
    maxBand[2] = -1
    var off: Int64 = 0
    while (i < nbands) {
        k = 0
        while (k < sfb[i]) {
            if (!(right[off + k] == 0.0 && right[off + k + 1] == 0.0)) {
                maxBand[i % 3] = i
                break
            }
            k = k + 2
        }
        off = off + sfb[i]
        i = i + 1
    }
}

/// 逐频带分派：这一带走**强度立体声**，还是走 **MS**。
///
/// 判据：频带序号 `i` 已**越过** `maxBand`（右声道为零的起点）且强度位置 `ipos`
/// 合法 → 走强度立体声；否则若码流声明了 MS，则该带做 MS 解码。
/// 注意 MS 是**按带**应用的（不是整帧一次），这正是"低频 MS、高频 IS"这类混合
/// 编码能被正确还原的原因。
///
/// 两条编码路径的左右权重来源不同：
///   · MPEG1：7 档强度位置，查规范给定的固定加权表（本函数内的 `gPan`，14 个数
///     即 7 组左右权重）；
///   · MPEG2：64 档，权重由位置**算出**（2 的幂，借 `l3LdexpQ2`），且 `ipos` 的奇偶
///     决定左右互换 —— `mpeg2Sh` 是 `scalefac_compress` 的最低位，用来把 MPEG2 的
///     强度范围再放大一档。
private func l3StereoProcess(left: Array<Float64>, istPos: Array<UInt8>, sfb: Array<Int64>, hdr: Array<UInt8>,
    maxBand: Array<Int64>, mpeg2Sh: Int64): Unit {
    // MPEG1 强度立体声的左右加权表：7 组 (kl, kr)，成对存放。
    // 取值由规范给定（形如 cos/sin 的一对），不是本库调出来的魔法数。
    let gPan: Array<Float64> = [0.0, 1.0, 0.21132487, 0.78867513, 0.36602540, 0.63397460, 0.5, 0.5, 0.63397460,
        0.36602540, 0.78867513, 0.21132487, 1.0, 0.0]

    var i: Int64 = 0
    // 强度位置的合法上限：MPEG1 只定义了 7 档（3 比特字段），MPEG2 有 64 档（6 比特）。
    // 超出该范围的位置按"不是强度带"处理 —— 这也是判别编码器是否真用了 IS 的第二道依据。
    var maxPos: Int64 = 64
    if (hdrTestMpeg1(hdr)) {
        maxPos = 7
    } else {
        maxPos = 64
    }
    var off: Int64 = 0
    // sfb 以 0 结尾（见文件头说明），故这里是"遍历全部频带"而非越界。
    while (sfb[i] != 0) {
        let ipos: Int64 = Int64(istPos[i])
        if (i > maxBand[i % 3] && ipos < maxPos) {
            var kl: Float64 = 1.0
            var kr: Float64 = 1.0
            var s: Float64 = 1.0
            // MS 与强度立体声并存时的附加定标（√2）。这一项是**参照实现的处理方式**，
            // 本库沿用：去掉它会让同时使用 MS 与 IS 的码流出现系统性电平偏差。
            // （本库素材未覆盖该组合，故它同样属于"未被 golden 比对证明"的部分。）
            if (hdrTestMsStereo(hdr)) {
                s = 1.41421356
            } else {
                s = 1.0
            }
            if (hdrTestMpeg1(hdr)) {
                // MPEG1：直接查 7 组加权表
                kl = gPan[2 * ipos]
                kr = gPan[2 * ipos + 1]
            } else {
                // MPEG2：左固定为 1，右取 2 的幂（位置 → 指数），指数再按 mpeg2Sh 扩展一档；
                // ipos 为奇数时左右互换 —— 规范用"奇偶 + 幂次"共同编码 64 档位置。
                kl = 1.0
                kr = l3LdexpQ2(1.0, ((ipos + 1) >> 1) << mpeg2Sh)
                if ((ipos & 1) != 0) {
                    let tmp = kl;
                    kl = kr
                    kr = tmp
                }
            }
            l3IntensityStereoBand(left.slice(off, left.size), sfb[i], kl * s, kr * s)
        } else {
            if (hdrTestMsStereo(hdr)) {
                l3MidsideStereo(left.slice(off, left.size), sfb[i])
            }
        }
        off = off + sfb[i]
        i = i + 1
    }
}

/// 强度立体声的总入口：先定出 IS 的起始频带，再把尾部位置的"补齐"做完，
/// 最后交给 `l3StereoProcess` 逐带分派。
///
/// 【为什么要"补齐尾部位置"】短块把频谱切成 3 个窗口，而 `istPos` 只有一份、
/// 尾部若干频带由 3 个窗口共用。规范对这部分位置的取值有明确规定：若该带超出
/// `maxBand`（即编码器已在此清零）就用**默认位置**（MPEG1 为 3、MPEG2 为 0），
/// 否则沿用上一轮的位置。漏掉这一步，短块最后一个窗口会读到未初始化的位置 ——
/// 这类错误在只有长块的素材上完全看不出来，是本文件最容易被忽略的一处。
protected func l3IntensityStereo(left: Array<Float64>, istPos: Array<UInt8>, grs: Array<Mp3GrInfo>, hdr: Array<UInt8>): Unit {
    let gr = grs[0]
    var maxBand = [0, 0, 0]
    let nSfb = gr.nLongSfb + gr.nShortSfb
    // 只看右声道（切片从 576 开始）——IS 的判据是"右声道是否已被清零"。
    l3StereoTopBand(left.slice(576, left.size), gr.sfbtab, nSfb, maxBand)
    // 长块只有一条频带序列，把三个槽统一为三者中的最大值（等价于"整段只有一条序列"）。
    if (gr.nLongSfb != 0) {
        let m = max(max(maxBand[0], maxBand[1]), maxBand[2])
        maxBand[0] = m
        maxBand[1] = m
        maxBand[2] = m
    }

    var i: Int64 = 0
    // 短块 3 个窗口、长块 1 个 —— 尾部要补齐的位置数正好等于窗口数。
    var maxBlocks: Int64 = 1
    if (gr.nShortSfb != 0) {
        maxBlocks = 3
    } else {
        maxBlocks = 1
    }
    while (i < maxBlocks) {
        var defaultPos: Int64 = 0
        if (hdrTestMpeg1(hdr)) {
            defaultPos = 3
        } else {
            defaultPos = 0
        }
        let itop = nSfb - maxBlocks + i
        let prev = itop - maxBlocks
        if (maxBand[i] >= prev) {
            istPos[itop] = UInt8(defaultPos)
        } else {
            istPos[itop] = istPos[prev]
        }
        i = i + 1
    }
    // MPEG2 的强度范围扩展位借用 `scalefac_compress` 的最低位；立体声时取**第二个**
    // granule 的那一位（单声道没有第二个 granule，取 0）。
    var mpeg2Sh: Int64 = 0
    if (grs.size > 1) {
        mpeg2Sh = (grs[1].scalefacCompress & 1)
    } else {
        mpeg2Sh = 0
    }
    l3StereoProcess(left, istPos, gr.sfbtab, hdr, maxBand, mpeg2Sh)
}
