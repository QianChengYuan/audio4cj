package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 Layer III —— side info（旁信息）与标度因子读取
 *
 * 【side info 是什么】它是每帧频谱数据之前的**解码说明**：这一帧的数据有多长、
 *   有几个"大值"、用了哪张 Huffman 表、标度因子怎么排、是不是短块、强度立体声
 *   的位置在哪。没有它，后面的比特流只是无法解释的字节。
 *   因此本文件是 Layer III 解码的**入口**（`l3Decode` 的第一步就是调它）。
 *
 * 【MPEG1 与 MPEG2 的差别（本文件最需要小心的地方）】
 *   · granule 数：MPEG1 每声道两个 granule、MPEG2 只有一个 —— `grCount` 先取
 *     声道数，MPEG1 再乘 2；
 *   · `main_data_begin`（位池回退字节数）：MPEG1 读 9 比特，MPEG2 读 `8 + grCount`
 *     比特再右移 —— 字段宽度不同，漏改会让位池错位（表现为开头若干帧全是噪声）；
 *   · 标度因子压缩字段：MPEG1 为 4 比特、MPEG2 为 9 比特；
 *   · `preflag`（高频预加重）：MPEG1 是显式 1 比特，MPEG2 无该比特，由
 *     `scalefac_compress >= 500` 推导；
 *   · `scfsi`（标度因子选择信息）：MPEG1 跨 granule 共享，MPEG2 直接清零。
 *
 * 【返回值约定】`l3ReadSideInfo` 返回**位池回退字节数** `main_data_begin`；
 *   返回 **-1 表示这一帧 side info 非法**（`bigValues > 288`、`blockType == 0`，
 *   或声明的主数据长度超出 `bs.limit` + 位池）—— 调用方据此**丢弃该帧**，
 *   而不是继续按错参数解释后面的比特流。
 *
 * 【为什么有 Mp3Scratch】这些缓冲都按最大规模**一次分配、跨帧复用**
 *   （576×2 的频谱、40 个标度因子、33×64 的合成缓冲），避免每帧热路径反复分配 ——
 *   这是"纯仓颉解码器能否跑到可用速度"的关键之一。
 * ========================================================================== */

// 反量化输出的位宽修正项。MP3 的 `global_gain`（8 比特）不是线性增益，而是"2 的幂
// 的指数"，并与输出位宽挂钩。本库沿用参照实现的 -1：**不要按直觉改它** ——
// 它直接决定下面两个上界，改动等价于整体重新标定，会立刻与 golden 比对冲突。
protected let BITS_DEQUANTIZER_OUT: Int64 = -1

// 标度因子可取的最大值：8 比特满量程 255，减去位宽修正（4）与规范偏置 210。
private let MAX_SCF: Int64 = (255 + BITS_DEQUANTIZER_OUT * 4 - 210)

// 向上取整到 4 的倍数。反量化时用它给出指数基准（见 mp3_huffman.cj：
// `l3LdexpQ2(1 << (MAX_SCFI / 4), MAX_SCFI - gainExp)`）—— 取 4 的倍数是为了
// 让 `1 << (MAX_SCFI / 4)` 落在 2 的幂的整数刻度上。
protected let MAX_SCFI: Int64 = (((MAX_SCF + 3) >> 2) << 2)

/// 一个 granule 的 side info（旁信息）—— Layer III 解码全程都要查它。
///
/// 字段名沿用规范的术语（`big_values`、`region_count`……），这样对着规范即可核对；
/// 刻意不做"更友好"的重命名，因为查错时最需要的是与规范一一对应。
protected class Mp3GrInfo {
    /// 标度因子频带长度表（`scf_long` / `scf_short` / `scf_mixed` 三选一，**以 0 结尾**）。
    var sfbtab: Array<Int64>

    /// 本 granule 在比特流里占用的比特数（`part2_3_length`）。
    var part23Length: Int64

    /// "大值"对的个数（`big_values`）：前 2×该值个样点走 Huffman 码表，其余走 count1 表。
    var bigValues: Int64

    /// 标度因子压缩字段：MPEG1 4 比特、MPEG2 9 比特，决定标度因子的位宽与分组。
    var scalefacCompress: Int64

