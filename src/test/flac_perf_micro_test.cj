package audio4cj.test

import std.binary.*
import std.time.*

/* ============================================================================
 * FLAC 地板微基准：把"每采样固定成本"拆成"趟"，回答"内存流量还是每值开销"
 *
 * 【它解决什么问题】
 *   实测（见 docs/...evaluation.md 第八轮）：
 *     · 数字静音（CONSTANT 子帧，几乎不含内容工作）在 bs=1024 下要 13.5~20.4 ns/采样值，
 *       bs=4096 下 15.0~18.8，而同文件 ffmpeg 只要 4.4 / 1.4 —— 差距 3~15 倍；
 *     · 我们把同一份静音的读数在同一台机上重复 6 次，极差 25%（静音 1024 档甚至 52%），
 *       而有内容的文件（噪声/音乐）稳定在 ±5%。
 *   ⇒ 这条 12~22 ns/采样值的"地板"是当前第一大头（青花瓷 L5 的 48%），但**它花在哪一趟**
 *     不能靠推理：本项目已多次证明"没有当期实测不要指认瓶颈"。
 *
 * 【方法：只复刻形态，不调用生产代码】
 *   把生产代码里对 blockSize 大小缓冲的每一趟访问**按形状**搬进来（同样的元素类型、
 *   同样的访存方向、同样的循环结构），逐趟单独计时 ⇒ 得到"每趟每采样值多少 ns"。
 *   然后与"静音路径实际要跑的趟数"相加，与实测地板对照：
 *     · 若相加 ≈ 实测地板 ⇒ 地板就是这些趟的访存成本（**内存流量**）⇒ 该做"减少趟数/合并缓冲"；
 *     · 若相加 ≪ 实测地板 ⇒ 地板另有来源（每值循环/分支/调用开销）⇒ 该做局部改写。
 *
 * 【对应关系（生产代码坐标，均来自实读）】
 *   V1 常量填充        ← flac_frame.cj:449  decodeConstant：新建 bs 长 Int64 并逐值写
 *   V2 仅分配+清零     ← flac_frame.cj:33   flacAllocInt64：Array<Int64>(n, repeat: 0)
 *   V3 装配 f32        ← flac_bitstream.cj:739 interleave：读 Int64、写 Float32（含 /scale）
 *   V4 float→字节      ← pcm/bitview.cj:72  f32ToBytes：每值 4 字节小端写
 *   V5 字节→Float32    ← pcm/bitview.cj:35  reinterpretF32Bytes：读字节、写 Float32
 *   V6 残差+重建两趟   ← flac_frame.cj:334  decodeResidual + :476 decodeFixed
 *   V7 去相关          ← flac_frame.cj:705  applyChannelDecorrelation：读 2 写 2
 *
 * 【两处"形状近似"（必须声明，别当精确值读）】
 *   · V4/V5 用 `writeLittleEndian` 逐值拆字节（与 diag_dump_test 同形），而生产代码在
 *     `pcm/bitview.cj` 里走 `CPointer` 裸指针逐字节拷贝（本仓规约把 unsafe 限定在该文件，
 *     测试不得触碰）⇒ 本复刻**可能高估**这两趟；
 *   · 输入缓冲在计时前预置（真实代码里是上一趟的产物），故 V3~V7 只算"该趟本身"，
 *     分配成本单列为 V2。
 *
 * 【与门槛/门禁的关系】
 *   本文件**无断言、只打印**（与 `mp3_synth_micro*_test.cj` 同约定）：它是诊断件，
 *   不是判据；正确性由 golden 与各格式用例负责。
 *
 * 【运行】cjpm test --filter FlacPerfMicroTest --show-all-output --no-color
 * ========================================================================== */

/// 让每趟的计算结果"有去处"，避免被优化掉。
private var FM_SINK: Int64 = 0

