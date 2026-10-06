package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 —— 帧头解析与帧级常量
 *
 * 【为什么单独一个文件】帧头是**唯一能把 MP3 从裸字节流里切出来**的东西：
 *   先找同步（`findFrame`，在 mp3_anchor.cj）→ 校验帧头 → 算帧长 → 才能按帧推进。
 *   本文件提供这中间的全部字段访问与判定，以及帧长 / 采样率 / 每帧样本数这些
 *   "后续一切计算的基准"。
 *
 * 【帧头 4 字节的位布局（h[0]..h[3]）】
 *   h[0]：同步字高 8 位（固定 0xFF）
 *   h[1]：同步字低 3 位 + 版本(2 位) + 层(2 位) + 保护位
 *   h[2]：比特率索引(4 位) + 采样率索引(2 位) + 填充位 + 私有位
 *   h[3]：声道模式(2 位) + 模式扩展(2 位) + 版权/原创位 + 强调(2 位)
 *   本文件所有 `hdr*` 都是对这四个字节取位的**纯函数**，不持有状态。
 *
 * 【几个易错点（都在下面各函数的注释里）】
 *   · `hdrGetMySampleRate` 返回的是"**采样率表行号**"而不是采样率本身，
 *     且调用方还要再做一次行偏移；
 *   · 比特率表里存的是**半值**（kbps 的一半），故 `hdrBitrateKbps` 末尾要 `* 2`；
 *   · 帧长依赖"填充位"，同层相邻帧可以差 1 字节 —— 按固定长度推进必错。
 * ========================================================================== */

/// 自由格式（free format）帧的长度上限。
///
/// 自由格式**不在帧头里报比特率**（比特率索引为 0），只能靠"找下一处同步"
/// 反推帧长。给一个上限是为了：① 限制扫描长度；② 抵御构造出的超长帧。
protected let MAX_FREE_FORMAT_FRAME_SIZE: Int64 = 2304

/// 判定"连续帧"时最多向前比对几帧 —— 单个同步字不足为凭（见 `findFrame`）。
protected let MAX_FRAME_SYNC_MATCHES: Int64 = 10

/// Layer III 单帧负载的上限（与自由格式上限同值）。
protected let MAX_L3_FRAME_PAYLOAD_BYTES: Int64 = MAX_FREE_FORMAT_FRAME_SIZE

/// 位池容量（字节）：规范允许向前借用的最大值。
protected let MAX_BITRESERVOIR_BYTES: Int64 = 511

/// 块类型：短块（8 个频带、3 个窗口）。
protected let SHORT_BLOCK_TYPE: Int64 = 2

/// 块类型：结束块（长块之后过渡用的窗型）。
protected let STOP_BLOCK_TYPE: Int64 = 3

/// 声道模式：单声道。
protected let MODE_MONO: Int64 = 3

/// 声道模式：联合立体声（可能含 MS / 强度立体声）。
protected let MODE_JOINT_STEREO: Int64 = 1

/// 帧头长度（字节）。
protected let HDR_SIZE: Int64 = 4

/* ----------------------------------------------------------------------------
 * MPEG 音频帧头（4 字节）字段访问
 *
 * 【为什么是普通函数而不是宏】这些访问在原参照实现里是宏（cpp 风格 #define）。
 *   仓颉没有 C 预处理宏；若改用宏包，会给本项目引入一个独立模块与编译顺序依赖，
 *   而这里的取位逻辑只是一行表达式，普通函数完全够用且能被调试器单步。
 *   帧头固定 4 字节（h[0]..h[3]），全部按位从字节取值。
 * -------------------------------------------------------------------------- */
protected func hdrIsMono(h: Array<UInt8>): Bool {
    (Int64(h[3]) & 0xC0) == 0xC0
}

private func hdrIsFreeFormat(h: Array<UInt8>): Bool {
    (Int64(h[2]) & 0xF0) == 0
}

protected func hdrIsCrc(h: Array<UInt8>): Bool {
    !((Int64(h[1]) & 1) == 1)
}

private func hdrTestPadding(h: Array<UInt8>): Bool {
    (Int64(h[2]) & 0x2) != 0
}

