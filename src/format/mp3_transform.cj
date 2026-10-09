package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 Layer III —— 频谱后处理、IMDCT 与帧内解码编排
 *
 * 【数据流】本文件接着 `mp3_huffman.cj`，把"浮点谱线"变成"时域样本"：
 *   重排（短块）→ 抗混叠 → IMDCT（长/短/混合块）→ 交给 `mp3_synth.cj` 多相合成。
 *   此外还有**位池**的存取，以及一个 granule 的**总编排** `l3Decode`。
 *
 * 【本文件最需要知道的三件事】
 *   1. **短块的频谱在码流里是"窗口优先"排列的**（Huffman 按窗口编码更省比特），
 *      而 IMDCT 要求"子带优先" —— `l3Reorder` 就是补这个差异。漏掉它，短块高频
 *      会出现规律性错误（听感上是"沙沙"声），而且在只有长块的素材上完全看不出来。
 *   2. **IMDCT 是手写蝶形 + 查表**（`l3Dct39` / `l3Idct3` 与窗表），不是调用通用变换。
 *      36 点与 12 点是定长小变换，展开成蝶形更快；代价是代码不像公式那样直观，
 *      故每个变换都单独写了"它在算什么"。
 *   3. **位池（bit reservoir）**：MP3 允许一帧借用前面帧没用完的比特（VBR 的基础）。
 *      `l3SaveReservoir` 存本帧**未消费的尾部**（只保留最后 511 字节），
 *      `l3RestoreReservoir` 把它与本帧负载拼成解码用的主数据流。
 * ========================================================================== */

/// 短块频谱重排："窗口优先" → "子带优先"。
///
/// 码流里短块的频谱按 `[窗口][子带]` 排列（三个窗口各一段），而 IMDCT 需要
/// `[子带][窗口]`。做法是按标度因子频带长度（`sfb`）走：从每个频带的**三个窗口**
/// 各取一个样本凑成一组写到前面（`dstOff += 3`），跳过一个频带后 `srcOff` 要多跨
/// `2 * len`（另外两个窗口的数据留在后面由下一轮取）。
///
/// 重排只在 `scratch` 上进行，最后整段拷回 —— 就地重排会在覆盖前丢掉源数据。
private func l3Reorder(grbuf: Array<Float64>, scratch: Array<Float64>, sfb: Array<Int64>): Unit {
    var srcOff: Int64 = 0
    var dstOff: Int64 = 0
    var len: Int64 = 0
    var sfbIdx: Int64 = 0
    while (true) {
        if (sfbIdx >= sfb.size) {
            break
        }
        len = sfb[sfbIdx]
        if (len == 0) {
            break
        }
        var i: Int64 = 0
        while (i < len) {
            scratch[dstOff + 0] = grbuf[srcOff + 0 * len]
            scratch[dstOff + 1] = grbuf[srcOff + 1 * len]
            scratch[dstOff + 2] = grbuf[srcOff + 2 * len]
            dstOff = dstOff + 3
            srcOff = srcOff + 1
            i = i + 1
        }
        sfbIdx = sfbIdx + 3
        srcOff = srcOff + 2 * len
    }

    scratch.slice(0, dstOff).copyTo(grbuf.slice(0, dstOff))
}

/// 抗混叠：在相邻子带的交界处做一对互补的加权，抵消 IMDCT 旁瓣造成的混叠。
///
/// 系数表（8 对，来自规范）是"两只手"式的：每对系数把相邻子带最靠近边界的样本
/// 混合一次，写回时用 `[0]` 与 `[1]` 两个方向 —— 系数表只存一行，靠这两行读法
/// 同时完成两个方向的加权。这是本函数看起来"读了两次同样的表"的原因。
private func l3Antialias(grbuf: Array<Float64>, nbands: Int64): Unit {
    let gAa: Array<Array<Float64>> = [
        [0.85749293, 0.88174200, 0.94962865, 0.98331459, 0.99551782, 0.99916056, 0.99989920, 0.99999316],
        [0.51449576, 0.47173197, 0.31337745, 0.18191320, 0.09457419, 0.04096558, 0.01419856, 0.00369997] // cjlint-ignore !G.OTH.02 MP3 抗混叠系数，非敏感信息
    ]

    var b: Int64 = 0
    var base: Int64 = 0
    while (b < nbands) {
        var i: Int64 = 0
        while (i < 8) {
            let u = grbuf[base + 18 + i]
            let d = grbuf[base + 17 - i]
            grbuf[base + 18 + i] = u * gAa[0][i] - d * gAa[1][i]
            grbuf[base + 17 - i] = u * gAa[1][i] + d * gAa[0][i]
            i = i + 1
        }
        b = b + 1
        base = base + 18
    }
}

