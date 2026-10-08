package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 Layer III —— 多相合成滤波器组（解码链的最后一级）
 *
 * 【这一级在做什么】前面的 IMDCT 把频谱变成了"32 个子带、每子带 18 个样本"的
 *   形式，本文件负责把它还原成**时域 PCM**：先对每子带做一次 DCT-II，
 *   再用 MPEG 的多相合成滤波（512 项窗口）把子带样本叠成连续波形。
 *
 * 【三个必须知道的约定】
 *   1. **滤波是有状态的**：`qmfState`（15 × 64）保存前 15 个窗口的重叠数据，
 *      跨 granule、跨帧累积。它由 `Mp3Dec` 持有，`reset()` 要清零的正是它 ——
 *      少了它，每个 granule 接缝处会出现规律性"咔哒"。
 *   2. **一次算两个样本**：窗口叠加中对相邻两个输出样本共用的项一样，故
 *      `synthPair` 成对计算，调用方按 `band += 2` 前进（见 `synthGranule`）。
 *   3. **输出是 f32 交错**：`synthPair` 结束时直接调 `scalePcm` 落到库的统一口径
 *      （`[-1, 1]` 的 Float32），因此本文件之后再没有任何数值变换。
 *
 * 【为什么这些常数看着像密码】窗口/蝶形系数（29、213、459…、`G_WIN` 表）
 *   全部来自规范，是固定的滤波器系数，不是可调参数；改动任何一个都等价于
 *   换一个滤波器，会立刻与 golden 比对冲突。
 * ========================================================================== */

// ===== DCT-II变换 =====
/// 对每个子带的 18 个样本做 DCT-II（就地写回），得到合成滤波所需的时域子带样本。
///
/// 循环按子带前进（`n` 是子带数），每个子带内部是一次 18 点变换的展开蝶形
/// （系数来自规范）。这里不用通用变换库：定长 18 点展开更快，代价是代码不像公式。
private func dctII(grbuf: Array<Float64>, n: Int64): Unit {
    let gSec: Array<Float64> = [
        10.19000816,
        0.50060302,
        0.50241929,
        3.40760851,
        0.50547093,
        0.52249861,
        2.05778098,
        0.51544732,
        0.56694406,
        1.48416460,
        0.53104258,
        0.64682180,
        1.16943991,
        0.55310392,
        0.78815460,
        0.97256821,
        0.58293498,
        1.06067765,
        0.83934963,
        0.62250412,
        1.72244716,
        0.74453628,
        0.67480832,
        5.10114861
    ]

    var t = Array<Float64>(32, repeat: 0.0)

    var k: Int64 = 0
    while (k < n) {
        for (i in Range<Int64>(0, 8, 1, true, true, false)) {
            let x0 = grbuf[k + i * 18]
            let x1 = grbuf[k + (15 - i) * 18]
            let x2 = grbuf[k + (16 + i) * 18]
            let x3 = grbuf[k + (31 - i) * 18]
            let t0 = x0 + x3
            let t1 = x1 + x2
            let t2 = (x1 - x2) * gSec[3 * i + 0]
            let t3 = (x0 - x3) * gSec[3 * i + 1]
            t[0 * 8 + i] = t0 + t1
            t[1 * 8 + i] = (t0 - t1) * gSec[3 * i + 2]
            t[2 * 8 + i] = t3 + t2
            t[3 * 8 + i] = (t3 - t2) * gSec[3 * i + 2]
        }

        var ti: Int64 = 0
        while (ti < 4) {
            let xOff = ti * 8
            var x0 = t[xOff + 0]
            var x1 = t[xOff + 1]
            var x2 = t[xOff + 2]
            var x3 = t[xOff + 3]
            var x4 = t[xOff + 4]
            var x5 = t[xOff + 5]
            var x6 = t[xOff + 6]
            var x7 = t[xOff + 7]
            var xt: Float64

            xt = x0 - x7
            x0 = x0 + x7
            x7 = x1 - x6
            x1 = x1 + x6
            x6 = x2 - x5
            x2 = x2 + x5
            x5 = x3 - x4
            x3 = x3 + x4
            x4 = x0 - x3
            x0 = x0 + x3
            x3 = x1 - x2
            x1 = x1 + x2
            t[xOff + 0] = x0 + x1
            t[xOff + 4] = (x0 - x1) * 0.70710677
            x5 = x5 + x6
            x6 = (x6 + x7) * 0.70710677
            x7 = x7 + xt
            x3 = (x3 + x4) * 0.70710677
            x5 = x5 - x7 * 0.198912367
            x7 = x7 + x5 * 0.382683432
            x5 = x5 - x7 * 0.198912367
            x0 = xt - x6
            xt = xt + x6
            t[xOff + 1] = (xt + x7) * 0.50979561
            t[xOff + 2] = (x4 + x3) * 0.54119611
            t[xOff + 3] = (x0 - x5) * 0.60134488
            t[xOff + 5] = (x0 + x5) * 0.89997619
            t[xOff + 6] = (x4 - x3) * 1.30656302 // cjlint-ignore !G.OTH.02 AM 蝶形系数，非敏感信息
            t[xOff + 7] = (xt - x7) * 2.56291556

            ti = ti + 1
        }

        var yOff: Int64 = k
        var j: Int64 = 0
        while (j < 7) {
            grbuf[yOff + 0 * 18] = t[0 * 8 + j]
            grbuf[yOff + 1 * 18] = t[2 * 8 + j] + t[3 * 8 + j] + t[3 * 8 + j + 1]
            grbuf[yOff + 2 * 18] = t[1 * 8 + j] + t[1 * 8 + j + 1]
            grbuf[yOff + 3 * 18] = t[2 * 8 + j + 1] + t[3 * 8 + j] + t[3 * 8 + j + 1]
            yOff = yOff + 4 * 18
            j = j + 1
        }
        grbuf[yOff + 0 * 18] = t[0 * 8 + 7]
        grbuf[yOff + 1 * 18] = t[2 * 8 + 7] + t[3 * 8 + 7]
        grbuf[yOff + 2 * 18] = t[1 * 8 + 7]
        grbuf[yOff + 3 * 18] = t[3 * 8 + 7]
        k = k + 1
    }
}

