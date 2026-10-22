package audio4cj.format

import audio4cj.core.CorruptedFileException
import std.math.{cos, sin}

/* ============================================================================
 * Vorbis IMDCT（纯仓颉）
 *
 * 【算法来源】
 *   移植自 stb_vorbis 的 `inverse_mdct_naive`（公有领域 / MIT 双许可）。
 *   它是同一变换的数组下标版本，比 stb 的指针优化版更容易逐行核对；
 *   本项目当前以正确性优先，性能留在后续阶段（见 docs/codec-expansion-assessment.md）。
 *
 * 【为什么用 naive 版而不是直接写 DCT-IV】
 *   naive 版是 O(n log n)：核心是 step 3 的蝶形；直接按定义算 IMDCT 是 O(n²)，
 *   2048 点块每秒要跑约 43 次，O(n²) 会明显拖慢解码。naive 版仍然是 stb
 *   验证过的结构，只是没有做指针/寄存器级优化。
 *
 * 【与 stb 优化版的三处差异（必须同时满足，否则输出幅度/相位错）】
 *   1. B 表不乘 0.5（naive 版用 s=0.5 补偿；优化版把 0.5 吸收进 B）。
 *   2. step 3 的 u/w ping-pong 用显式拷贝，不能省。
 *   3. 输出缩放 s=0.5，不是 n/4。
 *
 * 【窗函数】
 *   window[i] = sin(0.5π * sin((i+0.5)/n2 * 0.5π)^2)，与 stb 的
 *   compute_window 逐字一致；重叠相加时前半窗与后半窗互为镜像。
 * ========================================================================== */

/// 单个块大小的 IMDCT 常量表。
protected class VorbisMdctTables {
    protected let n: Int64
    protected let n2: Int64
    protected let n4: Int64
    protected let n8: Int64
    protected let n3_4: Int64
    protected let ld: Int64
    protected let a: Array<Float32>
    protected let b: Array<Float32>
    protected let c: Array<Float32>
    protected let window: Array<Float32>
    protected let bitrev: Array<Int64>

    protected init(n: Int64) {
        this.n = n
        this.n2 = n >> 1
        this.n4 = n >> 2
        this.n8 = n >> 3
        this.n3_4 = n - n4
        this.ld = vorbisIlog(n) - 1

        let pi = 3.14159265358979323846
        a = Array<Float32>(this.n2, repeat: 0.0)
        b = Array<Float32>(this.n2, repeat: 0.0)
        c = Array<Float32>(this.n4, repeat: 0.0)
        window = Array<Float32>(this.n2, repeat: 0.0)
        bitrev = Array<Int64>(this.n8, repeat: 0)

        var k: Int64 = 0
        var k2: Int64 = 0
        while (k < this.n4) {
            a[k2] = Float32(cos(4.0 * Float64(k) * pi / Float64(n)))
            a[k2 + 1] = Float32(-sin(4.0 * Float64(k) * pi / Float64(n)))
            b[k2] = Float32(cos(Float64(k2 + 1) * pi / Float64(n) / 2.0))
            b[k2 + 1] = Float32(sin(Float64(k2 + 1) * pi / Float64(n) / 2.0))
            k += 1
            k2 += 2
        }

        k = 0
        k2 = 0
        while (k < this.n8) {
            c[k2] = Float32(cos(2.0 * Float64(k2 + 1) * pi / Float64(n)))
            c[k2 + 1] = Float32(-sin(2.0 * Float64(k2 + 1) * pi / Float64(n)))
            k += 1
            k2 += 2
        }

        var i: Int64 = 0
        while (i < this.n2) {
            let inner = sin((Float64(i) + 0.5) / Float64(this.n2) * 0.5 * pi)
            window[i] = Float32(sin(0.5 * pi * inner * inner))
            i += 1
        }

        i = 0
        while (i < this.n8) {
            bitrev[i] = vorbisBitReverse32(i) >> (32 - this.ld + 3)
            i += 1
        }
    }
}

