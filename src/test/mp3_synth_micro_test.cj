package audio4cj.test

import std.time.*

/* ============================================================================
 * 合成段微基准 —— 把"合成 2.10 ms/帧"逐项定责，而不是再靠推理挑目标
 *
 * 【为什么需要它】
 *   分段计时已给出当期分布（合成 2.10 / 频谱链 1.21 / 旁信息 0.37 ms/帧，残差 0.8%），
 *   但"合成里什么最贵"此前四次都靠**推理**挑目标，其中三次实测无收益（证伪）。
 *   微基准把每项成本单独量出来，再用「每帧次数 × 单次成本」折算成 ms/帧 ——
 *   与分段实测的 2.10 ms/帧一对，就知道合成的开销是否已被解释完、缺口在哪一项。
 *
 * 【与生产代码的关系】
 *   只**复刻形态**，不调用生产函数：热循环的 key 是"2 次表取数 + 8 次数组取数 +
 *   16 次浮点 + 三分支"的**每迭代成本**，本文件按同样形态重建（表用 64 项，
 *   生产是 240 项，两者都在 L1 内 ⇒ 单次取数成本同量级，跨度差异已在此标注）。
 *   结果只能用来排**优先级**，最终仍以整段实测（phase_timing）为准。
 *
 * 【每帧次数（来自生产代码的结构）】
 *   · k 迭代：15 个 i × 8 个 k × 9 次 synth × 2 声道 × 2 granule = 4320 次/帧
 *   · i 迭代：15 × 9 × 2 × 2 = 540 次/帧
 *   · scalePcm：8 次/每个 i × 540 = 4320 次/帧
 *   · synthPair：4 次/每次 synth × 9 × 2 × 2 = 144 次/帧
 * ========================================================================== */

/// 复刻 G_WIN 的取数形态（生产 240 项，这里 64 项；两者都在 L1 内）。
private let U_WIN: Array<Float64> = [
    0.000000,
    0.003068,
    0.006136,
    0.009204,
    0.012272,
    0.015340,
    0.018408,
    0.021476,
    0.024544,
    0.027612,
    0.030680,
    0.033748,
    0.036816,
    0.039884,
    0.042952,
    0.046020,
    0.049088,
    0.052156,
    0.055224,
    0.058292,
    0.061360,
    0.064428,
    0.067496,
    0.070564,
    0.073632,
    0.076700,
    0.079768,
    0.082836,
    0.085904,
    0.088972,
    0.092040,
    0.095108,
    0.098176,
    0.101244,
    0.104312,
    0.107380,
    0.110448,
    0.113516,
    0.116584,
    0.119652,
    0.122720,
    0.125788,
    0.128856,
    0.131924,
    0.134992,
    0.138060,
    0.141128,
    0.144196,
    0.147264,
    0.150332,
    0.153400,
    0.156468,
    0.159536,
    0.162604,
    0.165672,
    0.168740,
    0.171808,
    0.174876,
    0.177944,
    0.181012,
    0.184080,
    0.187148,
    0.190216,
    0.193284
]

/// 复刻 `scalePcm` 的形态（缩放 + 钳位 + 转 Float32）。
private func uScalePcm(sample: Float64): Float32 {
    var v = sample * 32768.0
    if (v > 32767.0) {
        v = 32767.0
    } else if (v < -32768.0) {
        v = -32768.0
    }
    return Float32(v)
}

/// 一列小数（避免打印 `${Float64}` 的长尾数字）。
private func f1(x: Float64): String {
    let v = Int64(x * 10.0 + 0.5)
    return "${v / 10}.${v % 10}"
}

/// V0：当前 k 迭代形态（2 表取数 + 8 数组取数 + 16 浮点 + 三分支），按 i/k 两层循环。
/// 返回 (耗时 ns, 消费用的 sink)。
private func uV0(iIters: Int64): (Float64, Float64) {
    let buf = Array<Float64>(2112, repeat: 0.0)
    var p: Int64 = 0
    while (p < 2112) {
        buf[p] = Float64((p % 23)) * 0.01 - 0.11
        p += 1
    }
    var sink = 0.0
    let t0 = MonoTime.now()
    var it: Int64 = 0
    while (it < iIters) {
        let iLoop = 14 - (it % 15)
        var a0 = 0.0
        var a1 = 0.0
        var a2 = 0.0
        var a3 = 0.0
        var b0 = 0.0
        var b1 = 0.0
        var b2 = 0.0
        var b3 = 0.0
        let wBase = (14 - iLoop) * 16
        var k: Int64 = 0
        while (k < 8) {
            let w0 = U_WIN[(wBase + 2 * k) & 63]
            let w1 = U_WIN[(wBase + 2 * k + 1) & 63]
            let vz = 960 + 4 * iLoop - 64 * k
            let vy = 960 + 4 * iLoop - 64 * (15 - k)
            let z0 = buf[vz + 0]
            let z1 = buf[vz + 1]
            let z2 = buf[vz + 2]
            let z3 = buf[vz + 3]
            let y0 = buf[vy + 0]
            let y1 = buf[vy + 1]
            let y2 = buf[vy + 2]
            let y3 = buf[vy + 3]
            if (k == 0) {
                b0 = z0 * w1 + y0 * w0
                b1 = z1 * w1 + y1 * w0
                b2 = z2 * w1 + y2 * w0
                b3 = z3 * w1 + y3 * w0
                a0 = z0 * w0 - y0 * w1
                a1 = z1 * w0 - y1 * w1
                a2 = z2 * w0 - y2 * w1
                a3 = z3 * w0 - y3 * w1
            } else if ((k & 1) == 1) {
                b0 += z0 * w1 + y0 * w0
                b1 += z1 * w1 + y1 * w0
                b2 += z2 * w1 + y2 * w0
                b3 += z3 * w1 + y3 * w0
                a0 += y0 * w1 - z0 * w0
                a1 += y1 * w1 - z1 * w0
                a2 += y2 * w1 - z2 * w0
                a3 += y3 * w1 - z3 * w0
            } else {
                b0 += z0 * w1 + y0 * w0
                b1 += z1 * w1 + y1 * w0
                b2 += z2 * w1 + y2 * w0
                b3 += z3 * w1 + y3 * w0
                a0 += z0 * w0 - y0 * w1
                a1 += z1 * w0 - y1 * w1
                a2 += z2 * w0 - y2 * w1
                a3 += z3 * w0 - y3 * w1
            }
            k += 1
        }
        sink += a0 + a1 + a2 + a3 + b0 + b1 + b2 + b3
        it += 1
    }
    return (Float64((MonoTime.now() - t0).toNanoseconds()), sink)
}