/// 9 点 DCT 的展开蝶形（`l3Imdct36` 的内核）。
///
/// 输入是 18 个样本组成的 9 组，就地写回同样位置。系数表位于函数内（定长常量表），
/// 依据是规范里 36 点 IMDCT 的因式分解：36 点被拆成 9 点 DCT × 若干蝶形 + 窗。
/// 这里不做一般化封装 —— 展开的写法正是它比通用变换快的原因。
private func l3Dct39(y: Array<Float64>): Unit {
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8]
    var t0 = s0 + s6 * 0.5
    s0 = s0 - s6
    var t4 = (s4 + s2) * 0.93969262
    var t2 = (s8 + s2) * 0.76604444
    s6 = (s4 - s8) * 0.17364818
    s4 = s4 + s8 - s2
    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7]
    s2 = s0 - s4 * 0.5
    y[4] = s4 + s0
    var s8n = t0 - t2 + s6
    s0 = t0 - t4 + t2
    s4 = t0 + t4 - s6
    s3 = s3 * 0.86602540
    t0 = (s5 + s1) * 0.98480775
    t4 = (s5 - s7) * 0.34202014
    t2 = (s1 + s7) * 0.64278761
    s1 = (s1 - s5 - s7) * 0.86602540
    var s5n = t0 - s3 - t2
    var s7n = t4 - s3 - t0
    s3 = t4 + s3 - t2
    y[0] = s4 - s7n
    y[1] = s2 + s1
    y[2] = s0 - s3
    y[3] = s8n + s5n
    y[5] = s8n - s5n
    y[6] = s0 + s3
    y[7] = s2 - s1
    y[8] = s4 + s7n
}

/// 长块（或混合块的低频段）的 36 点 IMDCT + 加窗 + 重叠相加。
///
/// 步骤：按 18 个样本一组取输入 → `l3Dct39` 做 9 点 DCT → 蝶形展开成 36 点 →
/// 乘窗（`window` 由调用方按块类型给出）→ 与上一块的 `overlap` 相加后写回，
/// 并把本块尾部存进 `overlap` 供下一块使用。
///
/// 【窗口为什么由调用方传】长块、起始块、结束块用的是**不同的窗**（规范定义的
/// 三种窗型），换窗只改这一个参数，函数体不必知道自己处理的是哪种块。
private func l3Imdct36(grbuf: Array<Float64>, overlap: Array<Float64>, window: Array<Float64>, nbands: Int64): Unit {
    let gTwid9: Array<Float64> = [
        0.73727734,
        0.79335334,
        0.84339145,
        0.88701083,
        0.92387953,
        0.95371695,
        0.97629601,
        0.99144486,
        0.99904822,
        0.67559021,
        0.60876143,
        0.53729961,
        0.46174861,
        0.38268343,
        0.30070580, // cjlint-ignore !G.OTH.02 MP3 蝶形旋转系数，非敏感信息
        0.21643961,
        0.13052619,
        0.04361938
    ]

    var j: Int64 = 0
    var grOff: Int64 = 0
    var ovlOff: Int64 = 0
    while (j < nbands) {
        var co = Array<Float64>(9, repeat: 0.0)
        var si = Array<Float64>(9, repeat: 0.0)
        co[0] = -grbuf[grOff + 0]
        si[0] = grbuf[grOff + 17]
        var i: Int64 = 0
        while (i < 4) {
            si[8 - 2 * i] = grbuf[grOff + 4 * i + 1] - grbuf[grOff + 4 * i + 2]
            co[1 + 2 * i] = grbuf[grOff + 4 * i + 1] + grbuf[grOff + 4 * i + 2]
            si[7 - 2 * i] = grbuf[grOff + 4 * i + 4] - grbuf[grOff + 4 * i + 3]
            co[2 + 2 * i] = -(grbuf[grOff + 4 * i + 3] + grbuf[grOff + 4 * i + 4])
            i = i + 1
        }
        l3Dct39(co)
        l3Dct39(si)
        si[1] = -si[1]
        si[3] = -si[3]
        si[5] = -si[5]
        si[7] = -si[7]

        var k: Int64 = 0

        while (k < 8) {
            let ovl = overlap[ovlOff + k]
            let sum = co[k] * gTwid9[9 + k] + si[k] * gTwid9[k]
            overlap[ovlOff + k] = co[k] * gTwid9[k] - si[k] * gTwid9[9 + k]
            grbuf[grOff + k] = ovl * window[k] - sum * window[9 + k]
            grbuf[grOff + 17 - k] = ovl * window[9 + k] + sum * window[k]

            k = k + 1
        }

        let ovl = overlap[ovlOff + 8]
        let sum = co[8] * gTwid9[17] + si[8] * gTwid9[8]
        overlap[ovlOff + 8] = co[8] * gTwid9[8] - si[8] * gTwid9[17]
        grbuf[grOff + 8] = ovl * window[8] - sum * window[17]
        grbuf[grOff + 17 - 8] = ovl * window[17] + sum * window[8]

        j = j + 1
        grOff = grOff + 18
        ovlOff = ovlOff + 9
    }
}