/// 合成一组"配对"样点（原参照实现的 mp3d_synth_pair）。
///
/// 【为什么多一个 dstOff 参数（移植修正）】原实现把目标指针写成 `dstr = dstl + (nch-1)`，
///   即**通道 nch-1**；本移植原先漏掉了这个通道偏移，直接以通道 0 为基址写出。
///   单声道时两者重合，问题不可见；立体声时这会把配对样点写进左声道、
///   而右声道对应位置缺值 —— 实测右声道相关系数只有 0.96（左声道 1.00）。
///   这里改为显式传入目标偏移，语义与原实现完全一致，也不再依赖切片的共享细节。
private func synthPair(pcm: Array<Float32>, nch: Int64, lins: Array<Float64>, zOff: Int64, dstOff: Int64): Unit {
    let Z0 = lins[zOff + 0 * 64]
    let Z1 = lins[zOff + 1 * 64]
    let Z2 = lins[zOff + 2 * 64]
    let Z3 = lins[zOff + 3 * 64]
    let Z4 = lins[zOff + 4 * 64]
    let Z5 = lins[zOff + 5 * 64]
    let Z6 = lins[zOff + 6 * 64]
    let Z7 = lins[zOff + 7 * 64]
    let Z8 = lins[zOff + 8 * 64]
    let Z9 = lins[zOff + 9 * 64]
    let Z10 = lins[zOff + 10 * 64]
    let Z11 = lins[zOff + 11 * 64]
    let Z12 = lins[zOff + 12 * 64]
    let Z13 = lins[zOff + 13 * 64]
    let Z14 = lins[zOff + 14 * 64]

    var a: Float64 = 0.0

    a = (Z14 - Z0) * 29.0
    a = a + (Z1 + Z13) * 213.0
    a = a + (Z12 - Z2) * 459.0
    a = a + (Z3 + Z11) * 2037.0
    a = a + (Z10 - Z4) * 5153.0
    a = a + (Z5 + Z9) * 6574.0
    a = a + (Z8 - Z6) * 37489.0
    a = a + Z7 * 75038.0
    pcm[dstOff] = scalePcm(a)

    let Y0 = lins[zOff + 2 + 0 * 64]
    let Y2 = lins[zOff + 2 + 2 * 64]
    let Y4 = lins[zOff + 2 + 4 * 64]
    let Y6 = lins[zOff + 2 + 6 * 64]
    let Y8 = lins[zOff + 2 + 8 * 64]
    let Y10 = lins[zOff + 2 + 10 * 64]
    let Y12 = lins[zOff + 2 + 12 * 64]
    let Y14 = lins[zOff + 2 + 14 * 64]
    a = Y14 * 104.0
    a = a + Y12 * 1567.0
    a = a + Y10 * 9727.0
    a = a + Y8 * 64019.0
    a = a + Y6 * -9975.0
    a = a + Y4 * -45.0
    a = a + Y2 * 146.0
    a = a + Y0 * -5.0
    pcm[dstOff + 16 * nch] = scalePcm(a)
}

