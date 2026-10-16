package audio4cj.test

import audio4cj.pcm.isSupportedPcmFormat
import audio4cj.pcm.pcmToF32
import audio4cj.pcm.f32ToBytes
import std.collection.ArrayList

/* ============================================================================
 * 32 位浮点 PCM 的位视角转换测试（纯内存、不落盘、无素材）
 *
 * 背景：WAV 的 `formatTag = 3`（IEEE 浮点，含 extensible 子格式 3）此前被
 *       `isSupportedPcmFormat(_, isFloatFormat: true)` 一律拒绝。现在放行 32 位，
 *       转换方式为**按位重解释**（`reinterpretF32Bytes`），而不是拆符号/阶码/尾数
 *       手工拼回 —— 后者要自己实现舍入，最低位会与参考实现不一致。
 *
 * 因此本文件的断言刻意分两层：
 *   · 数值层：常见位模式必须还原成精确的浮点值（1.0 / -1.0 / 0.5 …）
 *   · 位层：**任意** 32 位模式（含次正规数、±Inf、NaN 载荷、-0.0）经
 *     `pcmToF32` → `f32ToBytes` 往返后必须逐位相同。位层断言才是"没有数值运算"
 *     的真正证据：任何一次数值转换都会在某个模式上留下痕迹。
 * ========================================================================== */

/// 把一个 32 位模式写成小端 4 字节。
private func pfAppendBits(out: ArrayList<UInt8>, bits: UInt32): Unit {
    out.add(UInt8(bits & 0xFF))
    out.add(UInt8((bits >> 8) & 0xFF))
    out.add(UInt8((bits >> 16) & 0xFF))
    out.add(UInt8((bits >> 24) & 0xFF))
}

/// 把若干 32 位模式按顺序拼成字节流（每条 4 字节，小端）。
private func pfStreamOfBits(codes: Array<UInt32>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (c in codes) {
        pfAppendBits(out, c)
    }
    out.toArray()
}

/// 取出字节流中第 index 条样本的 32 位模式（小端）。
private func pfBitsOf(bytes: Array<UInt8>, index: Int64): UInt32 {
    let at = index * 4
    UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
}

/// 由整数字面量列表构造字节流（避免数组字面量的元素类型推断歧义）。
private func pfBytes(values: Array<Int64>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (v in values) {
        out.add(UInt8(v & 0xFF))
    }
    out.toArray()
}

/// 单个样本的常用位模式（便于跨用例复用与阅读）。
private let PF_ONE: UInt32 = 0x3F800000 // 1.0
private let PF_NEG_ONE: UInt32 = 0xBF800000 // -1.0
private let PF_HALF: UInt32 = 0x3F000000 // 0.5
private let PF_ZERO: UInt32 = 0x00000000 // 0.0
private let PF_NEG_ZERO: UInt32 = 0x80000000 // -0.0
private let PF_INF: UInt32 = 0x7F800000 // +Inf
private let PF_NEG_INF: UInt32 = 0xFF800000 // -Inf
private let PF_NAN: UInt32 = 0x7FC00000 // 静默 NaN（约定载荷）

// ---------------------------------------------------------------------------
// 支持矩阵
// ---------------------------------------------------------------------------
@Test
class PcmFloatSupportMatrixTest {
    /// 浮点只放行 32 位：64 位在真实素材里极罕见，而本库统一表示就是 f32，
    /// 收进来只能降精度 —— 明确拒绝好过静默截断。
    @TestCase
    func floatSupportIsExactly32Bits() {
        @Assert(isSupportedPcmFormat(32, true))
        @Assert(!isSupportedPcmFormat(64, true))
        @Assert(!isSupportedPcmFormat(24, true))
        @Assert(!isSupportedPcmFormat(16, true))
        @Assert(!isSupportedPcmFormat(8, true))
    }

    /// 整型矩阵不因本次改动而变（回归护栏）。
    @TestCase
    func integerMatrixIsUnchanged() {
        @Assert(isSupportedPcmFormat(8, false))
        @Assert(isSupportedPcmFormat(16, false))
        @Assert(isSupportedPcmFormat(24, false))
        @Assert(isSupportedPcmFormat(32, false))
        @Assert(!isSupportedPcmFormat(12, false))
        @Assert(!isSupportedPcmFormat(64, false))
    }

    /// 走浮点分支但位深不是 32：返回**空数组**，绝不按整型口径误解释位模式。
    @TestCase
    func floatBranchOnOtherDepthReturnsEmpty() {
        @Assert(pcmToF32(pfStreamOfBits([PF_ONE]), 64, isFloatFormat: true).size == 0)
        @Assert(pcmToF32(pfStreamOfBits([PF_ONE]), 16, isFloatFormat: true).size == 0)
    }

    /// 缺省（不传 isFloatFormat）仍是整型口径 —— 既有调用点不因形参新增而改变行为。
    @TestCase
    func omittedFlagKeepsIntegerSemantics() {
        // 16 位整型 0x7FFF → 0.999969…；若被当成浮点位模式会得到完全不同的值
        let s = pcmToF32(pfBytes([0xFF, 0x7F]), 16)
        @Assert(s.size == 1)
        @Assert(s[0] > 0.999)
        @Assert(s[0] < 1.0)
    }
}

// ---------------------------------------------------------------------------
// 数值层
// ---------------------------------------------------------------------------

@Test
class PcmFloatValueTest {
    @TestCase
    func knownPatternsDecodeToExactValues() {
        let codes: Array<UInt32> = [PF_ONE, PF_NEG_ONE, PF_ZERO, PF_HALF, 0x3FC00000] // 1.0 -1.0 0.0 0.5 1.5
        let s = pcmToF32(pfStreamOfBits(codes), 32, isFloatFormat: true)
        @Assert(s.size == 5)
        @Assert(s[0] == 1.0)
        @Assert(s[1] == -1.0)
        @Assert(s[2] == 0.0)
        @Assert(s[3] == 0.5)
        @Assert(s[4] == 1.5)
    }

