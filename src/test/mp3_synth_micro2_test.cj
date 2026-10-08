package audio4cj.test

import std.time.*

/* ============================================================================
 * 合成段微基准（续）—— 覆盖第一份没量到的 43% 缺口
 *
 * 第一份（`mp3_synth_micro_test.cj`）量到：k 迭代形态 0.99 + scalePcm 0.10 +
 * synthPair 0.17 = 1.2 ms/帧，只解释分段实测的合成 2.10 ms/帧，缺口 0.9 ms/帧。
 * 本文件补齐缺口里可预期的三项：
 *   · V4 i 循环蝶形：每个 i 有 8 次取数（含 18*(31-i) 之类的下标算术）+
 *     8 次写入（写进 2112 的 lins）—— 540 次 i/帧；
 *   · V5 dctII：每次调用都新建 gSec(24) 与 t(32)，n=18 的两层循环 —— 4 次/帧；
 *   · V6 每声道每 granule 的固定开销：pcmBuffer 分配+清零(2304)、qmfState 拷入(960)、
 *     状态回写循环(960 步长 2) —— 4 次/帧。
 *
 * 与第一份一样：**只复刻形态，不调用生产函数**；结果是排优先级的依据，
 * 最终以 phase_timing 的整段实测为准。
 * ========================================================================== */
private func g1(x: Float64): String {
    // Inf/NaN 与超范围值都要能打印出来 —— 否则诊断本身会成为新的失败点
    // （实测踩过：把 inf 直接丢给 Int64 会抛 OverflowException，真正的坏数就看不见了）。
    if (x != x) {
        return "NaN"
    }
    if (x > 1.0e14) {
        return "inf+"
    }
    if (x < -1.0e14) {
        return "-inf"
    }
    let v = Int64(x * 100.0 + 0.5)
    return "${v / 100}.${v % 100}"
}

/// V4：`synth` 里 i 循环的取数 + 蝶形写入形态。
private func uV4(iIters: Int64): (Float64, Float64) {
    let xl = Array<Float64>(576, repeat: 0.0)
    let lins = Array<Float64>(2112, repeat: 0.0)
    var p: Int64 = 0
    while (p < 576) {
        xl[p] = Float64(p % 13) * 0.03 - 0.19
        p += 1
    }
    let lz: Int64 = 960
    var sink = 0.0
    let t0 = MonoTime.now()
    var it: Int64 = 0
    while (it < iIters) {
        let i = 14 - (it % 15)
        lins[lz + 4 * i + 0] = xl[18 * (31 - i)]
        lins[lz + 4 * i + 1] = xl[1 + 18 * (31 - i)]
        lins[lz + 4 * i + 2] = xl[18 * (31 - i) + 1]
        lins[lz + 4 * i + 3] = xl[1 + 18 * (31 - i) + 2]
        lins[lz + 4 * (i + 16) + 0] = xl[1 + 18 * (1 + i)]
        lins[lz + 4 * (i + 16) + 1] = xl[2 + 18 * (1 + i)]
        lins[lz + 4 * (i - 16) + 2] = xl[18 * (1 + i)]
        lins[lz + 4 * (i - 16) + 3] = xl[1 + 18 * (1 + i)]
        sink += lins[lz + 4 * i]
        it += 1
    }
    return (Float64((MonoTime.now() - t0).toNanoseconds()), sink)
}