    /// 全局增益（2 的幂的指数基准，见 BITS_DEQUANTIZER_OUT 的说明）。
    var globalGain: Int64

    /// 块类型：0 长块 / 1 起始块 / 2 短块 / 3 结束块。
    var blockType: Int64

    /// 混合块标志：短块时若为 1，则低频部分仍按长块处理。
    var mixedBlockFlag: Int64

    /// 长块标度因子个数（短块时为 0；混合块时为低频那一段的个数）。
    var nLongSfb: Int64

    /// 短块标度因子个数（长块时为 0）。
    var nShortSfb: Int64

    /// 三个区域各用哪张 Huffman 表（索引 0..31，查 `l3Huffman` 里的表索引）。
    var tableSelect: Array<Int64>

    /// 三个区域的边界（以标度因子频带为单位；**255 表示"该区不存在"**）。
    var regionCount: Array<Int64>

    /// 短块三个窗口的公共增益（`subblock_gain`）。
    var subblockGain: Array<Int64>

    /// 预加重标志：高频标度因子统一加 1（MPEG2 由 scalefacCompress 推导）。
    var preflag: Int64

    /// 标度因子缩放：使标度因子步长变为 2 倍（0/1）。
    var scalefacScale: Int64

    /// count1 区选用哪张四元码表（0/1）。
    var count1Table: Int64

    /// 本 granule 的标度因子选择信息（4 比特，仅 MPEG1 有意义）。
    var scfsi: Int64

    public init() {
        sfbtab = []
        part23Length = 0
        bigValues = 0
        scalefacCompress = 0
        globalGain = 0
        blockType = 0
        mixedBlockFlag = 0
        nLongSfb = 0
        nShortSfb = 0
        tableSelect = [0, 0, 0]
        // 第 3 区默认置 255 = "不存在"：长块只划分两个区域，短块也只有一个分界。
        regionCount = [0, 0, 255]
        subblockGain = [0, 0, 0]
        preflag = 0
        scalefacScale = 0
        count1Table = 0
        scfsi = 0
    }
}

/// Layer III 的**复用工作区**：所有"每帧都要用、大小固定"的缓冲都在这里。
///
/// 为什么集中放一处：这些缓冲的**尺寸彼此有关**（`grbuf` 是 `576 × 声道数`、
/// `syn` 是 `(18 + 15) × 64`、`istPos` 每声道 39 项对齐短块的 39 个频带），
/// 散落在各个函数里就更容易改错一处而只在特定素材上暴露。放在此类的 init 里，
/// 尺寸的对应关系一眼可见。
protected class Mp3Scratch {
    /// 位读取器。注意 `buf` 在 init 里被置成空数组：真正的数据每帧由 `l3Decode` 装配。
    var bs: Mp3Bits

    /// 主数据缓冲：**位池（511 字节）+ 本帧负载**。两者拼在一起才能让
    /// `main_data_begin` 的回退访问不需要额外的分支 —— 这是位池最省事的做法。
    var maindata: Array<UInt8>

    /// side info 数组：容量 4 = 立体声时 MPEG1 的 2 granule × 2 声道（最大值）。
    var grInfo: Array<Mp3GrInfo>

    /// 频谱缓冲：`576 × 2`（两个声道首尾相接，各 576 条谱线）。
    var grbuf: Array<Float64>

    /// 标度因子缓冲：长块最多 22 个、短块 39 个，留 40 即可覆盖两种。
    var scf: Array<Float64>

    /// 多相合成的输入缓冲：`(18 + 15) × 64` = 18 个新子带样本 + 15 个历史窗口，
    /// 每个窗口 64 个值（合成滤波需要向前看 15 个窗口，见 mp3_synth.cj）。
    var syn: Array<Float64>

    /// 各声道的强度立体声位置，每声道 39 项（= 短块频带数上限）。
    var istPos: Array<Array<UInt8>>

