package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.format.crc8Of
import audio4cj.format.crc16Of
import audio4cj.format.PureFlacKernel
import std.fs.*

/* ============================================================================
 * FLAC CRC-8 / CRC-16 测试
 *
 * 【核心验证策略：公开标准校验值】
 *   业界公开的自检向量 —— 对 ASCII "123456789"：
 *     CRC-8 （多项式 0x07，初值 0，MSB-first，不反转）= 0xF4
 *     CRC-16（多项式 0x8005，初值 0，MSB-first，不反转）= 0xFEE8
 *
 *   这两个定值来自公开规范，**不是**用本实现算出来的 —— 否则就成了拿实现
 *   验证它自己。它们能一次挡掉三类典型错误：多项式抄错、位序（MSB/LSB）
 *   搞反、初值与反转设置错。
 *
 * 【与"真实文件逐帧校验"的分工】
 *   本文件的用例只能证明"实现符合规范"；至于"帧的字节区间取得对不对"
 *   （区间多算或漏算一个字节，上面这些定值都看不出来），由流式内核在
 *   真实文件上逐帧校验来保证 —— 见 flac_bitstream_test 的 CRC 用例。
 * ========================================================================== */
// ---------------------------------------------------------------------------
// 集成用例的辅助（在真实文件上做可复现的就地改写）
// ---------------------------------------------------------------------------

/// 读取整个文件。
///
/// 注意写法：仓颉的 `try (…) { … }` 是**语句**（类型为 Unit），
/// 不能在其中 `return` 或直接把块的值当返回 —— 必须用变量接出来。
private func crcReadWhole(path: String): Array<UInt8> {
    var out = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        out = buf[0..got]
    }
    out
}

/// 写成临时文件（命名沿用本仓库其它测试的 `a4cj_` 前缀）。
private func crcWriteTemp(name: String, bytes: Array<UInt8>): String {
    let path = testTmpPath(name)
    File.writeTo(path, bytes)
    path
}

/// 用纯仓颉内核完整解码一遍，返回库内异常的消息（无异常则返回 None）。
///
/// 只捕获 `CorruptedFileException`：其它异常（越界、溢出、类型转换失败等）
/// 会向上传播并让用例失败 —— 那正是我们希望暴露的东西，不能被这里吞掉。
private func crcDecodePure(path: String): ?String {
    let kernel = PureFlacKernel(path, false)
    let channels = kernel.channels()
    let buf = Array<UInt8>(4096 * channels * 4, repeat: 0)
    var failure: ?String = None

    try {
        var got: Int64 = 1
        while (got > 0) {
            got = kernel.readF32Into(buf, 4096)
        }
    } catch (e: CorruptedFileException) {
        failure = e.message
    }

    kernel.close()
    failure
}

@Test
class FlacCrcTest {
    // ------------------------------------------------------------------
    // 公开标准校验值
    // ------------------------------------------------------------------

    /// CRC-8 的公开自检向量。
    @TestCase
    func crc8StandardCheckValue(): Unit {
        let data = "123456789".toArray()
        @Assert(crc8Of(data, 0, data.size) == 0xF4)
    }

    /// CRC-16 的公开自检向量。
    @TestCase
    func crc16StandardCheckValue(): Unit {
        let data = "123456789".toArray()
        @Assert(crc16Of(data, 0, data.size) == 0xFEE8)
    }

    // ------------------------------------------------------------------
    // 区间语义（左闭右开）
    // ------------------------------------------------------------------

    /// 空区间返回初值 0。
    @TestCase
    func emptyRangeReturnsZero(): Unit {
        let data = "123456789".toArray()
        @Assert(crc8Of(data, 3, 3) == 0)
        @Assert(crc16Of(data, 3, 3) == 0)
    }

    /// 单字节区间符合查表定义：初值 0 时，输入 0x00 得 0x0000、输入 0x01 得 0x8005
    /// （后者即多项式本身 —— 首位为 1 时左移后再异或多项式）。
    @TestCase
    func singleByteMatchesTableDefinition(): Unit {
        let zero: Array<UInt8> = [0x00]
        let one: Array<UInt8> = [0x01]
        @Assert(crc16Of(zero, 0, 1) == 0x0000)
        @Assert(crc16Of(one, 0, 1) == 0x8005)
    }

    /// 区间结果只取决于区间内的字节，与外层缓冲区无关。
    ///
    /// 这一条针对的是最容易写错的地方：CRC 循环的下界写成 0 而不是 `from`
    /// （那样"对任意区间算出来都一样"，而单看某个用例的结果又恰好可能对上）。
    @TestCase
    func subRangeIsIndependentOfOuterBuffer(): Unit {
        let data = "123456789".toArray()
        let sub: Array<UInt8> = [0x34, 0x35, 0x36, 0x37, 0x38, 0x39] // "456789"
        @Assert(crc8Of(data, 3, 9) == crc8Of(sub, 0, sub.size))
        @Assert(crc16Of(data, 3, 9) == crc16Of(sub, 0, sub.size))
    }