/// 每采样值折算用：绝对值 = 采样值个数 = frames × blockSize × channels。
private func fmPerValue(totalNs: Int64, frames: Int64, bs: Int64, ch: Int64): Float64 {
    Float64(totalNs) / Float64(frames * bs * ch)
}

/// V1 常量填充：新建 bs 长 Int64（每声道一个）并逐值写入【写一趟】
private func fmConstFill(frames: Int64, bs: Int64, ch: Int64): Int64 {
    var sink: Int64 = 0
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        var c: Int64 = 0
        while (c < ch) {
            let out = Array<Int64>(bs, repeat: 0)
            var i: Int64 = 0
            while (i < bs) {
                out[i] = 7
                i += 1
            }
            sink += out[bs - 1]
            c += 1
        }
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

/// V2 仅分配+清零：`Array<Int64>(bs, repeat: 0)`（每声道一个）
private func fmAllocOnly(frames: Int64, bs: Int64, ch: Int64): Int64 {
    var sink: Int64 = 0
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        var c: Int64 = 0
        while (c < ch) {
            let out = Array<Int64>(bs, repeat: 0)
            sink += out[0]
            c += 1
        }
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

/// V3 装配 f32：读 bs 长 Int64 × ch，写 Float32(bs × ch)，含 `/ _scale`【读 1 + 写 1】
private func fmInterleave(frames: Int64, bs: Int64, ch: Int64, src: Array<Int64>, scale: Float32): Int64 {
    var sink: Int64 = 0
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        let out = Array<Float32>(bs * ch, repeat: 0.0)
        var i: Int64 = 0
        while (i < bs) {
            var c: Int64 = 0
            while (c < ch) {
                out[i * ch + c] = Float32(src[i]) / scale
                c += 1
            }
            i += 1
        }
        sink += Int64(out[bs * ch - 1])
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

/// V4 float→字节：读 Float32，逐值拆成 4 字节小端写入 UInt8（形状近似，见文件头）
private func fmF32ToBytes(frames: Int64, count: Int64, src: Array<Float32>): Int64 {
    var sink: Int64 = 0
    let quad = Array<UInt8>(4, repeat: 0)
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        let out = Array<UInt8>(count * 4, repeat: 0)
        var i: Int64 = 0
        while (i < count) {
            src[i].writeLittleEndian(quad)
            out[i * 4] = quad[0]
            out[i * 4 + 1] = quad[1]
            out[i * 4 + 2] = quad[2]
            out[i * 4 + 3] = quad[3]
            i += 1
        }
        sink += Int64(out[0])
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

/// V5 字节→Float32：读 UInt8，写 Float32（形状近似，见文件头）
private func fmBytesToF32(frames: Int64, count: Int64, src: Array<UInt8>): Int64 {
    var sink: Int64 = 0
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        let out = Array<Float32>(count, repeat: 0.0)
        var i: Int64 = 0
        while (i < count) {
            out[i] = Float32(src[i * 4])
            i += 1
        }
        sink += Int64(out[count - 1])
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

/// V6 残差 + 重建两趟：先逐值写残差数组，再逐值读残差写重建数组【写 1 + 读1写1】
private func fmResidualPlusRebuild(frames: Int64, bs: Int64, ch: Int64): Int64 {
    var sink: Int64 = 0
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        var c: Int64 = 0
        while (c < ch) {
            let residual = Array<Int64>(bs, repeat: 0)
            var i: Int64 = 0
            while (i < bs) {
                residual[i] = i % 5 - 2
                i += 1
            }
            let out = Array<Int64>(bs, repeat: 0)
            out[0] = residual[0]
            i = 1
            while (i < bs) {
                out[i] = out[i - 1] + residual[i]
                i += 1
            }
            sink += out[bs - 1]
            c += 1
        }
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

/// V7 去相关：读 a/b，写 left/right 两个新数组【读 2 + 写 2】
private func fmDecorrelation(frames: Int64, bs: Int64, a: Array<Int64>, b: Array<Int64>): Int64 {
    var sink: Int64 = 0
    let t0 = MonoTime.now()
    var f: Int64 = 0
    while (f < frames) {
        let left = Array<Int64>(bs, repeat: 0)
        let right = Array<Int64>(bs, repeat: 0)
        var i: Int64 = 0
        while (i < bs) {
            left[i] = b[i] + ((a[i] - b[i]) >> 1)
            right[i] = a[i]
            i += 1
        }
        sink += left[bs - 1] + right[bs - 1]
        f += 1
    }
    let dt = (MonoTime.now() - t0).toNanoseconds()
    FM_SINK += sink
    dt
}

@Test
class FlacPerfMicroTest {
    /// 逐趟计时，按 blockSize 各测一遍（每档取 5 次最小值）
    @TestCase
    func floorDecompositionPerPass() {
        let ch: Int64 = 2
        let blocks = [1024, 4096]
        for (bs in blocks) {
            // 与 120 s / 44.1 kHz / 立体声 等价的总采样值数：由块长决定帧数
            let frames = 5292000 / bs

            let scale: Float32 = Float32(Int64(1) << 15)
            let srcInt = Array<Int64>(bs, repeat: 12345)
            let srcF32 = Array<Float32>(bs * ch, repeat: 0.5)
            let srcBytes = Array<UInt8>(bs * ch * 4, repeat: 3)
            let srcA = Array<Int64>(bs, repeat: 1000)
            let srcB = Array<Int64>(bs, repeat: -1000)

            let names = ["V1 常量填充(写1趟)", "V2 仅分配+清零", "V3 装配f32(读1写1)", "V4 f32->字节(读1写1)",
                "V5 字节->f32(读1写1)", "V6 残差+重建(写1+读写1)", "V7 去相关(读2写2)"]
            let best = Array<Float64>(names.size, repeat: 1.0e18)

            var round: Int64 = 0
            while (round < 5) {
                let v1 = fmPerValue(fmConstFill(frames, bs, ch), frames, bs, ch)
                let v2 = fmPerValue(fmAllocOnly(frames, bs, ch), frames, bs, ch)
                let v3 = fmPerValue(fmInterleave(frames, bs, ch, srcInt, scale), frames, bs, ch)
                let v4 = fmPerValue(fmF32ToBytes(frames, bs * ch, srcF32), frames, bs, ch)
                let v5 = fmPerValue(fmBytesToF32(frames, bs * ch, srcBytes), frames, bs, ch)
                let v6 = fmPerValue(fmResidualPlusRebuild(frames, bs, ch), frames, bs, ch)
                let v7 = fmPerValue(fmDecorrelation(frames, bs, srcA, srcB), frames, bs, ch)
                let all = [v1, v2, v3, v4, v5, v6, v7]
                var k: Int64 = 0
                while (k < all.size) {
                    if (all[k] < best[k]) {
                        best[k] = all[k]
                    }
                    k += 1
                }
                round += 1
            }

            println("MICRO| blockSize=${bs} frames=${frames} channels=${ch} 单位=ns/采样值（除数 ${frames * bs * ch}）")
            var k: Int64 = 0
            while (k < names.size) {
                println("MICRO|   ${names[k]} = ${best[k]}")
                k += 1
            }
            // 静音（CONSTANT）路径：V2×2(每声道各分配一个) + V1×2(逐声道填充) + V3 + V4 + V5
            let sil = best[1] * 2.0 + best[0] * 2.0 + best[2] + best[3] + best[4]
            // FIXED/LPC + 立体声去相关：静音路径 + V6×2(两声道各两趟) + V7
            let full = sil + best[5] * 2.0 + best[6]
            println("MICRO|   => 静音路径各趟之和 ≈ ${sil}")
            println("MICRO|   => 含残差/重建/去相关的各趟之和 ≈ ${full}")
        }
        println("MICRO| sink=${FM_SINK}（仅用于阻止优化）")
    }
}