/// V5：`dctII` 的形态（含每次调用新建 gSec 与 t）。
private func uV5(calls: Int64): (Float64, Float64) {
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
    let grbuf = Array<Float64>(576, repeat: 0.0)
    var p: Int64 = 0
    while (p < 576) {
        grbuf[p] = Float64(p % 11) * 0.05 - 0.27
        p += 1
    }
    var sink = 0.0
    let t0 = MonoTime.now()
    var c: Int64 = 0
    while (c < calls) {
        let t = Array<Float64>(32, repeat: 0.0)
        let n: Int64 = 18
        var k: Int64 = 0
        while (k < n) {
            for (i in Range<Int64>(0, 8, 1, true, true, false)) {
                let x0 = grbuf[k + i * 18]
                let x1 = grbuf[k + (15 - i) * 18]
                let x2 = grbuf[k + (16 + i) * 18]
                let x3 = grbuf[k + (31 - i) * 18]
                let t0v = x0 + x3
                let t1v = x1 + x2
                let t2 = (x1 - x2) * gSec[3 * i + 0]
                let t3 = (x0 - x3) * gSec[3 * i + 1]
                t[0 * 8 + i] = t0v + t1v
                t[1 * 8 + i] = (t0v - t1v) * gSec[3 * i + 2]
                t[2 * 8 + i] = t3 + t2
                t[3 * 8 + i] = (t3 - t2) * gSec[3 * i + 2]
            }
            var ti: Int64 = 0
            while (ti < 4) {
                let xOff = ti * 8
                var a0 = t[xOff + 0]
                var a1 = t[xOff + 1]
                var a2 = t[xOff + 2]
                var a3 = t[xOff + 3]
                var a4 = t[xOff + 4]
                var a5 = t[xOff + 5]
                var a6 = t[xOff + 6]
                var a7 = t[xOff + 7]
                var xt: Float64
                xt = a0 - a7
                a0 = a0 + a7
                a7 = a1 - a6
                a1 = a1 + a6
                a6 = a2 - a5
                a2 = a2 + a5
                a5 = a3 - a4
                a3 = a3 + a4
                a4 = a0 - a3
                a0 = a0 + a3
                a3 = a1 - a2
                a1 = a1 + a2
                t[xOff + 0] = a0 + a1
                t[xOff + 4] = (a0 - a1) * 0.70710677
                a5 = a5 + a6
                a6 = (a6 + a7) * 0.70710677
                a7 = a7 + xt
                a3 = (a3 + a4) * 0.70710677
                a5 = a5 - a7 * 0.198912367
                a7 = a7 + a5 * 0.382683432
                a5 = a5 - a7 * 0.198912367
                a0 = xt - a6
                xt = xt + a6
                t[xOff + 1] = (xt + a7) * 0.50979561
                t[xOff + 2] = (a4 + a3) * 0.54119611
                t[xOff + 3] = (a0 - a5) * 0.60134488
                t[xOff + 5] = (a0 + a5) * 0.89997619
                t[xOff + 6] = (a4 - a3) * 1.30656302 // cjlint-ignore !G.OTH.02 AM 蝶形系数，非敏感信息
                t[xOff + 7] = (xt - a7) * 2.56291556
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
        sink += grbuf[0] + t[0]
        c += 1
    }
    return (Float64((MonoTime.now() - t0).toNanoseconds()), sink)
}

/// V6：每声道每 granule 的固定开销（分配清零 + 状态拷入 + 状态回写）。
private func uV6(rounds: Int64): (Float64, Float64) {
    let lins = Array<Float64>(2112, repeat: 0.0)
    let qmf = Array<Float64>(960, repeat: 0.031)
    var sink = 0.0
    let t0 = MonoTime.now()
    var r: Int64 = 0
    while (r < rounds) {
        let pcmBuffer = Array<Float32>(2304, repeat: 0.0)
        qmf.copyTo(lins, 0, 0, 960)
        var band: Int64 = 0
        while (band < 18) {
            lins[18 * 64 + band] = lins[band]
            band = band + 2
        }
        var qi: Int64 = 0
        while (qi < 960) {
            qmf[qi] = lins[18 * 64 + qi]
            qi = qi + 2
        }
        sink += Float64(pcmBuffer[0]) + qmf[0] + lins[0]
        r += 1
    }
    return (Float64((MonoTime.now() - t0).toNanoseconds()), sink)
}

@Test
class Mp3SynthMicro2Test {
    /// 补齐缺口：把 V4/V5/V6 折算成 ms/帧，并与第一份的三项合成总账。
    @TestCase
    func synthCostGapAttribution() {
        let iItersPerFrame: Float64 = 540.0
        let dctCallsPerFrame: Float64 = 4.0
        let granuleRoundsPerFrame: Float64 = 4.0

        var v4Ns = 1.0e18
        var s4 = 0.0
        var r = 0
        while (r < 5) {
            let (ns, s) = uV4(Int64(iItersPerFrame * 100.0))
            if (ns < v4Ns) {
                v4Ns = ns
            }
            s4 += s
            r += 1
        }
        var v5Ns = 1.0e18
        var s5 = 0.0
        r = 0
        while (r < 5) {
            let (ns, s) = uV5(Int64(dctCallsPerFrame * 200.0))
            if (ns < v5Ns) {
                v5Ns = ns
            }
            s5 += s
            r += 1
        }
        var v6Ns = 1.0e18
        var s6 = 0.0
        r = 0
        while (r < 5) {
            let (ns, s) = uV6(Int64(granuleRoundsPerFrame * 500.0))
            if (ns < v6Ns) {
                v6Ns = ns
            }
            s6 += s
            r += 1
        }

        let perI = v4Ns / (iItersPerFrame * 100.0)
        let perDct = v5Ns / (dctCallsPerFrame * 200.0)
        let perRound = v6Ns / (granuleRoundsPerFrame * 500.0)
        let msV4 = perI * iItersPerFrame / 1.0e6
        let msV5 = perDct * dctCallsPerFrame / 1.0e6
        let msV6 = perRound * granuleRoundsPerFrame / 1.0e6
        // 第一份的三项（同次测量口径，见其输出）
        let msFirst = 1.2
        let sum = msFirst + msV4 + msV5 + msV6

        println(
            "MICRO2 单次成本：i 循环蝶形 ${g1(perI)} ns、dctII ${g1(perDct)} ns、" +
                "每声道每 granule 固定开销 ${g1(perRound)} ns")
        println("MICRO2 每帧折算（ms/帧）：i 蝶形 ${g1(msV4)} + dctII ${g1(msV5)} + " + "固定开销 ${g1(msV6)}")
        println(
            "MICRO2 累计：第一份 1.2 + 本轮 ${g1(msV4 + msV5 + msV6)} = ${g1(sum)} ms/帧，" +
                "对照合成实测 2.10 ⇒ 解释 ${g1(sum / 2.10 * 100.0)}%，缺口 ${g1(2.10 - sum)} ms/帧")
        println("MICRO2 sink=${g1(s4 + s5 + s6)}（仅阻止优化）")
    }
}
