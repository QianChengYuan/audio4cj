package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.format.crc32Ogg
import audio4cj.format.PureFlacKernel
import audio4cj.pcm.readUInt32LE
import std.fs.*

/* ============================================================================
 * Ogg 页 CRC-32 测试
 *
 * 【两层验证，各挡一类错误】
 *   1. **公开标准串** —— ASCII "123456789" 的定值 0x89A1897F。
 *      "CRC-32" 这个名字下至少有三套参数（以太网/PNG 版反转、MPEG-2 版初值
 *      0xFFFFFFFF、Ogg 版），这个定值能一次挡掉**四组参数（多项式、初值、
 *      输入/输出反转、最终异或）的任意组合出错**。
 *      定值取自公开规范，不是拿本实现算出来的 —— 否则等于让实现自己判自己。
 *
 *   2. **真实素材反证** —— 对 testdata/ogg 下每个文件重算**每一页**的 CRC，
 *      与页头里存储的值逐一比对。这一层专防标准串看不出的错误：**覆盖范围**。
 *      例如忘了把页头那 4 字节 CRC 字段置零再算、漏算段表、页体长度算错 ——
 *      标准串只覆盖一段连续字节、没有页面结构，对这类错误完全无感。
 *      （素材里含 Vorbis 文件：CRC 是**容器级**校验、与子编码无关，
 *      故它们同样是有效证据，且让样本量从 2 个文件扩到 8 个、30 个页面。）
 *
 *   3. **篡改必被拒** —— 前两层只能证明"算得对"，证明不了"校验真的被调用"。
 *      故第 3 条就地改写真实素材的页体、保留其 CRC 字段，要求解码时必须报错。
 * ========================================================================== */

/// 读取整个文件。
///
/// 注意写法：仓颉的 `try (…) { … }` 是**语句**（类型为 Unit），
/// 不能在其中 `return` 或直接把块的值当返回 —— 必须用变量接出来。
private func ocReadWhole(path: String): Array<UInt8> {
    var out = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        out = buf[0..got]
    }
    out
}

/// 全部 Ogg 素材。
private let OC_FIXTURES = [
    "testdata/ogg/ogg_flac.oga",
    "testdata/ogg/ogg_flac_tagged.oga",
    "testdata/ogg/ogg_vorbis_q0.ogg",
    "testdata/ogg/ogg_vorbis_q4.ogg",
    "testdata/ogg/ogg_vorbis_q4_mono.ogg",
    "testdata/ogg/ogg_vorbis_q8.ogg",
    "testdata/ogg/ogg_vorbis_silence.ogg",
    "testdata/ogg/ogg_vorbis_tagged.ogg"
]

@Test
class OggCrcTest {
    /// 公开标准串：一次挡掉四组 CRC 参数的任意组合出错。
    @TestCase
    func standardCheckValue() {
        let digits = "123456789".toArray()
        @Expect(crc32Ogg(digits, 0, digits.size), 0x89A1897F)
    }

    /// 区间语义是左闭右开：空区间取初值 (0)，且只覆盖 [from, until)。
    @TestCase
    func rangeIsHalfOpen() {
        let bytes = [0x00u8, 0x31u8, 0x32u8]
        @Expect(crc32Ogg(bytes, 1, 1), 0) // 空区间 = 初值

        let tail = crc32Ogg(bytes, 1, 3)
        let only = "12".toArray()
        @Expect(tail, crc32Ogg(only, 0, only.size))
    }

    /// 真实素材：逐页重算 CRC 并与页头存储值比对（8 个素材、30 个页面）。
    ///
    /// 这一层能挡住"参数对但覆盖范围错"，也能挡住"页体长度按写死的偏移算"
    /// 这类错误（段数可变，payload 起点不能写死）。
    @TestCase
    func realPagesMatchStoredValues() {
        if (gsSkipIfNoFixtures("realPagesMatchStoredValues")) {
            return
        }

        var totalPages: Int64 = 0

        for (path in OC_FIXTURES) {
            let data = ocReadWhole(path)
            @Assert(data.size >= 27)

            var off: Int64 = 0
            var pages: Int64 = 0
            while (off + 27 <= data.size) {
                // 页起点必须是 "OggS"
                @Assert(data[off] == 0x4F && data[off + 1] == 0x67 && data[off + 2] == 0x67 &&
                    data[off + 3] == 0x53)

                let segCount = Int64(data[off + 26])
                var bodyLen: Int64 = 0
                var i: Int64 = 0
                while (i < segCount) {
                    bodyLen += Int64(data[off + 27 + i])
                    i += 1
                }
                let pageSize = 27 + segCount + bodyLen
                @Assert(off + pageSize <= data.size)

                // 复制整页，把 CRC 字段自身置零，再重算
                let page = Array<UInt8>(pageSize, repeat: 0)
                i = 0
                while (i < pageSize) {
                    page[i] = data[off + i]
                    i += 1
                }
                let stored = readUInt32LE(page, 22)
                page[22] = 0
                page[23] = 0
                page[24] = 0
                page[25] = 0
                @Expect(crc32Ogg(page, 0, pageSize), stored)

                off += pageSize
                pages += 1
            }

            @Assert(pages > 0)
            totalPages += pages
        }

        // 样本量下限：防止素材被换掉后这条用例悄悄退化成"只验了 1 页"
        @Assert(totalPages >= 30)
    }

    /// 页体被篡改必须被拒 —— 证明校验真的被**调用**，而不只是"算得对"。
    ///
    /// 做法：就地改写真实素材的**最后一个字节**（只动页体内容，不动页结构的
    /// 任何字段，包括 CRC 字段本身），于是重算值与存储值必然不同。
    @TestCase
    func corruptedPageIsRejected() {
        if (gsSkipIfNoFixtures("corruptedPageIsRejected")) {
            return
        }

        let data = ocReadWhole("testdata/ogg/ogg_flac.oga")
        @Assert(data.size > 100)

        data[data.size - 1] = data[data.size - 1] ^ 0xFF
        let tmp = testTmpPath("a4cj_ogg_crc_bad.oga")
        File.writeTo(tmp, data)

        // 打开阶段只读元数据链（前几页），故损坏要到解码阶段才被碰到
        let kernel = PureFlacKernel(tmp, true)
        let channels = kernel.channels()
        let buf = Array<UInt8>(4096 * channels * 4, repeat: 0)

        var caught = false
        try {
            var got: Int64 = 1
            while (got > 0) {
                got = kernel.readF32Into(buf, 4096)
            }
        } catch (e: CorruptedFileException) {
            caught = true
        }
        kernel.close()

        // 只捕获库内异常：若抛出的是越界/溢出等其它异常，会向上传播让用例失败 ——
        // 那正是我们希望暴露的东西，不能被这里吞掉。
        @Assert(caught)
    }
}