/// 一个子带的合成滤波：产出 2 个样本/声道，并推进 15×64 的滑动历史缓冲。
///
/// 三步：
///   1. 把 32 个子带样本展开成 64 个中间值（32 点变换的蝶形，`G_WIN` 为规范系数）；
///   2. 对"15 个历史窗口 + 当前窗口"这 16 个窗口做加权叠加（512 项），
///      历史区就是 `zlin = 15 * 64` 之前的部分；
///   3. 把本次的 64 个值滑入历史区，并把叠加结果写成 PCM。
///
/// 【成对计算】叠加式里相邻两个输出样本共享同一批乘积，故由 `synthPair` 一次算出
/// 两个；调用方按 `band += 2` 前进。`lins` 是**跨调用/跨帧**的状态缓冲，
/// 由调用方持有并传回（返回值即更新后的它）。
/// ????????????????
///
/// ?????????????? `synth` ?????????? `synth` ????
/// granule ?? 9 ???? 2??? ???? 18 ??? 240 ????????????
/// ???????????????????????????????
/// ????????????????????
private let G_WIN: Array<Float64> = [
    -1.0,
    26.0,
    -31.0,
    208.0,
    218.0,
    401.0,
    -519.0,
    2063.0,
    2000.0,
    4788.0,
    -5517.0,
    7134.0,
    5959.0,
    35640.0,
    -39336.0,
    74992.0,
    -1.0,
    24.0,
    -35.0,
    202.0,
    222.0,
    347.0,
    -581.0,
    2080.0,
    1952.0,
    4425.0,
    -5879.0,
    7640.0,
    5288.0,
    33791.0,
    -41176.0,
    74856.0,
    -1.0,
    21.0,
    -38.0,
    196.0,
    225.0,
    294.0,
    -645.0,
    2087.0,
    1893.0,
    4063.0,
    -6237.0,
    8092.0,
    4561.0,
    31947.0,
    -43006.0,
    74630.0,
    -1.0,
    19.0,
    -41.0,
    190.0,
    227.0,
    244.0,
    -711.0,
    2085.0,
    1822.0,
    3705.0,
    -6589.0,
    8492.0,
    3776.0,
    30112.0,
    -44821.0,
    74313.0,
    -1.0,
    17.0,
    -45.0,
    183.0,
    228.0,
    197.0,
    -779.0,
    2075.0,
    1739.0,
    3351.0,
    -6935.0,
    8840.0,
    2935.0,
    28289.0,
    -46617.0,
    73908.0,
    -1.0,
    16.0,
    -49.0,
    176.0,
    228.0,
    153.0,
    -848.0,
    2057.0,
    1644.0,
    3004.0,
    -7271.0,
    9139.0,
    2037.0,
    26482.0,
    -48390.0,
    73415.0,
    -2.0,
    14.0,
    -53.0,
    169.0,
    227.0,
    111.0,
    -919.0,
    2032.0,
    1535.0,
    2663.0,
    -7597.0,
    9389.0,
    1082.0,
    24694.0,
    -50137.0,
    72835.0,
    -2.0,
    13.0,
    -58.0,
    161.0,
    224.0,
    72.0,
    -991.0,
    2001.0,
    1414.0,
    2330.0,
    -7910.0,
    9592.0,
    70.0,
    22929.0,
    -51853.0,
    72169.0,
    -2.0,
    11.0,
    -63.0,
    154.0,
    221.0,
    36.0,
    -1064.0,
    1962.0,
    1280.0,
    2006.0,
    -8209.0,
    9750.0,
    -998.0,
    21189.0,
    -53534.0,
    71420.0,
    -2.0,
    10.0,
    -68.0,
    147.0,
    215.0,
    2.0,
    -1137.0,
    1919.0,
    1131.0,
    1692.0,
    -8491.0,
    9863.0,
    -2122.0,
    19478.0,
    -55178.0,
    70590.0,
    -3.0,
    9.0,
    -73.0,
    139.0,
    208.0,
    -29.0,
    -1210.0,
    1870.0,
    970.0,
    1388.0,
    -8755.0,
    9935.0,
    -3300.0,
    17799.0,
    -56778.0,
    69679.0,
    -3.0,
    8.0,
    -79.0,
    132.0,
    200.0,
    -57.0,
    -1283.0,
    1817.0,
    794.0,
    1095.0,
    -8998.0,
    9966.0,
    -4533.0,
    16155.0,
    -58333.0,
    68692.0,
    -4.0,
    7.0,
    -85.0,
    125.0,
    189.0,
    -83.0,
    -1356.0,
    1759.0,
    605.0,
    814.0,
    -9219.0,
    9959.0,
    -5818.0,
    14548.0,
    -59838.0,
    67629.0,
    -4.0,
    7.0,
    -91.0,
    117.0,
    177.0,
    -106.0,
    -1428.0,
    1698.0,
    402.0,
    545.0,
    -9416.0,
    9916.0,
    -7154.0,
    12980.0,
    -61289.0,
    66494.0,
    -5.0,
    6.0,
    -97.0,
    111.0,
    163.0,
    -127.0,
    -1498.0,
    1634.0,
    185.0,
    288.0,
    -9585.0,
    9838.0,
    -8540.0,
    11455.0,
    -62684.0,
    65290.0
]