/// 3 点 IDCT（短块 12 点 IMDCT 的内核）：把三个频域样本还原成三个时域样本。
///
/// 短块的变换是"12 点 = 4 组 3 点"，故这里是 3 点这一层的展开蝶形。
private func l3Idct3(x0: Float64, x1: Float64, x2: Float64, dst: Array<Float64>): Unit {
    let m1 = x1 * 0.86602540
    let a1 = x0 - x2 * 0.5
    dst[1] = x0 + x2
    dst[0] = a1 + m1
    dst[2] = a1 - m1
}

/// 12 点 IMDCT（短块的单个窗口）：4 组 3 点变换 + 加窗 + 重叠相加。
///
/// `dst` 与 `overlap` 的错位相加方式与长块一致，只是长度小 3 倍 ——
/// 短块的"三个窗口"由调用方 `l3ImdctShort` 循环三次完成。
private func l3Imdct12(x: Array<Float64>, dst: Array<Float64>, overlap: Array<Float64>): Unit {
    if (dst.size < 6 || overlap.size < 6) {
        return
    }
    let gTwid3: Array<Float64> = [0.79335334, 0.92387953, 0.99144486, 0.60876143, 0.38268343, 0.13052619]
    var co = Array<Float64>(3, repeat: 0.0)
    var si = Array<Float64>(3, repeat: 0.0)
    l3Idct3(-x[0], x[6] + x[3], x[12] + x[9], co)
    l3Idct3(x[15], x[12] - x[9], x[6] - x[3], si)
    si[1] = -si[1]

    for (i in Range<Int64>(0, 3, 1, true, true, false)) {
        let ovl = overlap[i]
        let sum = co[i] * gTwid3[3 + i] + si[i] * gTwid3[i]
        overlap[i] = co[i] * gTwid3[i] - si[i] * gTwid3[3 + i]
        dst[i] = ovl * gTwid3[2 - i] - sum * gTwid3[5 - i]
        dst[5 - i] = ovl * gTwid3[5 - i] + sum * gTwid3[2 - i]
    }
}