    /// 浮点载荷不受 [-1, 1] 限制：削波前的素材与总线电平都可能越界，
    /// 与整型路径一致 —— 归一化不等于钳位，钳位交给消费方。
    @TestCase
    func beyondUnitRangeIsNotClamped() {
        let s = pcmToF32(pfStreamOfBits([0x40200000, 0xC0200000]), 32, isFloatFormat: true) // 2.5 / -2.5
        @Assert(s[0] == 2.5)
        @Assert(s[1] == -2.5)
    }

    @TestCase
    func subnormalAndHugeExponentsSurvive() {
        // 2^-30、最小次正规数 2^-149、2^100
        let s = pcmToF32(pfStreamOfBits([0x30800000, 0x00000001, 0x71800000]), 32, isFloatFormat: true)
        @Assert(s[0] == 9.31322574615478515625e-10)
        @Assert(s[1] > 0.0)
        @Assert(s[1] < 1.0e-44)
        @Assert(s[2] > 1.0e30)
    }

    @TestCase
    func infAndNanArePassedThrough() {
        let s = pcmToF32(pfStreamOfBits([PF_INF, PF_NEG_INF, PF_NAN, PF_ZERO]), 32, isFloatFormat: true)
        @Assert(s[0] > 1.0e38) // +Inf
        @Assert(s[1] < -1.0e38) // -Inf
        @Assert(s[2] != s[2]) // NaN 与自身不相等（唯一可靠的判定）
        @Assert(s[3] == 0.0)
    }

    @TestCase
    func interleavingOrderIsPreserved() {
        // 立体声交错：L=1.0 R=0.5 L=-1.0 R=0.0
        let s = pcmToF32(pfStreamOfBits([PF_ONE, PF_HALF, PF_NEG_ONE, PF_ZERO]), 32, isFloatFormat: true)
        @Assert(s.size == 4)
        @Assert(s[0] == 1.0)
        @Assert(s[1] == 0.5)
        @Assert(s[2] == -1.0)
        @Assert(s[3] == 0.0)
    }

    @TestCase
    func emptyAndTruncatedInputsAreSafe() {
        @Assert(pcmToF32(Array<UInt8>(0, repeat: 0), 32, isFloatFormat: true).size == 0)
        // 尾部不足 4 字节：残缺样本被忽略而不是读越界
        @Assert(pcmToF32(pfBytes([0x00, 0x00, 0x80]), 32, isFloatFormat: true).size == 0)
        @Assert(pcmToF32(pfBytes([0x00, 0x00, 0x80, 0x3F, 0xAA]), 32, isFloatFormat: true).size == 1)
    }
}

// ---------------------------------------------------------------------------
// 位层：往返逐位相同
// ---------------------------------------------------------------------------

@Test
class PcmFloatBitExactnessTest {
    /// 覆盖：±0、正规数两端、最小次正规数、最大次正规数、最大正规数、±Inf、NaN、
    /// 以及若干普通值。任何数值转换（乘法/除法/舍入/钳位）都会在其中某个模式上
    /// 留下可见痕迹，因此"全部逐位还原"等价于"这条路径没有数值运算"。
    @TestCase
    func everyPatternRoundTripsBitExactly() {
        let codes: Array<UInt32> = [
            PF_ZERO,
            PF_NEG_ZERO,
            PF_ONE,
            PF_NEG_ONE,
            PF_HALF,
            PF_INF,
            PF_NEG_INF,
            PF_NAN,
            0x00000001, // 最小次正规数
            0x007FFFFF, // 最大次正规数
            0x00800000, // 最小正规数
            0x7F7FFFFF, // 最大有限值
            0x3E800000, // 0.25
            0x4B000000, // 8388608.0
            0x2EDBE6FF, // ≈1e-10
            0x40200000 // 2.5（越界值）
        ]

        let out = pcmToF32(pfStreamOfBits(codes), 32, isFloatFormat: true)
        @Assert(out.size == codes.size)

        let back = f32ToBytes(out)
        @Assert(back.size == codes.size * 4)

        for (i in 0..codes.size) {
            let got = pfBitsOf(back, i)
            if (got != codes[i]) {
                @Fail("第 ${i} 个位模式未逐位还原：期望 ${Int64(codes[i])}，实得 ${Int64(got)}")
            }
        }
    }

    /// -0.0 与 0.0 数值相等，只有符号位能区分 —— 这也是"位视角而非数值转换"的证据。
    @TestCase
    func negativeZeroKeepsItsSignBit() {
        let out = pcmToF32(pfStreamOfBits([PF_NEG_ZERO, PF_ZERO]), 32, isFloatFormat: true)
        @Assert(out[0] == 0.0)
        @Assert(out[1] == 0.0)
        let back = f32ToBytes(out)
        @Assert(pfBitsOf(back, 0) == PF_NEG_ZERO)
        @Assert(pfBitsOf(back, 1) == PF_ZERO)
    }

    /// NaN 载荷在位视角下原样保留（数值层只能判断"是 NaN"，无法区分载荷）。
    @TestCase
    func nanPayloadIsPreserved() {
        let payload: UInt32 = 0x7FC00001 // 带自定义载荷的静默 NaN
        let out = pcmToF32(pfStreamOfBits([payload]), 32, isFloatFormat: true)
        @Assert(out[0] != out[0])
        @Assert(pfBitsOf(f32ToBytes(out), 0) == payload)
    }
}
