package audio4cj.test

import audio4cj.facade.AudioFile
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * FLAC 解码测试 —— 开发文档 §10 M4
 *
 * 【为什么能自包含构造】
 *   MPC 与 FLAC 的测试可行性截然不同：MP3 的帧数据是 Huffman 编码与频域
 *   变换的产物，手工构造「有意义的音频」等价于实现一个编码器；而 FLAC 规范
 *   定义了 **verbatim 子帧**（子帧类型 0b000001）—— 即未经压缩的原始样本，
 *   可直接内联写入。因此本测试能在内存中拼出**合法且可被解码**的 FLAC 流，
 *   不依赖任何外部音频素材。
 *
 * 【构造的字节结构】
 *   "fLaC"
 *   [STREAMINFO 块]  块头 4 字节（isLast=1, type=0）+ 34 字节块体
 *   [音频帧]
 *     帧头：sync(14) + reserved(1) + blocking(1) + blocksize code(4)
 *           + samplerate code(4) + channel assign(4) + samplesize code(3)
 *           + reserved(1) + UTF-8 帧号(8) + blocksize-1(8) + CRC-8(8)
 *     verbatim 子帧：padding(1) + type(6) + wasted(1) + 原始样本(n*bps 位)
 *     帧尾 CRC-16（2 字节，覆盖整帧）
 *
 * 校验和与位打包均按规范实现（CRC-8 多项式 0x07、CRC-16 多项式 0x8005）。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 位写入器
// ---------------------------------------------------------------------------

/// 按位写入的缓冲器（FLAC 的头与子帧都是非字节对齐的位流）。
private class TestFlacBitWriter {
    private var _bytes = ArrayList<UInt8>()
    private var _cur: Int64 = 0
    private var _bits: Int64 = 0

    /// 写入 `count` 个低位比特（高位在前）。
    func writeBits(value: Int64, count: Int64): Unit {
        var i = count - 1
        while (i >= 0) {
            let bit = (value >> i) & 1
            _cur = (_cur << 1) | bit
            _bits += 1
            if (_bits == 8) {
                _bytes.add(UInt8(_cur & 0xFF))
                _cur = 0
                _bits = 0
            }
            i -= 1
        }
    }

    /// 写入有符号值的 `count` 位补码表示。
    func writeSigned(value: Int32, count: Int64): Unit {
        let mask: Int64 = if (count >= 32) {
            0xFFFFFFFF
        } else {
            (1 << count) - 1
        }
        writeBits(Int64(value) & mask, count)
    }

    /// 补零对齐到字节边界。
    func alignToByte(): Unit {
        while (_bits != 0) {
            writeBits(0, 1)
        }
    }

    /// 当前已写出的完整字节（不含未对齐的残余位）。
    func bytes(): Array<UInt8> {
        _bytes.toArray()
    }

    /// 补零对齐到字节边界后输出全部字节。
    func toArrayBytes(): Array<UInt8> {
        alignToByte()
        _bytes.toArray()
    }
}

// ---------------------------------------------------------------------------
// 校验和（FLAC 规范指定的两个多项式）
// ---------------------------------------------------------------------------

/// CRC-8，多项式 x^8 + x^2 + x + 1（0x07），初值 0。用于帧头校验。
private func flacCrc8(data: Array<UInt8>): UInt8 {
    var crc: UInt32 = 0
    for (b in data) {
        crc = (crc ^ UInt32(b)) & 0xFFu32
        for (i in 0..8) {
            if ((crc & 0x80u32) != 0u32) {
                crc = ((crc << 1) ^ 0x07u32) & 0xFFu32
            } else {
                crc = (crc << 1) & 0xFFu32
            }
        }
    }
    UInt8(crc)
}

/// CRC-16，多项式 x^16 + x^15 + x^2 + 1（0x8005），初值 0。用于整帧校验。
private func flacCrc16(data: Array<UInt8>): UInt16 {
    var crc: UInt32 = 0
    for (b in data) {
        crc = (crc ^ (UInt32(b) << 8)) & 0xFFFFu32
        for (i in 0..8) {
            if ((crc & 0x8000u32) != 0u32) {
                crc = ((crc << 1) ^ 0x8005u32) & 0xFFFFu32
            } else {
                crc = (crc << 1) & 0xFFFFu32
            }
        }
    }
    UInt16(crc)
}

