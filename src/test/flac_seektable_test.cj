package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.format.parseSeekTable
import audio4cj.format.parseStreamInfo
import audio4cj.format.findFirstFrameOffset
import audio4cj.format.decodeFrame
import audio4cj.format.BitReader
import audio4cj.format.PureFlacKernel
import audio4cj.format.FLAC_MARKER_SIZE
import audio4cj.pcm.reinterpretF32Bytes
import std.collection.ArrayList
import std.fs.*

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

/// 读取整个文件（与 flac_crc_test 的同名辅助同理；private 是文件级的，故各自一份）。
private func stReadWhole(path: String): Array<UInt8> {
    var out = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        out = buf[0..got]
    }
    out
}

/// 写成临时文件。
private func stWriteTemp(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 遍历一整份 FLAC 内存镜像，记录每帧的 (首样本号, 相对首帧的字节偏移)。
///
/// 用**本库自己的帧解码器**走边界：帧长只有在解出帧尾 CRC-16 之后才知道，
/// 而 `FlacFrame.frameEndByte` 恰好给出这个位置。
///
/// 这里只负责**造素材**，不承担正确性 —— 偏移若记错，后面"跳过去解出来的音频
/// 必须与顺序解码逐样本一致"会立刻失败（错位的音频不可能对上）。
private func stFramePoints(image: Array<UInt8>): ArrayList<(Int64, Int64)> {
    let info = parseStreamInfo(image)
    let firstFrame = findFirstFrameOffset(image)
    let reader = BitReader(image)
    let out = ArrayList<(Int64, Int64)>()

    var pos = firstFrame
    var sample: Int64 = 0
    while (pos < image.size) {
        reader.seekToBit(pos * 8)
        let frame = decodeFrame(reader, info)
        out.add((sample, pos - firstFrame))
        sample += frame.blockSize
        pos = frame.frameEndByte
    }
    out
}

/// 把一份 SEEKTABLE 插到 STREAMINFO 之后，返回新的文件镜像。
///
/// 【要点一：插在 STREAMINFO 之后】STREAMINFO 必须仍是首块。
/// 【要点二：清掉 STREAMINFO 的 last 标志】它后面现在多了一块；
///   若不清，解析器会在 STREAMINFO 处就认为元数据结束，把新块当成音频帧。
/// 【要点三：定位点偏移无需调整】规范把偏移定义成"相对**首帧**"，
///   所以元数据变长不影响任何已有偏移 —— 这正是该设计的用意。
private func stSpliceSeekTable(image: Array<UInt8>, points: ArrayList<(Int64, Int64)>, step: Int64): Array<UInt8> {
    let body = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < points.size) {
        stAppendBeUInt64(body, points[i][0])
        stAppendBeUInt64(body, points[i][1])
        stAppendBeUInt16(body, 4096)
        i += step
    }
    let bodyLen = body.size

    let insAt = FLAC_MARKER_SIZE + 4 + 34 // fLaC + STREAMINFO 块头 + 34 字节块体
    let out = ArrayList<UInt8>()

    var j: Int64 = 0
    while (j < insAt) {
        // 顺带清掉 STREAMINFO 头的 last 位（第 4 字节的最高位）
        if (j == FLAC_MARKER_SIZE) {
            out.add(image[j] & 0x7F)
        } else {
            out.add(image[j])
        }
        j += 1
    }

    // 新块头：类型 3、last = 0（后面还有原有的块），长度为 24 位大端
    out.add(0x03)
    out.add(UInt8((bodyLen >> 16) & 0xFF))
    out.add(UInt8((bodyLen >> 8) & 0xFF))
    out.add(UInt8(bodyLen & 0xFF))
    for (b in body) {
        out.add(b)
    }

    while (j < image.size) {
        out.add(image[j])
        j += 1
    }
    out.toArray()
}

/// seek 到 `target` 后读一小段，返回 (音频, 自本次 seek 起解码的帧数)。
private func stSeekAndRead(path: String, target: Int64, chunkFrames: Int64): (Array<Float32>, Int64) {
    let kernel = PureFlacKernel(path)
    let channels = kernel.channels()
    let _ = kernel.seekToFrame(target)

    let buf = Array<UInt8>(chunkFrames * channels * 4, repeat: 0)
    let got = kernel.readF32Into(buf, chunkFrames)
    let audio = if (got > 0) {
        reinterpretF32Bytes(buf[0..got * channels * 4])
    } else {
        Array<Float32>(0, repeat: 0.0)
    }
    let frames = kernel.framesSinceReposition()
    kernel.close()
    (audio, frames)
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

    // ------------------------------------------------------------------
    // 集成：拼入真实文件，验证 seek 真的走定位点
    // ------------------------------------------------------------------

    /// 有 SEEKTABLE 时：能解析出定位点、seek 走定位点、音频与无表时**逐样本一致**，
    /// 且**解码帧数显著更少**。
    ///
    /// 【为什么必须做 A/B 对比】只看"有表"一侧解出的音频对不对，无法区分
    /// "表生效了"与"表被忽略、仍走从头解码"—— 两者音频必然相同。
    /// 只有拿"无表"一侧的**解码帧数**作对照，才能证明表真的被用上。
    @TestCase
    func splicedSeekTableIsParsedAndUsed(): Unit {
        let image = stReadWhole("testdata/flac/flac_s16_44100_stereo.flac")
        let points = stFramePoints(image)
        @Assert(points.size >= 4) // 素材太短则这个对比没有意义

        let spliced = stSpliceSeekTable(image, points, 1)
        let pathNoTable = stWriteTemp("a4cj_noseek.flac", image)
        let pathWithTable = stWriteTemp("a4cj_withseek.flac", spliced)

        // ① 定位点确实被解析出来（数量应与拼入的点数一致）
        let probe = PureFlacKernel(pathWithTable)
        @Assert(probe.seekPointCount() == points.size)
        probe.close()

        // 目标取倒数第二帧的起点：前面必有定位点，且不是文件末尾
        let target = points[points.size - 2][0]

        let (audioNoTable, framesNoTable) = stSeekAndRead(pathNoTable, target, 512)
        let (audioWithTable, framesWithTable) = stSeekAndRead(pathWithTable, target, 512)

        // ② 两侧音频必须逐样本一致（SEEKTABLE 不得改变解码结果）
        @Assert(audioNoTable.size > 0)
        @Assert(audioNoTable.size == audioWithTable.size)
        var identical = true
        for (i in 0..audioNoTable.size) {
            if (audioNoTable[i] != audioWithTable[i]) {
                identical = false
            }
        }
        @Assert(identical)

        // ③ 有表一侧必须真的少解码：每个帧都有定位点，故应只解目标那一帧
        @Assert(framesWithTable < framesNoTable)
        @Assert(framesWithTable <= 2)
    }
}
