package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.format.parseSeekTable
import std.collection.ArrayList

/* ============================================================================
 * FLAC SEEKTABLE 解析测试
 *
 * 【为什么用合成字节而不是真实素材】
 *   现有 7 个素材**一个 SEEKTABLE 都没有**（ffmpeg 的 FLAC 编码器默认不写，
 *   而参考 flac CLI 本机不可用）。所以解析层用合成字节精确构造各种形态 ——
 *   这反而是更强的测法：可以按需造出"占位点""非升序""长度非 18 倍数"等
 *   真实素材里很难出现的边界。
 *
 * 【重点防的是"大端写反"】
 *   三个字段都是大端；若实现里按小端读，只有**值大于 0xFF** 的用例才能暴露 ——
 *   因此下面的定位点样本号刻意取 0x0000_0000_0001_2345 这种跨字节的值，
 *   而不是 1、2、3。
 * ========================================================================== */

/// 大端 64 位。
private func stAppendBeUInt64(out: ArrayList<UInt8>, v: Int64): Unit {
    var i: Int64 = 7
    while (i >= 0) {
        out.add(UInt8((v >> (i * 8)) & 0xFF))
        i -= 1
    }
}

/// 大端 16 位。
private func stAppendBeUInt16(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

/// 拼一个定位点。
private func stAppendPoint(out: ArrayList<UInt8>, sample: Int64, offset: Int64, frameSamples: Int64): Unit {
    stAppendBeUInt64(out, sample)
    stAppendBeUInt64(out, offset)
    stAppendBeUInt16(out, frameSamples)
}

/// 占位点：样本号为 2^64-1。
private func stAppendPlaceholder(out: ArrayList<UInt8>, offset: Int64): Unit {
    var i: Int64 = 0
    while (i < 8) {
        out.add(0xFF)
        i += 1
    }
    stAppendBeUInt64(out, offset)
    stAppendBeUInt16(out, 4096)
}

@Test
class FlacSeekTableTest {
    /// 三个字段按大端解出，且顺序正确。
    @TestCase
    func parsesFieldsInBigEndian(): Unit {
        let body = ArrayList<UInt8>()
        stAppendPoint(body, 0x12345, 0x6789AB, 4096)
        stAppendPoint(body, 0x12345 + 4096, 0x70000, 4096)

        let points = parseSeekTable(body.toArray())
        @Assert(points.size == 2)
        @Assert(points[0].sampleNumber == 0x12345)
        @Assert(points[0].streamOffset == 0x6789AB)
        @Assert(points[0].frameSamples == 4096)
        @Assert(points[1].sampleNumber == 0x12345 + 4096)
        @Assert(points[1].streamOffset == 0x70000)
    }

    /// 空块体 ⇒ 空表（合法：SEEKTABLE 允许存在但没有任何点）。
    @TestCase
    func emptyBodyYieldsEmptyTable(): Unit {
        let empty: Array<UInt8> = []
        @Assert(parseSeekTable(empty).size == 0)
    }

    /// 占位点被跳过，真实点保留。
    @TestCase
    func placeholderPointsAreSkipped(): Unit {
        let body = ArrayList<UInt8>()
        stAppendPoint(body, 100, 0, 4096)
        stAppendPlaceholder(body, 0)
        stAppendPlaceholder(body, 0)

        let points = parseSeekTable(body.toArray())
        @Assert(points.size == 1)
        @Assert(points[0].sampleNumber == 100)
    }

    /// 长度不是 18 的整数倍 ⇒ 抛异常（结构损坏，不能猜）。
    @TestCase
    func raggedLengthThrows(): Unit {
        let body = ArrayList<UInt8>()
        stAppendPoint(body, 0, 0, 0)
        body.add(0x00) // 多出一个字节

        var threw = false
        try {
            let _ = parseSeekTable(body.toArray())
        } catch (e: CorruptedFileException) {
            threw = true
        }
        @Assert(threw)
    }

    /// 样本号非升序 ⇒ 抛异常。
    ///
    /// 【为什么必须拒绝而不是容忍】seek 依赖"表按样本号递增"做查找；
    /// 容忍乱序会让 seek 落到错误位置并**静默给出错位的音频** ——
    /// 那比直接报错糟得多。
    @TestCase
    func nonAscendingSamplesThrow(): Unit {
        let body = ArrayList<UInt8>()
        stAppendPoint(body, 5000, 0, 4096)
        stAppendPoint(body, 1000, 4096, 4096)

        var threw = false
        try {
            let _ = parseSeekTable(body.toArray())
        } catch (e: CorruptedFileException) {
            threw = true
        }
        @Assert(threw)
    }

    /// 样本号/偏移超出 Int64 ⇒ 抛异常（而不是静默回绕成负数）。
    @TestCase
    func overflowingValuesThrow(): Unit {
        let body = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i < 8) {
            body.add(0xFF) // 0xFFFF…FF 去掉最后一字节的 F ⇒ 略小于 2^64-1，即超出 Int64
            i += 1
        }
        body[7] = 0xFE
        stAppendBeUInt64(body, 0)
        stAppendBeUInt16(body, 4096)

        var threw = false
        try {
            let _ = parseSeekTable(body.toArray())
        } catch (e: CorruptedFileException) {
            threw = true
        }
        @Assert(threw)
    }
}