private func synth(xl: Array<Float64>, dstl: Array<Float32>, nch: Int64, lins: Array<Float64>): Array<Float64> {
    let xr = xl.slice(576 * (nch - 1), xl.size - 576 * (nch - 1))
    let dstrOff = (nch - 1)
    let zlin = 15 * 64

    lins[zlin + 4 * 15 + 0] = xl[18 * 16]
    lins[zlin + 4 * 15 + 1] = xr[18 * 16]
    lins[zlin + 4 * 15 + 2] = xl[0]
    lins[zlin + 4 * 15 + 3] = xr[0]
    lins[zlin + 4 * 31 + 0] = xl[1 + 18 * 16]
    lins[zlin + 4 * 31 + 1] = xr[1 + 18 * 16]
    lins[zlin + 4 * 31 + 2] = xl[1]
    lins[zlin + 4 * 31 + 3] = xr[1]

    // 配对样点。三点约束决定了这里的**顺序与偏移**（改一处就会破坏另一处）：
    //   1. z 偏移尾数 0/1 分别对应 lins 里 xl/xr 的写入位置，因此 0 → 左声道、
    //      1 → 右声道（见 synthPair 的移植修正说明）；
    //   2. 单声道下右声道的状态位是**未更新**的（qmfState 按 step 2 只写偶数位），
    //      读 c=1 会取到陈旧值 —— 所以单声道必须由 c=0 的那次调用**最后写入**；
    //   3. 单声道时 dstrOff == 0，两次调用落在同一位置，正好由第 2 点决定谁生效。
    // 综合：每个分块先写 c=1（右），再写 c=0（左）。
    synthPair(dstl, nch, lins, 4 * 15 + 1, dstrOff)
    synthPair(dstl, nch, lins, 4 * 15, 0)

    synthPair(dstl, nch, lins, 4 * 15 + 64 + 1, 32 * nch + dstrOff)
    synthPair(dstl, nch, lins, 4 * 15 + 64, 32 * nch)

    var i: Int64 = 14
    while (i >= 0) {
        lins[zlin + 4 * i + 0] = xl[18 * (31 - i)]
        lins[zlin + 4 * i + 1] = xr[18 * (31 - i)]
        lins[zlin + 4 * i + 2] = xl[1 + 18 * (31 - i)]
        lins[zlin + 4 * i + 3] = xr[1 + 18 * (31 - i)]
        lins[zlin + 4 * (i + 16) + 0] = xl[1 + 18 * (1 + i)]
        lins[zlin + 4 * (i + 16) + 1] = xr[1 + 18 * (1 + i)]
        lins[zlin + 4 * (i - 16) + 2] = xl[18 * (1 + i)]
        lins[zlin + 4 * (i - 16) + 3] = xr[18 * (1 + i)]
        var a = [0.0, 0.0, 0.0, 0.0]
        var b = [0.0, 0.0, 0.0, 0.0]

        let wBase = (14 - i) * 16
        var k: Int64 = 0
        while (k < 8) {
            let w0 = G_WIN[wBase + 2 * k + 0]
            let w1 = G_WIN[wBase + 2 * k + 1]
            let vz = zlin + 4 * i - 64 * k
            let vy = zlin + 4 * i - 64 * (15 - k)

            var j: Int64 = 0
            if (k == 0) {
                while (j < 4) {
                    b[j] = lins[vz + j] * w1 + lins[vy + j] * w0
                    a[j] = lins[vz + j] * w0 - lins[vy + j] * w1
                    j = j + 1
                }
            } else if ((k & 1) == 1) {
                while (j < 4) {
                    b[j] += lins[vz + j] * w1 + lins[vy + j] * w0
                    a[j] += lins[vy + j] * w1 - lins[vz + j] * w0
                    j = j + 1
                }
            } else {
                while (j < 4) {
                    b[j] += lins[vz + j] * w1 + lins[vy + j] * w0
                    a[j] += lins[vz + j] * w0 - lins[vy + j] * w1
                    j = j + 1
                }
            }
            k = k + 1
        }

        dstl[(15 - i) * nch + dstrOff] = scalePcm(a[1])
        dstl[(17 + i) * nch + dstrOff] = scalePcm(b[1])
        dstl[(15 - i) * nch + 0] = scalePcm(a[0])
        dstl[(17 + i) * nch + 0] = scalePcm(b[0])
        dstl[(47 - i) * nch + dstrOff] = scalePcm(a[3])
        dstl[(49 + i) * nch + dstrOff] = scalePcm(b[3])
        dstl[(47 - i) * nch + 0] = scalePcm(a[2])
        dstl[(49 + i) * nch + 0] = scalePcm(b[2])
        i = i - 1
    }

    return lins
}