// ---------------------------------------------------------------------------
// FLAC 构造
// ---------------------------------------------------------------------------

/// 构造 STREAMINFO 块体（34 字节 = 272 位）。
private func buildStreamInfo(
    sampleRate: Int64,
    channels: Int64,
    bitsPerSample: Int64,
    totalSamples: Int64,
    blockSize: Int64
): Array<UInt8> {
    let w = TestFlacBitWriter()
    w.writeBits(blockSize, 16) // 最小块大小
    w.writeBits(blockSize, 16) // 最大块大小
    w.writeBits(0, 24) // 最小帧大小（0 = 未知）
    w.writeBits(0, 24) // 最大帧大小（0 = 未知）
    w.writeBits(sampleRate, 20)
    w.writeBits(channels - 1, 3)
    w.writeBits(bitsPerSample - 1, 5)
    w.writeBits(totalSamples, 36)
    w.writeBits(0, 32) // MD5（128 位，此处全零：
    w.writeBits(0, 32) //   常量块解码不校验它，
    w.writeBits(0, 32) //   但对齐与长度必须正确）
    w.writeBits(0, 32)
    w.toArrayBytes()
}

/// 构造一个 verbatim 子帧的音频帧（固定块大小）。
private func buildVerbatimFrame(
    samples: Array<Int32>,
    bitsPerSample: Int64,
    blockSize: Int64,
    frameNumber: Int64
): Array<UInt8> {
    let w = TestFlacBitWriter()

    // ---- 帧头 ----
    w.writeBits(0x3FFE, 14) // 同步码 0b11111111111110
    w.writeBits(0, 1) // reserved
    w.writeBits(0, 1) // 阻塞策略 0 = 固定块大小
    w.writeBits(6, 4) // 块大小码 6 -> 头部末尾跟 8 位 (blocksize-1)
    w.writeBits(9, 4) // 采样率码 9 = 44.1 kHz
    w.writeBits(0, 4) // 声道分配 0 = 单声道
    w.writeBits(4, 3) // 样本宽度码 4 = 16 位
    w.writeBits(0, 1) // reserved
    w.writeBits(frameNumber, 8) // UTF-8 编码的帧号（<128 时占 1 字节）
    w.writeBits(blockSize - 1, 8) // 块大小 - 1
    w.alignToByte() // 至此恰好 6 字节

    // 帧头 CRC-8（覆盖帧头全部字节）
    let headerBytes = w.bytes()
    w.writeBits(Int64(flacCrc8(headerBytes)), 8)

    // ---- 子帧（verbatim）----
    w.writeBits(0, 1) // 子帧填充位
    w.writeBits(1, 6) // 子帧类型 000001 = verbatim
    w.writeBits(0, 1) // 无效位标志
    for (s in samples) {
        w.writeSigned(s, bitsPerSample)
    }

    w.alignToByte()
    let frameSoFar = w.bytes()

    // ---- 帧尾 CRC-16（覆盖整帧到此处）----
    w.writeBits(Int64(flacCrc16(frameSoFar)), 16)
    w.toArrayBytes()
}

/// 组装完整 FLAC 文件。
private func buildFlacFile(
    samples: Array<Int32>,
    bitsPerSample: Int64,
    sampleRate: Int64
): Array<UInt8> {
    let blockSize = Int64(samples.size)
    let out = ArrayList<UInt8>()

    for (b in "fLaC".toArray()) {
        out.add(b)
    }

    // STREAMINFO 块头：最高位 = 1（最后一个元数据块），低 7 位 = 0（类型 0）
    let si = buildStreamInfo(sampleRate, 1, bitsPerSample, blockSize, blockSize)
    out.add(0x80u8)
    out.add(UInt8((si.size >> 16) & 0xFF))
    out.add(UInt8((si.size >> 8) & 0xFF))
    out.add(UInt8(si.size & 0xFF))
    for (b in si) {
        out.add(b)
    }

    // 音频帧
    let frame = buildVerbatimFrame(samples, bitsPerSample, blockSize, 0)
    for (b in frame) {
        out.add(b)
    }

    out.toArray()
}