/// 短块的 IMDCT：对每个子带做 3 个窗口（各 12 点），并做窗口间的重叠相加。
///
/// 调用方必须**先**做过 `l3Reorder`：短块的频谱在码流里是窗口优先排列的，
/// 本函数按子带连续的假设取数（见 `l3Reorder` 的说明）。
private func l3ImdctShort(grbuf: Array<Float64>, overlap: Array<Float64>, nbands: Int64): Unit {
    var offG: Int64 = 0
    var offO: Int64 = 0
    var n = nbands
    while (n > 0) {
        var tmp = Array<Float64>(18, repeat: 0.0)
        grbuf.slice(offG, 18).copyTo(tmp)

        overlap.slice(offO, 6).copyTo(grbuf.slice(offG, 6))

        if (offG + 6 < grbuf.size && offO + 6 < overlap.size) {
            l3Imdct12(tmp, grbuf.slice(offG + 6, min(6, grbuf.size - (offG + 6))),
                overlap.slice(offO + 6, min(6, overlap.size - (offO + 6))))
        }
        if (offG + 12 < grbuf.size && offO + 6 < overlap.size) {
            l3Imdct12(tmp.slice(1, 17), grbuf.slice(offG + 12, min(6, grbuf.size - (offG + 12))),
                overlap.slice(offO + 6, min(6, overlap.size - (offO + 6))))
        }
        if (offO < overlap.size && offO + 6 < overlap.size) {
            l3Imdct12(tmp.slice(2, 16), overlap.slice(offO, min(6, overlap.size - offO)),
                overlap.slice(offO + 6, min(6, overlap.size - (offO + 6))))
        }

        offG = offG + 18
        offO = offO + 9
        n = n - 1
    }
}

/// 对每 36 个样本跨度里"后半 18 个样本"的奇数位置取反（步进 2 个跨度、最多 16 个）。
///
/// 【来历】短块频谱在相邻样本间有规范定义的符号交替；本实现让 IMDCT 输出**不带**
/// 这层交替，统一在这里补 —— 这也是 `l3Decode` 里**无条件调用**它的原因
/// （不要误以为它只服务短块）。这是参照实现的结构，不是本库的选择。
///
/// 【维护提示】它是"整块符号相乘"，改动会影响一片频率范围的相位而不是音量 ——
/// 这类错误用耳朵不容易判断，靠与独立参照解码器的逐样本/包络比对才抓得住。
private func l3ChangeSignRange(grbuf: Array<Float64>, baseOff: Int64, bands: Int64): Unit {
    var b: Int64 = 0
    var base: Int64 = baseOff + 18
    while (b < 32 && b < bands) {
        var i: Int64 = 1
        while (i < 18) {
            let idx = base + i
            if (idx < grbuf.size) {
                grbuf[idx] = -grbuf[idx]
            }
            i = i + 2
        }
        b = b + 2
        base = base + 36
    }
}

// ===== Layer III IMDCT变换 =====
/// 按块类型分派 IMDCT，并处理"混合块"的长短两段。
///
/// 三段逻辑：
///   · 前 `nLongBands` 个子带走 `l3Imdct36`（长块的全部、或混合块的低频段）；
///   · 余下 `rem = 32 - nLongBands` 个：纯短块走 `l3ImdctShort`，起始/结束块走
///     `l3Imdct36` 配 `gMdctWindow[1]`（那就是"起始/结束"窗）；
///   · 窗表两行的用途由此处两处分派决定 —— 长块用 `[0]`、起始/结束块用 `[1]`，
///     短块自带窗（见 `l3Imdct12`），所以不需要第三行。
/// 切片偏移里的 `18 *` 与 `9 *` 是"每子带 18 个样本、每子带 9 个重叠样本"。
private func l3ImdctGr(grbuf: Array<Float64>, overlap: Array<Float64>, blockType: Int64, nLongBands: Int64): Unit {
    let gMdctWindow: Array<Array<Float64>> = [
        [0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953, 0.88701083, 0.84339145, 0.79335334, 0.73727734,
            0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343, 0.46174861, 0.53729961, 0.60876143, 0.67559021], // cjlint-ignore !G.OTH.02 MP3 窗函数系数，非敏感信息
        [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.99144486, 0.92387953, 0.79335334, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.13052619,
            0.38268343, 0.60876143]
    ]

    if (nLongBands != 0) {
        l3Imdct36(grbuf, overlap, gMdctWindow[0], nLongBands)
    }
    let rem = 32 - nLongBands
    if (rem > 0) {
        let grbufRest = grbuf.slice(18 * nLongBands, grbuf.size - 18 * nLongBands)
        let overlapRest = overlap.slice(9 * nLongBands, overlap.size - 9 * nLongBands)
        if (blockType == SHORT_BLOCK_TYPE) {
            l3ImdctShort(grbufRest, overlapRest, rem)
        } else {
            let win = gMdctWindow[if (blockType == STOP_BLOCK_TYPE) {
                    1
                } else {
                    0
                }]
            l3Imdct36(grbufRest, overlapRest, win, rem)
        }
    }
}