// ===== PCM合成输出 =====
/// 一个 granule 的合成编排：逐声道 DCT-II → 逐子带 `synth` → 输出 PCM 并更新滤波状态。
///
/// 顺序与数据依赖：
///   1. 每个声道先做 `dctII`（就地变换，须在 `synth` 之前）；
///   2. 把持久状态 `qmfState` 拷进工作缓冲 `lins` 的头部，`synth` 在尾部（`15 * 64`）
///      追加当前窗口 —— 这就是"15 个历史窗口 + 当前"的来处；
///   3. 逐子带调 `synth`，**步进 2**（它一次产 2 个样本，见 `synth` 的说明）；
///   4. 把 PCM 拷出到调用方缓冲，并把滑动缓冲的**尾部**收回 `qmfState` 供下一 granule 用。
///
/// 【单声道为什么只取偶数项更新状态】多相合成的成对输出对单声道而言有一半是
/// "配对样点"（由 `synthPair` 的另一支写入），状态只需保留其中一路；
/// 立体声则两路都是真实数据，必须逐个保留 —— 这就是末尾那个 `nch == 1` 分支的来由。
protected func synthGranule(qmfState: Array<Float64>, grbuf: Array<Float64>, nbands: Int64, nch: Int64,
    pcm: Array<Float32>, lins: Array<Float64>): Array<Float64> {
    var pcmSize = 1152 * nch
    var pcmBuffer = Array<Float32>(pcmSize, repeat: 0.0)

    var ch: Int64 = 0
    while (ch < nch) {
        let dctSlice = grbuf.slice(576 * ch, 576 * (ch + 1) - 576 * ch)
        dctII(dctSlice, nbands)
        ch = ch + 1
    }

    // 持久状态拷进工作缓冲头部；`synth` 会在 15*64 处追加当前窗口
    qmfState.copyTo(lins, 0, 0, 15 * 64)

    var band: Int64 = 0
    // 步进 2：`synth` 一次产出 2 个样本（成对计算，见 synth 的说明）
    while (band < nbands) {
        let grbufSlice = grbuf.slice(band, grbuf.size - band)
        let pcmSlice = pcmBuffer.slice(32 * nch * band, pcmBuffer.size - 32 * nch * band)
        let linsSlice = lins.slice(band * 64, lins.size - band * 64)
        synth(grbufSlice, pcmSlice, nch, linsSlice)

        band = band + 2
    }

    let copySize = min(pcmSize, pcm.size)
    pcmBuffer.copyTo(pcm, 0, 0, copySize)

    if (nch == 1) {
        for (qi in Range<Int64>(0, 15 * 64, 2, true, true, false)) {
            qmfState[qi] = lins[nbands * 64 + qi]
        }
    } else {
        for (qi in Range<Int64>(0, 15 * 64, 1, true, true, false)) {
            qmfState[qi] = lins[nbands * 64 + qi]
        }
    }

    return qmfState
}
