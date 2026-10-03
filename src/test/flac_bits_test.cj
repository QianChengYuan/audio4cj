package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.format.BitReader

/* ============================================================================
 * BitReader 单元测试
 *
 * 【为什么单独测位读取】
 *   FLAC 是逐位编码的格式，位读取一旦有错，上层症状是"整段样本值全错"，
 *   无法区分是位序错、预测算错还是残差解错。把位读取单独验证透，
 *   后面几百行解码算法的调试范围才能收敛到算法本身。
 *
 * 【本文件的用例刻意覆盖四类易错点】
 *   1. 跨字节边界读取（位序 MSB-first 的直接体现）
 *   2. 符号扩展（用 Int64 加宽，规避仓颉默认的转换溢出检查）
 *   3. 一元码与 UTF-8 式变长整数（FLAC 特有的两种编码）
 *   4. 截断与非法编码必须抛异常，而不是静默返回 0
 * ========================================================================== */
@Test
class FlacBitsTest {
    // ------------------------------------------------------------------
    // 定长读取与位序
    // ------------------------------------------------------------------

    /// 跨字节边界读取 —— MSB-first 位序的直接检验。
    ///
    /// 字节流 1011_0010 0110_1100：
    ///   先读 4 位 -> 1011 = 11
    ///   再读 8 位 -> 0010_0110 = 38（跨越两个字节）
    @TestCase
    func crossesByteBoundaryInMsbFirstOrder() {
        let data: Array<UInt8> = [0xB2, 0x6C]
        let r = BitReader(data)

        @Expect(r.readBits(4), 11)
        @Expect(r.readBits(8), 38)

        // 读走 12 位，应剩 4 位
        @Expect(r.remainingBits(), 4)

        // 剩下的 4 位是 byte1 的低 4 位：1100 = 12
        @Expect(r.readBits(4), 12)
        @Expect(r.isExhausted(), true)
    }

    /// 单字节内逐位读取的顺序（最高位在前）。
    @TestCase
    func readsBitsFromMostSignificantFirst() {
        let data: Array<UInt8> = [0x80] // 1000_0000
        let r = BitReader(data)

        @Expect(r.readBit(), true)
        @Expect(r.readBit(), false)
        @Expect(r.readBit(), false)
        @Expect(r.readBit(), false)
    }

    /// 读满 64 位（位读取器的最大位宽）。
    @TestCase
    func readsFullSixtyFourBits() {
        let data: Array<UInt8> = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let r = BitReader(data)
        @Expect(r.readBits(64), 0xFFFFFFFFFFFFFFFF)
    }

    // ------------------------------------------------------------------
    // 符号扩展
    // ------------------------------------------------------------------

    /// 二进制补码符号扩展：4 位全 1 应得 -1，而不是 15。
    @TestCase
    func extendsSignForNegativeValues() {
        let data: Array<UInt8> = [0xFF, 0xFF, 0xFF, 0xFF]
        let r = BitReader(data)

        @Expect(r.readSignedBits(4), -1)
        @Expect(r.readSignedBits(4), -1)
        @Expect(r.readSignedBits(4), -1)
        @Expect(r.readSignedBits(4), -1)

        // 0b1000（4 位最小值）应为 -8
        let data2: Array<UInt8> = [0x80]
        let r2 = BitReader(data2)
        @Expect(r2.readSignedBits(4), -8)
    }

    /// 正值的符号位为 0 时不得被误判为负数。
    ///
    /// 取值说明（本用例初版取 0x7F 失败）：0x7F 的**低 7 位**是 `111_1111`，
    /// 其最高位为 1，按补码解读是 -1 而非 127。要验证"正值不被误判"，
    /// 必须让被读位段的最高位为 0 —— 故这里取 0x70 的 4 位（`0111` = 7）。
    @TestCase
    func keepsPositiveValuesPositive() {
        let data: Array<UInt8> = [0x70] // 0111_0000
        let r = BitReader(data)
        @Expect(r.readSignedBits(4), 7)

        // 32 位正数上限，验证不会被 Int32 溢出的转换检查打断
        let data2: Array<UInt8> = [0x7F, 0xFF, 0xFF, 0xFF]
        let r2 = BitReader(data2)
        @Expect(r2.readSignedBits(32), 2147483647)
    }

    /// 32 位负数（-1）的符号扩展 —— 这是最容易触发仓颉转换溢出检查的取值。
    @TestCase
    func extendsSignForFullWidthNegative() {
        let data: Array<UInt8> = [0xFF, 0xFF, 0xFF, 0xFF]
        let r = BitReader(data)
        @Expect(r.readSignedBits(32), -1)
    }

    // ------------------------------------------------------------------
    // 一元码
    // ------------------------------------------------------------------

    /// 一元码：计数连续 0，直到读到 1（该 1 被消费）。
    ///
    /// 第二个一元码刻意**跨越字节边界**：0x10 剩余的 4 位为 0000，
    /// 0x08 的前 4 位为 0001，故共 8 个 0 之后才遇到 1。
    ///
    /// （本用例初版把第二个一元码写在单字节内并期望 4，实际因位耗尽抛异常 ——
    ///   那其实是**正确行为**，见下面 throwsOnUnterminatedUnary。）
    @TestCase
    func countsZerosInUnaryCode() {
        let data: Array<UInt8> = [0b0001_0000, 0b0000_1000]
        let r = BitReader(data)

        @Expect(r.readUnary(), 3) // 000 后遇 1
        @Expect(r.readUnary(), 8) // 跨字节：0000 0000 后遇 1
    }