/// IMDCT 执行器（持有两份常量表与一份复用的临时数组）。
protected class VorbisMdct {
    private let _small: VorbisMdctTables
    private let _large: VorbisMdctTables
    private let _u: Array<Float32>
    private let _v: Array<Float32>
    private let _w: Array<Float32>
    private let _x: Array<Float32>

    protected init(blocksize0: Int64, blocksize1: Int64) {
        _small = VorbisMdctTables(blocksize0)
        _large = VorbisMdctTables(blocksize1)
        _u = Array<Float32>(blocksize1, repeat: 0.0)
        _v = Array<Float32>(blocksize1, repeat: 0.0)
        _w = Array<Float32>(blocksize1, repeat: 0.0)
        _x = Array<Float32>(blocksize1, repeat: 0.0)
    }

    /// 对 buffer[0..n) 做 IMDCT，输入为 buffer[0..n/2) 的频域系数。
    protected func inverse(buffer: Array<Float32>, n: Int64, blockType: Int64): Unit {
        if (n <= 0 || blockType < 0 || blockType > 1) {
            throw CorruptedFileException("Vorbis IMDCT 参数非法：n=${n}, blockType=${blockType}")
        }
        let t = if (blockType == 0) {
            _small
        } else {
            _large
        }
        if (n != t.n) {
            throw CorruptedFileException("Vorbis IMDCT 块大小与表不匹配：${n} vs ${t.n}")
        }

        let u = _u
        let v = _v
        let w = _w
        let x = _x
        let n2 = t.n2
        let n4 = t.n4
        let n8 = t.n8
        let n3_4 = t.n3_4

        // copy and reflect spectral data
        var k: Int64 = 0
        while (k < n2) {
            u[k] = buffer[k]
            k += 1
        }
        while (k < n) {
            u[k] = -buffer[n - k - 1]
            k += 1
        }

        // step 1
        var k2: Int64 = 0
        var k4: Int64 = 0
        k = 0
        while (k < n4) {
            v[n - k4 - 1] = (u[k4] - u[n - k4 - 1]) * t.a[k2] - (u[k4 + 2] - u[n - k4 - 3]) * t.a[k2 + 1]
            v[n - k4 - 3] = (u[k4] - u[n - k4 - 1]) * t.a[k2 + 1] + (u[k4 + 2] - u[n - k4 - 3]) * t.a[k2]
            k += 1
            k2 += 2
            k4 += 4
        }

        // step 2
        k = 0
        k4 = 0
        while (k < n8) {
            w[n2 + 3 + k4] = v[n2 + 3 + k4] + v[k4 + 3]
            w[n2 + 1 + k4] = v[n2 + 1 + k4] + v[k4 + 1]
            w[k4 + 3] = (v[n2 + 3 + k4] - v[k4 + 3]) * t.a[n2 - 4 - k4] - (v[n2 + 1 + k4] - v[k4 + 1]) * t.a[n2 - 3 - k4]
            w[k4 + 1] = (v[n2 + 1 + k4] - v[k4 + 1]) * t.a[n2 - 4 - k4] + (v[n2 + 3 + k4] - v[k4 + 3]) * t.a[n2 - 3 - k4]
            k += 1
            k4 += 4
        }

        // step 3
        let ld = t.ld
        var l: Int64 = 0
        while (l < ld - 3) {
            let k0 = n >> (l + 2)
            let k1 = Int64(1) << (l + 3)
            let rlim = n >> (l + 4)
            let s2lim = Int64(1) << (l + 2)
            var r4: Int64 = 0
            var r: Int64 = 0
            while (r < rlim) {
                var s2: Int64 = 0
                while (s2 < s2lim) {
                    let i1 = n - 1 - k0 * s2 - r4
                    let i2 = n - 1 - k0 * (s2 + 1) - r4
                    let i3 = n - 3 - k0 * s2 - r4
                    let i4 = n - 3 - k0 * (s2 + 1) - r4
                    u[i1] = w[i1] + w[i2]
                    u[i3] = w[i3] + w[i4]
                    u[i2] = (w[i1] - w[i2]) * t.a[r * k1] - (w[i3] - w[i4]) * t.a[r * k1 + 1]
                    u[i4] = (w[i3] - w[i4]) * t.a[r * k1] + (w[i1] - w[i2]) * t.a[r * k1 + 1]
                    s2 += 2
                }
                r4 += 4
                r += 1
            }
            if (l + 1 < ld - 3) {
                var i: Int64 = 0
                while (i < n) {
                    w[i] = u[i]
                    i += 1
                }
            }
            l += 1
        }

        // step 4
        var i: Int64 = 0
        while (i < n8) {
            let j = t.bitrev[i]
            if (i == j) {
                let i8 = i << 3
                v[i8 + 1] = u[i8 + 1]
                v[i8 + 3] = u[i8 + 3]
                v[i8 + 5] = u[i8 + 5]
                v[i8 + 7] = u[i8 + 7]
            } else if (i < j) {
                let i8 = i << 3
                let j8 = j << 3
                v[j8 + 1] = u[i8 + 1]
                v[i8 + 1] = u[j8 + 1]
                v[j8 + 3] = u[i8 + 3]
                v[i8 + 3] = u[j8 + 3]
                v[j8 + 5] = u[i8 + 5]
                v[i8 + 5] = u[j8 + 5]
                v[j8 + 7] = u[i8 + 7]
                v[i8 + 7] = u[j8 + 7]
            }
            i += 1
        }

        // step 5
        k = 0
        while (k < n2) {
            w[k] = v[k * 2 + 1]
            k += 1
        }

        // step 6
        k = 0
        k2 = 0
        k4 = 0
        while (k < n8) {
            u[n - 1 - k2] = w[k4]
            u[n - 2 - k2] = w[k4 + 1]
            u[n3_4 - 1 - k2] = w[k4 + 2]
            u[n3_4 - 2 - k2] = w[k4 + 3]
            k += 1
            k2 += 2
            k4 += 4
        }

        // step 7
        k = 0
        k2 = 0
        while (k < n8) {
            v[n2 + k2] = (u[n2 + k2] + u[n - 2 - k2] + t.c[k2 + 1] * (u[n2 + k2] - u[n - 2 - k2]) + t.c[k2] * (u[n2 + k2 +
                    1] + u[n - 2 - k2 + 1])) / 2.0
            v[n - 2 - k2] = (u[n2 + k2] + u[n - 2 - k2] - t.c[k2 + 1] * (u[n2 + k2] - u[n - 2 - k2]) - t.c[k2] * (u[n2 +
                    k2 + 1] + u[n - 2 - k2 + 1])) / 2.0
            v[n2 + 1 + k2] = (u[n2 + 1 + k2] - u[n - 1 - k2] + t.c[k2 + 1] * (u[n2 + 1 + k2] + u[n - 1 - k2]) -
                t.c[k2] * (u[n2 + k2] - u[n - 2 - k2])) / 2.0
            v[n - 1 - k2] = (-u[n2 + 1 + k2] + u[n - 1 - k2] + t.c[k2 + 1] * (u[n2 + 1 + k2] + u[n - 1 - k2]) -
                t.c[k2] * (u[n2 + k2] - u[n - 2 - k2])) / 2.0
            k += 1
            k2 += 2
        }

        // step 8
        k = 0
        k2 = 0
        while (k < n4) {
            x[k] = v[k2 + n2] * t.b[k2] + v[k2 + 1 + n2] * t.b[k2 + 1]
            x[n2 - 1 - k] = v[k2 + n2] * t.b[k2 + 1] - v[k2 + 1 + n2] * t.b[k2]
            k += 1
            k2 += 2
        }

        // decode kernel to output
        let s: Float32 = 0.5
        i = 0
        while (i < n4) {
            buffer[i] = s * x[i + n4]
            i += 1
        }
        while (i < n3_4) {
            buffer[i] = -s * x[n3_4 - i - 1]
            i += 1
        }
        while (i < n) {
            buffer[i] = -s * x[i - n3_4]
            i += 1
        }
    }

    /// 取某个块大小的窗表（长度 n/2）。
    protected func window(blockType: Int64): Array<Float32> {
        if (blockType == 0) {
            _small.window
        } else {
            _large.window
        }
    }
}
