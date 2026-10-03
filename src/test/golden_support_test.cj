package audio4cj.test

import std.binary.*
import std.fs.*

/* ============================================================================
 * golden 基准的读取与比对（测试共享）
 *
 * 【为什么单独一个文件】Tier 4 移除了 dr_libs 之后，"与第三方实现对照"这条判据
 *   就只剩 ffmpeg 的 golden 基准了，而它被多个测试文件使用（golden_test、
 *   flac_bitstream_test、flac_frame_test）。把读取与比对收在这里，避免同一段
 *   逻辑出现三份 —— 三份必然漂移。
 *
 * 【基准是什么】testdata/golden/ 下的 .f32le 文件：ffmpeg 解码出的 f32 交错样本，
 *   逐字节落盘。存 f32 而不是整型 PCM，是为了让比对**绕开被测库自己的位深转换** ——
 *   否则那个函数一旦有错，比对结果反而恒等（自己给自己判卷）。
 *   基准随仓库入库，因此测试**不依赖 ffmpeg**。
 *
 * 【为什么这里的比较函数"返回差异描述"而不是直接断言失败】
 *   `@Fail` 这类测试宏只在测试框架处理过的文件中可用（本文件没有 @Test 类），
 *   把它放进共享工具会引入一条隐性的编译约束。更实际的理由是：返回描述的函数
 *   谁都能用 —— 测试里 `@Fail(msg)`，基准或诊断脚本里可以直接打印。
 * ========================================================================== */

/// 基准所在目录。
let GS_GOLDEN_DIR: String = "testdata/golden"

/// 读取一份 golden 基准，返回 f32 交错样本。
///
/// 文件缺失、或长度不是 4 的整数倍时抛异常 —— 这两种情况都会让比对失去意义。
/// 静默返回空数组会把"基准没了"伪装成"比对通过"，那是最坏的一种失败。
func gsLoadGolden(name: String): Array<Float32> {
    let path = "${GS_GOLDEN_DIR}/${name}"
    var bytes = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        bytes = buf[0..got]
    }

    if (bytes.size == 0) {
        throw Exception("golden 基准 ${name} 为空（路径 ${path}）")
    }
    if (bytes.size % 4 != 0) {
        throw Exception("golden 基准 ${name} 长度不是 4 的整数倍（${bytes.size} 字节）")
    }

    let count = bytes.size / 4
    let out = Array<Float32>(count, repeat: 0.0)
    var i: Int64 = 0
    while (i < count) {
        // 取 4 字节到独立数组再还原：不依赖切片语义的细节
        let quad = Array<UInt8>(4, repeat: 0)
        var k: Int64 = 0
        while (k < 4) {
            quad[k] = bytes[i * 4 + k]
            k += 1
        }
        out[i] = Float32.readLittleEndian(quad)
        i += 1
    }
    out
}

/// 比较两个样本数组是否**完全一致**（含长度）。一致返回 None，否则返回差异描述。
///
/// 【为什么不留容差】两边是**同一段 PCM 的解码结果**，且本库与 ffmpeg 的 f32
///   归一化口径相同（`v / 2^(n-1)`）—— 实测最大差为 0。留容差只会掩盖真正的
///   缩放错误，而那正是这类比对要拦的东西。
func gsDiffIdentical(actual: Array<Float32>, expected: Array<Float32>): ?String {
    if (actual.size != expected.size) {
        return Some("样本数不一致（实际 ${actual.size}，期望 ${expected.size}）")
    }

    var i: Int64 = 0
    while (i < actual.size) {
        if (actual[i] != expected[i]) {
            return Some("第 ${i} 个样本不一致（实际 ${actual[i]}，期望 ${expected[i]}）")
        }
        i += 1
    }
    None
}