/// V2：`scalePcm` 的调用形态。
private func uV2(calls: Int64): (Float64, Float64) {
    var sink = 0.0
    let t0 = MonoTime.now()
    var c: Int64 = 0
    while (c < calls) {
        sink += Float64(uScalePcm(Float64(c % 100) * 0.37 - 18.0))
        c += 1
    }
    return (Float64((MonoTime.now() - t0).toNanoseconds()), sink)
}

/// V3：`synthPair` 的取数形态（15 条 Z + 8 条 Y，步长 64）。
private func uV3(pairs: Int64): (Float64, Float64) {
    let buf = Array<Float64>(2112, repeat: 0.0)
    var p: Int64 = 0
    while (p < 2112) {
        buf[p] = Float64((p % 19)) * 0.02 - 0.17
        p += 1
    }
    var sink = 0.0
    let t0 = MonoTime.now()
    var c: Int64 = 0
    while (c < pairs) {
        let zOff = (c % 4) * 4 + 61
        var acc = 0.0
        var t: Int64 = 0
        while (t < 15) {
            acc += buf[zOff + t * 64] * U_WIN[(t * 5) & 63]
            t += 1
        }
        var y: Int64 = 0
        while (y < 8) {
            acc += buf[zOff + 2 + y * 2 * 64] * U_WIN[(y * 7 + 3) & 63]
            y += 1
        }
        sink += acc
        c += 1
    }
    return (Float64((MonoTime.now() - t0).toNanoseconds()), sink)
}

@Test
class Mp3SynthMicroTest {
    /// 打印合成的三项单次成本与每帧折算（诊断用，不做断言 —— 它量的是形态而非产物）。
    @TestCase
    func synthCostAttribution() {
        // 每帧次数
        let kItersPerFrame: Float64 = 4320.0
        let iItersPerFrame: Float64 = 540.0
        let scaleCallsPerFrame: Float64 = 4320.0
        let pairCallsPerFrame: Float64 = 144.0
        // 每帧指令量：k 迭代 / 8 = i 迭代
        let iItersPerRound: Int64 = Int64(iItersPerFrame * 100.0)

        var v0Ns = 1.0e18
        var sink0 = 0.0
        var r = 0
        while (r < 5) {
            let (ns, s) = uV0(iItersPerRound)
            if (ns < v0Ns) {
                v0Ns = ns
            }
            sink0 += s
            r += 1
        }
        var v2Ns = 1.0e18
        var sink2 = 0.0
        r = 0
        while (r < 5) {
            let (ns, s) = uV2(Int64(scaleCallsPerFrame * 100.0))
            if (ns < v2Ns) {
                v2Ns = ns
            }
            sink2 += s
            r += 1
        }
        var v3Ns = 1.0e18
        var sink3 = 0.0
        r = 0
        while (r < 5) {
            let (ns, s) = uV3(Int64(pairCallsPerFrame * 100.0))
            if (ns < v3Ns) {
                v3Ns = ns
            }
            sink3 += s
            r += 1
        }

        // 每帧折算（ms/帧）：单次 ns × 每帧次数 / 1e6
        let kIterNs = v0Ns / 432000.0 // 100 帧的 k 迭代数 = 4320×100
        let scaleNs = v2Ns / 432000.0
        let pairNs = v3Ns / 14400.0
        let msV0 = kIterNs * kItersPerFrame / 1.0e6
        let msV2 = scaleNs * scaleCallsPerFrame / 1.0e6
        let msV3 = pairNs * pairCallsPerFrame / 1.0e6
        let sum = msV0 + msV2 + msV3

        println(
            "MICRO 单次成本：k 迭代 ${f1(kIterNs)} ns、scalePcm ${f1(scaleNs)} ns、" +
                "synthPair ${f1(pairNs)} ns（各取 5 轮最小值）")
        println(
            "MICRO 每帧折算（ms/帧）：k 迭代形态 ${f1(msV0)} + scalePcm ${f1(msV2)} + " +
                "synthPair ${f1(msV3)} = ${f1(sum)}")
        println(
            "MICRO 对照分段实测：合成 2.10 ms/帧 ⇒ " +
                "本三项解释 ${f1(sum / 2.10 * 100.0)}%，缺口 ${f1(2.10 - sum)} ms/帧")
        // 防死代码消除：把 sink 打进输出
        println("MICRO sink=${f1(sink0 + sink2 + sink3)}（仅为阻止优化，无意义）")
    }
}