protected func hdrTestMpeg1(h: Array<UInt8>): Bool {
    (Int64(h[1]) & 0x8) != 0
}

private func hdrTestNotMpeg25(h: Array<UInt8>): Bool {
    (Int64(h[1]) & 0x10) != 0
}

protected func hdrTestIStereo(h: Array<UInt8>): Bool {
    (Int64(h[3]) & 0x10) != 0
}

protected func hdrTestMsStereo(h: Array<UInt8>): Bool {
    (Int64(h[3]) & 0x20) != 0
}

protected func hdrGetStereoMode(h: Array<UInt8>): Int64 {
    (Int64(h[3]) >> 6) & 3
}

protected func hdrGetStereoModeExt(h: Array<UInt8>): Int64 {
    (Int64(h[3]) >> 4) & 3
}

protected func hdrGetLayer(h: Array<UInt8>): Int64 {
    (Int64(h[1]) >> 1) & 3
}

private func hdrGetBitrate(h: Array<UInt8>): Int64 {
    (Int64(h[2]) >> 4) & 15
}

protected func hdrGetSampleRate(h: Array<UInt8>): Int64 {
    (Int64(h[2]) >> 2) & 3
}

/// 采样率索引的三档合并索引（MPEG1 / MPEG2 / MPEG2.5 各占一档）。
/// 返回"采样率表行号" = `采样率索引 + 版本权重`（MPEG1 加 6、MPEG2 加 3、MPEG2.5 加 0）。
///
/// 【它不是采样率】返回值的用途是**选标度因子频带表的行**（见 mp3_layer3.cj），
/// 调用方还会再做一次行偏移（`- (v != 0)`）。**不要**把它当 Hz 用。
protected func hdrGetMySampleRate(h: Array<UInt8>): Int64 {
    ((Int64(h[2]) >> 2) & 3) + (((Int64(h[1]) >> 3) & 1) + ((Int64(h[1]) >> 4) & 1)) * 3
}

private func hdrIsFrame576(h: Array<UInt8>): Bool {
    (Int64(h[1]) & 14) == 2
}

protected func hdrIsLayer1(h: Array<UInt8>): Bool {
    (Int64(h[1]) & 6) == 6
}

/// 帧头合法性判定：拒绝规范中"保留/非法"的字段组合（版本、层、比特率索引、
/// 采样率索引，以及层与比特率表是否匹配）。
///
/// 这是帧同步的**第二道闸**：`findFrame` 先用同步字找候选，再用本函数把"恰好含
/// 0xFF 的巧合字节"筛掉。判据按规范保留值严格执行、不放宽 —— 放宽一处，
/// 垃圾数据就会被当成帧，解码出的是噪声而不是报错。
protected func hdrValid(h: Array<UInt8>): Bool {
    if (!(h[0] == 0xFF)) {
        return false
    }

    let h1 = h[1]
    let cond1 = ((h1 & 0xf0) == 0xf0) || ((h1 & 0xfe) == 0xe2)
    if (!cond1) {
        return false
    }
    if (hdrGetLayer(h) == 0) {
        return false
    }
    if (hdrGetBitrate(h) == 15) {
        return false
    }
    if (hdrGetSampleRate(h) == 3) {
        return false
    }
    return true
}

/// 判断两个帧头是否属于**同一串流**：版本、层、采样率、声道模式必须一致。
///
/// 【为什么不逐字节比较】相邻帧的**比特率与填充位可以不同**（VBR 正是这么做的），
/// 逐字节比较会把正常的 VBR 流判成损坏。因此只比较"同一串流必然相同"的字段。
/// `findFrame` 靠"连续 10 帧都同串流"来确认同步真的成立（单个同步字不足为凭）。
protected func hdrCompare(h1: Array<UInt8>, h2: Array<UInt8>): Bool {
    if (!hdrValid(h2)) {
        return false
    }
    if (((h1[1] ^ h2[1]) & 0xFE) != 0) {
        return false
    }
    if (((h1[2] ^ h2[2]) & 0x0C) != 0) {
        return false
    }
    if ((hdrIsFreeFormat(h1) && !hdrIsFreeFormat(h2)) || (!hdrIsFreeFormat(h1) && hdrIsFreeFormat(h2))) {
        return false
    }
    return true
}