/// 写临时 FLAC 文件并返回路径。
private func writeFlac(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class FlacDecodeTest {
    /// 手工构造的 verbatim 帧能被正确解码，样本值与归一化规则一致
    @TestCase
    func decodesVerbatimFrameSamples() {
        // 16 个样本（FLAC 规范要求块大小不小于 16），覆盖正负边界
        let samples: Array<Int32> = [
            -32768,
            -16384,
            -8192,
            0,
            8192,
            16384,
            32767,
            100,
            -100,
            1,
            -1,
            2,
            -2,
            3,
            -3,
            4
        ]
        let path = writeFlac("a4cj_verbatim.flac", buildFlacFile(samples, 16, 44100))

        try (f = AudioFile.open(path)) {
            let buf = f.readAll()

            @Assert(buf.frameCount == 16)
            @Assert(buf.sampleCount == 16)
            @Assert(buf.channels == 1)
            @Assert(buf.sampleRate == 44100)

            // 归一化：v / 32768.0（与主流解码器口径一致）
            @Assert(buf.samples[0] == -1.0)
            @Assert(buf.samples[1] == -0.5)
            @Assert(buf.samples[2] == -0.25)
            @Assert(buf.samples[3] == 0.0)
            @Assert(buf.samples[4] == 0.25)
            @Assert(buf.samples[5] == 0.5)
        }
        remove(path)
    }

    /// STREAMINFO 中的参数被正确读取
    @TestCase
    func reportsStreamInfo() {
        let samples: Array<Int32> = [
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
        ]
        let path = writeFlac("a4cj_streaminfo.flac", buildFlacFile(samples, 16, 48000))

        try (f = AudioFile.open(path)) {
            let info = f.info()
            @Assert(info.sampleRate == 48000)
            @Assert(info.channels == 1)
            @Assert(info.bitDepth == 16)
            @Assert(info.totalFrames == 16)
        }
        remove(path)
    }

    /// 分块流式读取不丢帧，且与 readAll 结果一致
    @TestCase
    func streamingMatchesReadAll() {
        let samples: Array<Int32> = [
            -32768,
            -24576,
            -16384,
            -8192,
            0,
            8192,
            16384,
            24576,
            32767,
            1000,
            -1000,
            500,
            -500,
            250,
            -250,
            125
        ]
        let path = writeFlac("a4cj_stream.flac", buildFlacFile(samples, 16, 44100))

        // 流式：累计帧数应精确等于 16
        try (f = AudioFile.open(path)) {
            let s = f.stream()
            var frames: Int64 = 0
            while (let Some(chunk) <- s.next()) {
                frames += chunk.frameCount
            }
            @Assert(frames == 16)
        }

        // readAll：抽查首尾样本
        try (f2 = AudioFile.open(path)) {
            let all = f2.readAll()
            @Assert(all.frameCount == 16)
            @Assert(all.samples[0] == -1.0)
            @Assert(all.samples[8] == Float32(32767) / 32768.0)
        }
        remove(path)
    }

    /// seek 返回实际落点，且 seek 后读取的数据正确
    @TestCase
    func seekReturnsActualPosition() {
        let samples: Array<Int32> = [
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            16384,
            16384,
            16384,
            16384,
            16384,
            16384,
            16384,
            16384
        ]
        let path = writeFlac("a4cj_seek.flac", buildFlacFile(samples, 16, 8000))

        try (f = AudioFile.open(path)) {
            // 8000 Hz 下 1 ms = 8 帧，定位到第 8 帧
            let actual = f.seekTo(1)
            @Assert(actual == 1)

            let buf = f.readFrames(8)
            @Assert(buf.frameCount == 8)
            // 第 8 帧起应为 0.5（= 16384 / 32768）
            @Assert(buf.samples[0] == 0.5)
        }
        remove(path)
    }

    /// 元数据读取（M3 的 FLAC 块链解析）应能在该自包含文件上正常工作
    @TestCase
    func metadataReturnsEmptyTagWhenNoCommentBlock() {
        let samples: Array<Int32> = [
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
        ]
        let path = writeFlac("a4cj_meta.flac", buildFlacFile(samples, 16, 44100))

        try (f = AudioFile.open(path)) {
            let tag = f.metadata()
            // 该文件只有 STREAMINFO，没有 VORBIS_COMMENT 块
            @Assert(tag.hasNoStandardFields())
        }
        remove(path)
    }
}