/// 比较 `actual[from .. from+count)` 与 `expected` 的前 `count` 个样本。
///
/// 用于"素材是基准的超集"这种情形：例如 2 秒的带标签素材，其前 1 秒与现成的
/// 1 秒基准逐位相同（lavfi 正弦自 t=0 确定性生成，而封装是无损的）。
func gsDiffPrefix(actual: Array<Float32>, from: Int64, expected: Array<Float32>, count: Int64): ?String {
    if (from < 0 || count < 0 || from + count > actual.size) {
        return Some("区间越界（from=${from} count=${count}，实际长度 ${actual.size}）")
    }
    if (count > expected.size) {
        return Some("基准不足以覆盖 ${count} 个样本（基准只有 ${expected.size} 个）")
    }

    var i: Int64 = 0
    while (i < count) {
        if (actual[from + i] != expected[i]) {
            return Some("第 ${i} 个样本不一致（实际 ${actual[from + i]}，基准 ${expected[i]}）")
        }
        i += 1
    }
    None
}

/// 对这套工具本身的自检。
///
/// 【为什么"判据"也需要被验证】本文件是所有"与 ffmpeg 比对"用例的裁判。它若悄悄
///   出错（字节序反了、长度算错、比较恒真），结果不是"某条用例失败"，而是
///   **全部比对一起失真** —— 那是最难发现的一类问题：一片绿，而绿得毫无意义。
///   因此这里用两份**已知内容**把读取与比较都钉住。
///
/// （本文件也因此有了 @Test 类：构建模式下未使用的顶层函数会告警，
///   而辅助函数与 @Test 类同文件是本仓库既有的组织方式。）
@Test
class GoldenSupportSelfCheck {
    /// 读取器确实按**小端 f32** 解读，且长度正确。
    @TestCase
    func loaderReadsLittleEndianF32() {
        let g = gsLoadGolden("sine_44100_stereo_s16.f32le")

        // 1 秒 / 44.1k / 立体声 → 恰好 88200 个样本
        @Expect(g.size, 44100 * 2)

        // 全部落在 [-1, 1]：字节序若反了，得到的会是天文数字或 NaN
        var i: Int64 = 0
        var nonZero: Int64 = 0
        while (i < g.size) {
            @Assert(g[i] >= -1.0 && g[i] <= 1.0)
            if (g[i] != 0.0) {
                nonZero += 1
            }
            i += 1
        }
        // 全零说明"读到了空/坏数据"，同样是失真
        @Assert(nonZero > 0)
    }

    /// 缺失的基准必须**抛异常**，不能静默返回空数组。
    @TestCase
    func missingBaselineThrows() {
        @AssertThrows[Exception](gsLoadGolden("__no_such_baseline__.f32le"))
    }

    /// 比较器必须**真的能发现差异** —— 否则它只是一条永远通过的断言。
    @TestCase
    func differDetectsMismatch() {
        // 显式标注类型：浮点字面量默认是 Float64，而比较器收的是 Array<Float32>
        let base: Array<Float32> = [0.0, 0.5, 1.0, -0.25]

        // 完全一致 → 无差异
        @Assert(gsDiffIdentical(base, [0.0, 0.5, 1.0, -0.25]).isNone())

        // 值不同 → 必须报出（含首个差异位置）
        let changed = gsDiffIdentical(base, [0.0, 0.5, 0.75, -0.25])
        @Assert(changed.isSome())
        if (let Some(msg) <- changed) {
            @Assert(msg.contains("第 2 个样本"))
        }

        // 长度不同 → 必须报出
        @Assert(gsDiffIdentical(base, [0.0, 0.5, 1.0]).isSome())
        @Assert(gsDiffIdentical([0.0, 0.5], base).isSome())

        // 前缀比较：一致 / 起点偏移（必然不等）/ 基准不足，三者都要正确区分
        @Assert(gsDiffPrefix(base, 0, [0.0, 0.5, 1.0, -0.25], 4).isNone())
        @Assert(gsDiffPrefix(base, 1, [0.0, 0.5, 1.0, -0.25], 3).isSome())
        @Assert(gsDiffPrefix(base, 0, [0.0, 0.5], 4).isSome()) // 基准不够
        @Assert(gsDiffPrefix(base, 0, [0.0, 0.5, 1.0, -0.25], 9).isSome()) // 越界
    }
}