    /// 一元码缺少终止 1（位耗尽）时必须抛异常，而不是静默返回一个计数。
    ///
    /// 这条对解码器很重要：残差的一元部分若被截断，静默返回计数会让
    /// 后续算出"看似合理但错误"的样本，比直接报错难查得多。
    @TestCase
    func throwsOnUnterminatedUnary() {
        let data: Array<UInt8> = [0b0000_0000]
        let r = BitReader(data)
        @AssertThrows[CorruptedFileException](r.readUnary())
    }

    /// 首位即为 1 时一元码返回 0。
    @TestCase
    func unaryCodeOfZeroZeros() {
        let data: Array<UInt8> = [0b1000_0000]
        let r = BitReader(data)
        @Expect(r.readUnary(), 0)
    }

    // ------------------------------------------------------------------
    // UTF-8 式变长整数（帧号 / 样本号）
    // ------------------------------------------------------------------

    /// 单字节形式：前导 0 后跟 7 位数值。
    @TestCase
    func readsSingleByteUtf8Number() {
        let data: Array<UInt8> = [0x7F] // 0_111_1111
        let r = BitReader(data)
        @Expect(r.readUtf8Number(), 127)
    }

    /// 双字节形式：110_xxxxx 10_xxxxxx，共 11 位数值。
    ///
    /// 0xDF 0xBF 解码为 0b111_1111_1111 = 2047。
    @TestCase
    func readsTwoByteUtf8Number() {
        let data: Array<UInt8> = [0xDF, 0xBF]
        let r = BitReader(data)
        @Expect(r.readUtf8Number(), 2047)
    }

    /// 三字节形式：1110_xxxx 10_xxxxxx 10_xxxxxx，共 16 位数值。
    @TestCase
    func readsThreeByteUtf8Number() {
        let data: Array<UInt8> = [0xEF, 0xBF, 0xBF]
        let r = BitReader(data)
        @Expect(r.readUtf8Number(), 65535)
    }

    /// 七字节形式：36 位全 1 —— FLAC 允许的最长编码。
    @TestCase
    func readsSevenByteUtf8Number() {
        let data: Array<UInt8> = [0xFE, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF]
        let r = BitReader(data)
        @Expect(r.readUtf8Number(), 68719476735) // 2^36 - 1
    }

    /// 首字节前导 1 为 1 个（0x80..0xBF）是续字节，不得作为起始 —— 必须抛异常。
    @TestCase
    func rejectsContinuationByteAsLeading() {
        let data: Array<UInt8> = [0x80, 0xBF]
        let r = BitReader(data)
        @AssertThrows[CorruptedFileException](r.readUtf8Number())
    }

    /// 首字节前导 1 超过 7 个同样是非法编码。
    @TestCase
    func rejectsTooManyLeadingOnes() {
        let data: Array<UInt8> = [0xFF, 0xFF]
        let r = BitReader(data)
        @AssertThrows[CorruptedFileException](r.readUtf8Number())
    }

    /// 续字节必须以 0b10 开头，否则抛异常。
    @TestCase
    func rejectsMalformedContinuationByte() {
        // 0xDF 后跟 0x00（而非 10xxxxxx）
        let data: Array<UInt8> = [0xDF, 0x00]
        let r = BitReader(data)
        @AssertThrows[CorruptedFileException](r.readUtf8Number())
    }

    // ------------------------------------------------------------------
    // 越界与位置控制
    // ------------------------------------------------------------------

    /// 读取超过剩余位数必须抛异常 —— 截断文件不得静默产出 0。
    @TestCase
    func throwsOnTruncatedInput() {
        let data: Array<UInt8> = [0x00]
        let r = BitReader(data)
        @AssertThrows[CorruptedFileException](r.readBits(16))
    }

    /// 位耗尽后继续读也必须抛异常。
    @TestCase
    func throwsWhenExhausted() {
        let data: Array<UInt8> = [0xFF]
        let r = BitReader(data)
        r.readBits(8)
        @Expect(r.isExhausted(), true)
        @AssertThrows[CorruptedFileException](r.readBit())
    }

    /// 非法位宽应当被拒绝（0 返回 0，负值与超 64 位抛异常）。
    @TestCase
    func rejectsIllegalBitWidth() {
        let data: Array<UInt8> = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let r = BitReader(data)

        @Expect(r.readBits(0), 0)
        @AssertThrows[CorruptedFileException](r.readBits(-1))
        @AssertThrows[CorruptedFileException](r.readBits(65))
    }

    /// 对齐到字节边界后，后续读取应从整字节开始。
    @TestCase
    func alignsToByteBoundary() {
        let data: Array<UInt8> = [0b1010_1010, 0b1111_0000]
        let r = BitReader(data)

        r.readBits(3)
        @Expect(r.bitPosition(), 3)
        r.alignToByte()
        @Expect(r.bitPosition(), 8)

        // 对齐后读到的是第二个字节的 4 位高半部分：1111
        @Expect(r.readBits(4), 0b1111)
    }

    /// 回退到指定位置（解码器重试帧时依赖它）。
    @TestCase
    func seeksBackToRecordedPosition() {
        let data: Array<UInt8> = [0xB2, 0x6C]
        let r = BitReader(data)

        let mark = r.bitPosition()
        let first = r.readBits(8)
        @Expect(first, 0xB2)

        r.seekToBit(mark)
        @Expect(r.bitPosition(), 0)
        @Expect(r.readBits(8), 0xB2)

        // 越界位置必须被拒绝
        @AssertThrows[CorruptedFileException](r.seekToBit(17))
        @AssertThrows[CorruptedFileException](r.seekToBit(-1))
    }
}