/// 帧头声明的比特率（kbps）；**返回 0 表示索引为 0**（自由格式 / 不报比特率）。
///
/// 表里的数是**半值**（用一套表同时覆盖 15 档 × 3 层 × 2 个版本组），
/// 所以末尾要 `* 2` —— 漏掉它会让所有时长与定位都差一倍。
protected func hdrBitrateKbps(h: Array<UInt8>): Int64 {
    let halfrate: Array<Array<Array<Int64>>> = [
        [[0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80], [0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72,
            80], [0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128]],
        [[0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160],
            [0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192],
            [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224]]
    ]
    var mpeg1: Int64 = 0
    if (hdrTestMpeg1(h)) {
        mpeg1 = 1
    } else {
        mpeg1 = 0
    }
    let layerIndex = hdrGetLayer(h) - 1
    let brIndex = hdrGetBitrate(h)
    return 2 * halfrate[mpeg1][layerIndex][brIndex]
}

/// 采样率（Hz）。
///
/// 基础表只有 3 个值（44.1k / 48k / 32k，规范定义），其余档位靠**折半**得到：
/// MPEG2 减半、MPEG2.5 再减半（22050/24000/16000、11025/12000/8000）——
/// 这就是下面两次 `>> 1` 的来由，不是"顺手写两次"。
protected func hdrSampleRateHz(h: Array<UInt8>): Int64 {
    let gHz: Array<Int64> = [44100, 48000, 32000]

    let sampleRateIdx: Int64 = hdrGetSampleRate(h)
    var v = gHz[sampleRateIdx]

    if (!hdrTestMpeg1(h)) {
        v = v >> 1
    }
    if (!hdrTestNotMpeg25(h)) {
        v = v >> 1
    }
    return v
}

/// 每帧的样本数（每声道）：Layer I 恒为 384；Layer II/III 为 1152（MPEG1）
/// 或 576（MPEG2 / MPEG2.5）。
///
/// 【注意它是"每声道"还是"合计"】这里返回的是**每声道**的样本数，声道数的相乘
/// 由调用方负责 —— 交错 PCM 的总样本数 = 帧数 × 声道数 × 本值。
protected func hdrFrameSamples(h: Array<UInt8>): Int64 {
    if (hdrIsLayer1(h)) {
        return 384
    }
    var sh: Int64 = 0
    if (hdrIsFrame576(h)) {
        sh = 1
    } else {
        sh = 0
    }
    return 1152 >> sh
}

/// 帧长（字节，**不含填充**）。自由格式（返回 0）时由调用方传入实测的 `freeFormatSize`。
///
/// 公式 `样本数 × kbps × 125 / 采样率`：125 = 1000/8，把"千比特每秒"换算成"字节每毫秒"
/// 再乘以本帧时长（毫秒）。Layer I 还要求向下对齐到 4 字节（`& !3`），因为它按 4 字节
/// 槽位组织。**帧长不含填充**，调用方要另外加 `hdrPadding`，漏掉会逐帧错位。
protected func hdrFrameBytes(h: Array<UInt8>, freeFormatSize: Int64): Int64 {
    var frameBytes = hdrFrameSamples(h) * hdrBitrateKbps(h) * 125 / hdrSampleRateHz(h)
    if (hdrIsLayer1(h)) {
        frameBytes = frameBytes & !3
    }
    if (frameBytes != 0) {
        return frameBytes
    }
    return freeFormatSize
}

/// 本帧的填充字节数（0 / 1 / 4）。
///
/// 填充位是为"用固定比特率凑整毫秒"而设的：Layer I 一次补 4 字节，其余补 1 字节。
/// **这是"同层相邻帧长度可以不同"的唯一来源** —— 任何按固定帧长推进的写法都会错位，
/// 正确做法是每帧都重新算 `帧长 + 填充`。
protected func hdrPadding(h: Array<UInt8>): Int64 {
    if (hdrTestPadding(h)) {
        if (hdrIsLayer1(h)) {
            return 4
        } else {
            return 1
        }
    }
    return 0
}