    public init() {
        bs = Mp3Bits()
        bs.buf = Array<UInt8>(0, repeat: 0)
        bs.pos = 0
        bs.limit = 0

        maindata = Array<UInt8>(MAX_BITRESERVOIR_BYTES + MAX_L3_FRAME_PAYLOAD_BYTES, repeat: 0)
        grInfo = Array<Mp3GrInfo>(4, {_: Int64 => Mp3GrInfo()})
        grbuf = Array<Float64>(576 * 2, repeat: 0.0)
        scf = Array<Float64>(40, repeat: 0.0)
        syn = Array<Float64>((18 + 15) * 64, repeat: 0.0)

        istPos = Array<Array<UInt8>>(2, {
            _: Int64 => Array<UInt8>(39, repeat: UInt8(0))
        })
    }
}

/// 读取一帧的 side info，并把每 granule 的参数填进 `gr`。
///
/// 返回**位池回退字节数**（`main_data_begin`）；**返回 -1 表示这一帧不可用**
/// （判据见文件头）。调用方必须按 -1 丢弃整帧，不能"尽力而为"。
///
/// 三张标度因子频带表（长/短/混合）都是**规范给定的数据**：8 行对应 8 种
/// "MPEG 版本 × 采样率"组合，行末的 `0` 是**表终止符**（配合 `while (sfb[i] != 0)`）。
/// 注意行尾出现的 158 / 192 / 26 这类"反常"值也来自规范，不是笔误。
protected func l3ReadSideInfo(bs: Mp3Bits, gr: Array<Mp3GrInfo>, hdr: Array<UInt8>): Int64 {
    let gScfLong: Array<Array<Int64>> = [
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0],
        [12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2, 0],
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0],
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36, 0],
        [6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26, 0]
    ]
    let gScfShort: Array<Array<Int64>> = [
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30,
            30, 40, 40, 40, 18, 18, 18, 0],
        [8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2,
            2, 2, 2, 2, 2, 26, 26, 26, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32,
            32, 42, 42, 42, 18, 18, 18, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32,
            32, 44, 44, 44, 12, 12, 12, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30,
            30, 40, 40, 40, 18, 18, 18, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22,
            22, 30, 30, 30, 56, 56, 56, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20,
            20, 26, 26, 26, 66, 66, 66, 0],
        [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34,
            34, 42, 42, 42, 12, 12, 12, 0]
    ]
    let gScfMixed: Array<Array<Int64>> = [
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40,
            40, 40, 18, 18, 18, 0],
        [12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2,
            2, 2, 2, 2, 2, 2, 26, 26, 26, 0],
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42,
            42, 18, 18, 18, 0],
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44,
            44, 44, 12, 12, 12, 0],
        [6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40,
            40, 40, 18, 18, 18, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22,
            30, 30, 30, 56, 56, 56, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20,
            26, 26, 26, 66, 66, 66, 0],
        [4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34,
            42, 42, 42, 12, 12, 12, 0]
    ]
    var tables: Int64 = 0
    var scfsi: Int64 = 0
    var mainDataBegin: Int64 = 0
    var part23Sum: Int64 = 0
    // 采样率表的行号：由「采样率索引 + 版本权重」得到（MPEG1 加 6、MPEG2 加 3、
    // MPEG2.5 加 0）。下面的 `- 1` **是行偏移，不是笔误** —— 唯一例外是值为 0 时
    // 保持不变，这一点照参照实现保留（改动会让高位采样率的表行整体错位）。
    var srIdx = hdrGetMySampleRate(hdr)
    if (srIdx != 0) {
        srIdx = srIdx - 1
    }
    // granule 数：先取声道数，MPEG1 再乘 2（MPEG1 每声道两个 granule、MPEG2 一个）。
    var grCount: Int64 = 2
    if (hdrIsMono(hdr)) {
        grCount = 1
    } else {
        grCount = 2
    }
    if (hdrTestMpeg1(hdr)) {
        grCount = grCount * 2
        mainDataBegin = getBits(bs, 9)
        // 这里读的是 `7 + grCount` 比特 = **private_bits + scfsi** 合起来的长度
        // （规范：private 单声道 5 / 立体声 3，scfsi 每声道 4）。private 位不单独读，
        // 而是留在 `scfsi` 变量里、由下面移位时自然甩掉 —— 见那处的对齐技巧。
        scfsi = getBits(bs, 7 + grCount)
    } else {
        // MPEG2：main_data_begin 是 `8 + grCount` 比特，但真实值是**右移 grCount 位**后的
        // 高位部分（低位留给 private 位）。漏掉这个右移会让位池回退量偏大若干倍。
        mainDataBegin = getBits(bs, 8 + grCount) >> grCount
    }
    var giIdx: Int64 = 0
    while (grCount > 0) {
        gr[giIdx].part23Length = getBits(bs, 12)
        part23Sum = part23Sum + gr[giIdx].part23Length
        gr[giIdx].bigValues = getBits(bs, 9)
        if (gr[giIdx].bigValues > 288) {
            return -1
        }

        gr[giIdx].globalGain = getBits(bs, 8)
        if (hdrTestMpeg1(hdr)) {
            gr[giIdx].scalefacCompress = getBits(bs, 4)
        } else {
            gr[giIdx].scalefacCompress = getBits(bs, 9)
        }
        gr[giIdx].sfbtab = gScfLong[srIdx]
        gr[giIdx].nLongSfb = 22
        gr[giIdx].nShortSfb = 0
        if (getBits(bs, 1) != 0) {
            gr[giIdx].blockType = getBits(bs, 2)
            if (gr[giIdx].blockType == 0) {
                return -1
            }
            gr[giIdx].mixedBlockFlag = getBits(bs, 1)
            gr[giIdx].regionCount[0] = 7
            gr[giIdx].regionCount[1] = 255
            if (gr[giIdx].blockType == SHORT_BLOCK_TYPE) {
                // 规范规定 short（短块）**不使用 scfsi**：这里把 granule 1 的
                // 4 位清除，使它们退化为"自带标度因子"（0 表示不启用共享）。
                scfsi = scfsi & 0x0F0F
                if (gr[giIdx].mixedBlockFlag == 0) {
                    gr[giIdx].regionCount[0] = 8
                    gr[giIdx].sfbtab = gScfShort[srIdx]
                    gr[giIdx].nLongSfb = 0
                    gr[giIdx].nShortSfb = 39
                } else {
                    gr[giIdx].sfbtab = gScfMixed[srIdx]
                    if (hdrTestMpeg1(hdr)) {
                        gr[giIdx].nLongSfb = 8
                    } else {
                        gr[giIdx].nLongSfb = 6
                    }
                    gr[giIdx].nShortSfb = 30
                }
            }
            // 短块路径只读 10 比特的表选择，左移 5 位是为了**与长块路径的 15 比特布局对齐**，
            // 这样下面统一用 `>> 10 / >> 5 / & 31` 三次取出三个区域 —— 两条路径共用一个提取式。
            tables = getBits(bs, 10)
            tables = tables << 5
            gr[giIdx].subblockGain[0] = getBits(bs, 3)
            gr[giIdx].subblockGain[1] = getBits(bs, 3)
            gr[giIdx].subblockGain[2] = getBits(bs, 3)
        } else {
            gr[giIdx].blockType = 0
            gr[giIdx].mixedBlockFlag = 0
            tables = getBits(bs, 15)
            gr[giIdx].regionCount[0] = getBits(bs, 4)
            gr[giIdx].regionCount[1] = getBits(bs, 3)
            gr[giIdx].regionCount[2] = 255
        }
        gr[giIdx].tableSelect[0] = (tables >> 10) & 31
        gr[giIdx].tableSelect[1] = (tables >> 5) & 31
        gr[giIdx].tableSelect[2] = (tables) & 31
        if (hdrTestMpeg1(hdr)) {
            gr[giIdx].preflag = getBits(bs, 1)
        } else {
            if (gr[giIdx].scalefacCompress >= 500) {
                gr[giIdx].preflag = 1
            } else {
                gr[giIdx].preflag = 0
            }
        }
        gr[giIdx].scalefacScale = getBits(bs, 1)
        gr[giIdx].count1Table = getBits(bs, 1)
        // 【最像笔误、其实最讲究的一段：scfsi 的对齐技巧】
        // `scfsi` 变量里除了真正的 scfsi，前面还有 private_bits（单声道 5 位、立体声 3 位）。
        // 单声道直接取低 4 位即可；立体声则靠"每次左移 4 位 + 取 bit15..12"来对齐：
        // 前两次迭代（granule 0 的两个声道）取到的是 0 与 private 位（**必须为 0**，
        // 因为 granule 0 一定要自带标度因子），第 2、3 次迭代才轮到 granule 1 的两个
        // 声道取到真正的 scfsi。少一次移位或多一次移位，都会让某个声道错用邻居的
        // 标度因子 —— 而这类错误只在用 scfsi 的编码器上出现，很难一眼看出。
        if (hdrIsMono(hdr)) {
            if (giIdx == 0) {
                gr[giIdx].scfsi = 0
            } else {
                gr[giIdx].scfsi = (scfsi & 15)
            }
        } else {
            gr[giIdx].scfsi = ((scfsi >> 12) & 15)
            scfsi = scfsi << 4
        }
        giIdx = giIdx + 1
        grCount = grCount - 1
    }
    // 一致性校验：本帧声明的主数据长度（part23Sum）加上已读的 side info 位数，
    // 不得超过**本帧实际可用位数**（`bs.limit`）**加上位池能回退的位数**。
    // 这是抵御"长度字段被伪造"的那道闸 —— 不校验就会读到别的帧的数据，
    // 表现为杂音而不是报错，属于最危险的一类静默损坏。
    if (part23Sum + bs.pos > bs.limit + mainDataBegin * 8) {
        return -1
    }
    return mainDataBegin
}