/// 把本帧**尚未消费的主数据尾部**存入位池（最多保留最后 511 字节）。
///
/// `remains` 从"当前位位置向上取整到字节"算到 `bs.limit`（本帧负载末尾）；
/// 超过上限时**丢弃最前面的部分**：位池只服务"下一帧往回借用"，而借用量受
/// `main_data_begin`（最多 511 字节）限制，所以留最后 511 字节就够。
/// 位位置向上取整（`+7 / 8`）而不是向下 —— 借用是按字节计的，半个字节也要算进去。
protected func l3SaveReservoir(h: Mp3Dec, s: Mp3Scratch): Unit {
    let pos = (s.bs.pos + 7) / 8
    var remains = s.bs.limit / 8 - pos
    var start = pos
    if (remains > MAX_BITRESERVOIR_BYTES) {
        start = start + (remains - MAX_BITRESERVOIR_BYTES)
        remains = MAX_BITRESERVOIR_BYTES
    }

    var i: Int64 = 0
    while (i < remains) {
        h.reservBuf[i] = s.maindata[start + i]
        i = i + 1
    }
    h.reserv = remains
}

/// 拼出本帧解码用的主数据流：**位池尾部 + 本帧负载**，返回"位池是否够用"。
///
/// 拼接顺序不能颠倒：主数据流先放"向前借来的字节"，再接本帧自己的负载。
/// 位池里可能少于 `mainDataBegin`（流开头若干帧、或刚 seek 之后就是这样），
/// 此时取位池现有的全部（`bytesHave`）并返回 0，让调用方知道这一帧借不齐。
/// `max(0, h.reserv - mainDataBegin)` 取的是位池**尾部**若干字节 ——
/// 与 `l3SaveReservoir` 只留尾部的策略配对，两处必须一起改才自洽。
protected func l3RestoreReservoir(h: Mp3Dec, bs: Mp3Bits, s: Mp3Scratch, mainDataBegin: Int64): Int64 {
    let frameBytes = (bs.limit - bs.pos) / 8
    let bytesHave = min(h.reserv, mainDataBegin)

    var i: Int64 = 0
    while (i < min(h.reserv, mainDataBegin)) {
        s.maindata[i] = h.reservBuf[max(0, h.reserv - mainDataBegin) + i]
        i = i + 1
    }
    i = 0
    while (i < frameBytes) {
        s.maindata[bytesHave + i] = bs.buf[bs.pos / 8 + i]
        i = i + 1
    }
    bitsInit(s.bs, s.maindata, bytesHave + frameBytes)
    if (h.reserv >= mainDataBegin) {
        return 1
    } else {
        return 0
    }
}