    /// 不同区间应给出不同结果（防止实现恒定返回同一个值而"碰巧"通过）。
    @TestCase
    func differentRangesDiffer(): Unit {
        let data = "123456789".toArray()
        @Assert(crc16Of(data, 0, 9) != crc16Of(data, 0, 8))
        @Assert(crc8Of(data, 0, 9) != crc8Of(data, 1, 9))
    }

    // ------------------------------------------------------------------
    // 越界必须是异常，而不是静默出错
    // ------------------------------------------------------------------

    /// 越界区间抛 CorruptedFileException（§4.1：不用返回值表达错误）。
    @TestCase
    func outOfRangeThrows(): Unit {
        let data = "123456789".toArray()
        var threw = false
        try {
            let _ = crc16Of(data, 0, data.size + 1)
        } catch (e: CorruptedFileException) {
            threw = true
        }
        @Assert(threw)
    }

    /// `until < from` 同样是非法的，不能静默算成空区间。
    @TestCase
    func reversedRangeThrows(): Unit {
        let data = "123456789".toArray()
        var threw = false
        try {
            let _ = crc8Of(data, 5, 2)
        } catch (e: CorruptedFileException) {
            threw = true
        }
        @Assert(threw)
    }

    // ------------------------------------------------------------------
    // 集成：校验在真实文件上是否真的会触发
    //
    // 【为什么必须有这一组】前面的定值用例只能证明"CRC 函数算得对"，
    // 证明不了"解码路径真的在调用它"。一个从不触发的校验，从外部看
    // 与正确的校验完全一样 —— 只有"改写一个字节就应当被拒绝"能戳穿。
    // ------------------------------------------------------------------

    /// 改写**最后一个字节** ⇒ 必须报帧尾 CRC-16 校验失败。
    ///
    /// 【为什么挑末字节】FLAC 文件以最后一帧的 CRC-16 结尾、后面没有尾部填充，
    /// 所以改末字节**只**破坏 CRC-16，不触碰帧体 —— 这个用例因此精确地测
    /// "帧尾 CRC 校验是否生效"，而不会与"损坏数据被别的方式拒绝"混淆。
    /// 代价是必须把整个文件解完才能撞上（最后一帧才校验失败）。
    @TestCase
    func trailingByteCorruptionFailsCrc16(): Unit {
        if (gsSkipIfNoFixtures("trailingByteCorruptionFailsCrc16")) {
            return
        }

        let bytes = crcReadWhole("testdata/flac/flac_s16_44100_stereo.flac")
        @Assert(bytes.size > 0)
        bytes[bytes.size - 1] = bytes[bytes.size - 1] ^ 0xFF
        let path = crcWriteTemp("a4cj_crc_tail.flac", bytes)

        let message = crcDecodePure(path)
        match (message) {
            case Some(m) => @Assert(m.contains("CRC-16"))
            case None => @Assert(false)
        }
    }

    /// 改写**文件中段**的一个字节 ⇒ 必须被拒绝。
    ///
    /// 【为什么不要求错误里出现 "CRC"】中段落在帧体里，改一位可能先撞上结构性
    /// 错误（非法子帧类型、残差越界等），那同样是**正确的拒绝**。这里断言的是
    /// 更强也更本质的性质：**损坏的文件不得静默产出样本**。
    /// （非库内异常会让本用例以异常形式失败 —— 那是对"错误语义"的额外要求。）
    @TestCase
    func bodyCorruptionIsRejected(): Unit {
        if (gsSkipIfNoFixtures("bodyCorruptionIsRejected")) {
            return
        }

        let bytes = crcReadWhole("testdata/flac/flac_s16_44100_stereo.flac")
        @Assert(bytes.size > 2000)
        let mid = bytes.size / 2
        bytes[mid] = bytes[mid] ^ 0xFF
        let path = crcWriteTemp("a4cj_crc_body.flac", bytes)

        @Assert(crcDecodePure(path) != None)
    }

    /// 对照：**未改写**的同名素材必须能完整解完、不报任何错。
    ///
    /// 这一条用来排除"解码器对任何输入都报错"这种假阳性 ——
    /// 没有它，上面两个用例在实现彻底崩坏时也会通过。
    @TestCase
    func intactFileStillDecodesCleanly(): Unit {
        if (gsSkipIfNoFixtures("intactFileStillDecodesCleanly")) {
            return
        }

        @Assert(crcDecodePure("testdata/flac/flac_s16_44100_stereo.flac") == None)
    }
}