/// 按分组读取标度因子，并同时记录**强度立体声位置**（`istPos`）。
///
/// 【两个容易误读的点】
///   1. `istPos` 是"兼用"的：它既存强度位置，又用 **255 表示"该带不是强度带"**。
///      当某组的标度因子取满量程（全 1）时，这个值不再表示标度因子，而表示
///      "此带用强度立体声" —— `istPos` 记 255，`scf` 仍存原值。
///   2. `scfsi` 参数在这里是**带符号的位模式**：最高位对应"该组是否复用 granule 0
///      的标度因子"。MPEG2 传 `-16`（见 mp3_huffman.cj 的 l3DecodeScalefactors）
///      是**故意**的：负值让下面 `scfsiVal < 0` 成立，从而启用"满量程 = 强度位置"
///      这条 MPEG2 规则。若把它当普通正数处理，MPEG2 的强度立体声会整段失效。
///
/// 结尾把后面 3 项补零：下游对 `scf` / `istPos` 会向前多读 2 项（短块的最后一个
/// 窗口），在这里一次性补齐，避免在热循环里反复做边界判断。
protected func l3ReadScalefactors(scf: Array<Int64>, istPos: Array<UInt8>, scfSize: Array<Int64>,
    scfCount: Array<Int64>, bitbuf: Mp3Bits, scfsi: Int64): Unit {
    var i: Int64 = 0
    var k: Int64 = 0
    var scfOff: Int64 = 0
    var istOff: Int64 = 0
    var scfsiVal = scfsi

    while (i < 4 && scfCount[i] != 0) {
        let cnt = scfCount[i]

        if ((scfsiVal & 8) != 0) {
            var t: Int64 = 0
            while (t < cnt) {
                let istVal: Int64 = Int64(istPos[istOff + t])
                scf[scfOff + t] = istVal
                t = t + 1
            }
        } else {
            let bits = scfSize[i]
            if (bits == 0) {
                var t: Int64 = 0
                while (t < cnt) {
                    scf[scfOff + t] = 0
                    istPos[istOff + t] = UInt8(0)
                    t = t + 1
                }
            } else {
                var maxScf: Int64 = -1
                if (scfsiVal < 0) {
                    maxScf = (1 << bits) - 1
                } else {
                    maxScf = -1
                }
                k = 0
                while (k < cnt) {
                    let s = getBits(bitbuf, bits)
                    if (s == maxScf) {
                        istPos[istOff + k] = UInt8(255)
                    } else {
                        istPos[istOff + k] = UInt8(s)
                    }
                    scf[scfOff + k] = s
                    k = k + 1
                }
            }
        }

        istOff = istOff + cnt
        scfOff = scfOff + cnt
        i = i + 1
        scfsiVal = scfsiVal * 2
    }
    if ((scfOff + 2) < scf.size) {
        scf[scfOff + 0] = 0
        scf[scfOff + 1] = 0
        scf[scfOff + 2] = 0
    }
}