/// Layer III 一个 granule 的完整解码编排（本文件的"主线"）。
///
/// 顺序是"两遍扫描 + 一次立体声"：
///   第 1 遍（逐声道）：标度因子（含强度位置）→ Huffman 解码 + 就地反量化；
///   中间：立体声处理 —— **必须在两个声道都反量化之后**，因为 MS / 强度立体声
///     都是对成对的左右频谱做运算；
///   第 2 遍（逐声道）：短块重排 → 抗混叠 → IMDCT → 符号交替。
///
/// 【为什么必须是这个顺序】频谱域的立体声处理依赖两个声道都就绪，而它又必须在
/// IMDCT 之前（变换之后就回不到频谱域了）—— 于是"频谱处理"与"变换"自然分成两轮。
///
/// 【两处容易踩的细节】
///   · `layer3grLimit` 是**本声道本 granule 的数据末尾位位置**（`pos + part23Length`），
///     每个声道各不相同；`l3Huffman` 靠它知道何时停下并把位位置复位。
///   · `l3Reorder` 拿 `s.syn` 当临时区 —— 多相合成的输入缓冲此时还没用上，被借来
///     做重排（省一次分配）。看代码时别以为 `syn` 只服务多相合成。
protected func l3Decode(h: Mp3Dec, s: Mp3Scratch, grInfo: Array<Mp3GrInfo>, nch: Int64): Unit {
    var ch: Int64 = 0
    while (ch < nch) {
        let layer3grLimit = s.bs.pos + grInfo[ch].part23Length

        l3DecodeScalefactors(h.header, s.istPos[ch], s.bs, grInfo[ch], s.scf, ch)

        let grbufForHuffman = s.grbuf.slice(576 * ch, s.grbuf.size - 576 * ch)
        // 子段计时（哨兵守卫 ⇒ 默认零开销）：哈夫曼码字解析 + 反量化。
        // `-O2` 后频谱链占 67~69%，只有切开才知道该打哈夫曼还是 IMDCT。
        let tHuff0 = mp3PhaseNow()
        l3Huffman(grbufForHuffman, s.bs, grInfo[ch], s.scf, layer3grLimit)
        mp3PhaseAddHuff(mp3PhaseNow() - tHuff0)

        ch = ch + 1
    }
    if (hdrTestIStereo(h.header)) {
        l3IntensityStereo(s.grbuf, s.istPos[1], grInfo, h.header)
    } else if (hdrTestMsStereo(h.header)) {
        l3MidsideStereo(s.grbuf, 576)
    }
    ch = 0
    while (ch < nch) {
        // 混合块低频段的长块子带数：默认为 2；MPEG2.5（本函数用采样率索引 2 判定）
        // 的划分不同，需要翻倍 —— 这是规范按采样率分组带来的差异。
        var aaBands: Int64 = 31
        var nLongBands: Int64 = 0
        if (grInfo[ch].mixedBlockFlag != 0) {
            nLongBands = 2
        } else {
            nLongBands = 0
        }
        if (hdrGetMySampleRate(h.header) == 2) {
            nLongBands = nLongBands << 1
        }

        // 短块才需要重排与"缩短抗混叠范围"：长块的抗混叠要覆盖到第 31 带，
        // 短块（或混合块的短块部分）只覆盖到长块段之前。
        if (grInfo[ch].nShortSfb != 0) {
            aaBands = nLongBands - 1

            // 临时区借的是 s.syn（见函数头说明）；重排从"长块段之后"开始。
            let grbufForReorder = s.grbuf.slice(576 * ch + nLongBands * 18, s.grbuf.size - (576 * ch + nLongBands * 18))
            l3Reorder(grbufForReorder, s.syn,
                grInfo[ch].sfbtab.slice(grInfo[ch].nLongSfb, grInfo[ch].sfbtab.size - grInfo[ch].nLongSfb))
        }

        // 子段计时：变换链（抗混叠 + IMDCT + 符号翻转）。
        // 短块的重排（上面 if 内）没并进来 —— 它只影响短块帧，单独计时会让代码更碎；
        // 因此 `transNs` 与 `huffNs` 之和会略小于频谱链总量，差额即重排与两侧的频带计算。
        let tTrans0 = mp3PhaseNow()
        let grbufForAa = s.grbuf.slice(576 * ch, s.grbuf.size - 576 * ch)
        l3Antialias(grbufForAa, aaBands)

        let grbufSlice = s.grbuf.slice(576 * ch, s.grbuf.size - 576 * ch)
        l3ImdctGr(grbufSlice, h.mdctOverlap[ch], grInfo[ch].blockType, nLongBands)

        l3ChangeSignRange(s.grbuf, 576 * ch, 32)
        mp3PhaseAddTrans(mp3PhaseNow() - tTrans0)

        ch = ch + 1
    }
}
