package audio4cj.test

import audio4cj.format.VorbisMdct
import std.math.{cos, sin}

/* ============================================================================
 * Vorbis IMDCT 单元测试
 *
 * 参考实现直接用 IMDCT 定义：
 *   y[i] = sum_{j=0}^{n/2-1} x[j] * cos(pi/(2n) * (2i+1+n/2) * (2j+1))
 * 这是 stb_vorbis 里 inverse_mdct_slow 实际采用的公式（无额外倍率）。
 *
 * 为什么要用 O(n²) 的定义式做基准：
 *   IMDCT 的蝶形结构一旦某个下标写错，输出仍然是"看起来像音频"的噪声，
 *   仅靠听感或能量统计很难定位。定义式独立于蝶形实现，能直接暴露相位/幅度错。
 *
 * 容差取 1e-4：输入是 Float32，256 点块累加约 128 项，Float32 舍入误差
 * 在 1e-5 量级；1e-4 既不会误报，也能抓住真正的算法错误。
 * ========================================================================== */
@Test
class VorbisMdctTest {
    @TestCase
    func matchesDirectFormulaForSmallBlock() {
        checkBlockSize(64, 0)
    }

    @TestCase
    func matchesDirectFormulaForLargeBlock() {
        checkBlockSize(256, 1)
    }

    @TestCase
    func windowIsHalfBlockAndMonotonicAtEnds() {
        let mdct = VorbisMdct(64, 256)
        let window = mdct.window(1)
        @Expect(window.size, 128)
        @Expect(window[0] < 0.001, true)
        @Expect(window[127] > 0.999, true)
    }

    private func checkBlockSize(n: Int64, blockType: Int64): Unit {
        let mdct = VorbisMdct(64, 256)
        let n2 = n / 2
        let input = Array<Float32>(n2, repeat: 0.0)
        var j: Int64 = 0
        while (j < n2) {
            input[j] = Float32(sin(Float64(j) * 0.37) + 0.5 * cos(Float64(j) * 0.11))
            j += 1
        }

        let actual = Array<Float32>(n, repeat: 0.0)
        j = 0
        while (j < n2) {
            actual[j] = input[j]
            j += 1
        }
        mdct.inverse(actual, n, blockType)

        let pi = 3.14159265358979323846
        var i: Int64 = 0
        while (i < n) {
            var expected: Float64 = 0.0
            j = 0
            while (j < n2) {
                let angle = pi / 2.0 / Float64(n) * (2.0 * Float64(i) + 1.0 + Float64(n2)) * (2.0 * Float64(j) + 1.0)
                expected += Float64(input[j]) * cos(angle)
                j += 1
            }
            var diff = Float64(actual[i]) - expected
            if (diff < 0.0) {
                diff = -diff
            }
            if (diff > 1e-4) {
                throw Exception(
                    "IMDCT 与定义式不一致：n=${n}, i=${i}, actual=${actual[i]}, expected=${expected}, diff=${diff}")
            }
            i += 1
        }
    }
}
