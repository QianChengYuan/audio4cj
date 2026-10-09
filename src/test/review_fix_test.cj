package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import audio4cj.pcm.AudioBuffer
import audio4cj.stream.AsyncFrameStream
import std.collection.ArrayList
import std.collection.concurrent.*
import std.fs.*
import std.sync.*
import std.time.*

/* ============================================================================
 * 代码审查修复回归 —— 每项确认缺陷留一条「当年会红、现在必须绿」的用例
 *
 * 【这一组用例压的是什么】
 *   针对一轮外部审查中**实测复现**的缺陷。它们的共同点是"契约被违反但不崩在
 *   明面上"：消费者永久挂起、标准库异常冒充库异常、数组越界冒充库异常、
 *   返回值与内部状态自相矛盾。用户代码最怕的正是这一类 —— 既没有编译错误，
 *   也没有可读的错误信息。
 *
 *   1) 异步流后台线程解码失败 → 消费者 `next()` 永久挂死（P0-1）
 *   2) 孤立 UTF-16 代理项 → `Rune(unit)` 抛 OverflowException（P0-2）
 *   3) Ogg 页在文件末尾被截断 → `table[i]` 越界 IndexOutOfBounds（P0-3）
 *   4) `seekTo(Int64.Max)` → 乘法溢出 OverflowException（P0-4）
 *   5) `AudioBuffer.samples` 返回内部数组 → 外部改写污染"不可变快照"（P1-1）
 *   6) `readAll()` 之后 `isClosed()` 仍为 false，但其它方法全抛（P1-2）
 *
 *   断言口径统一：**只接受正常返回或库内异常（Audio4CjException 及其子类）
 *   / 文件系统异常**；其它异常（越界、溢出、类型转换失败）一律向上传播使用例
 *   失败 —— 那正是"契约被违反"的信号。
 *
 * 【为什么 P0-1 要另起线程 + 超时】
 *   缺陷形态是"消费者永久阻塞在 next() 上"，若直接在测试线程里跑，回归发生时
 *   用例会挂死而不是变红（挂死的用例在 CI 上只会表现为"整个套件超时"）。
 *   故把消费放到 spawn 出来的线程，主线程用带超时的队列等待结果：
 *   预算内没返回即判定挂死。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

private func rfAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

/// 大端 32 位（ID3v2.3 帧长度字段的字节序）。
private func rfAppendUInt32BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 24) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func rfWrite(name: String, bytes: Array<UInt8>): String {
    let path = testTmpPath(name)
    File.writeTo(path, bytes)
    path
}

/// 读取整个文件（写法与 flac_crc_test 的 crcReadWhole 一致：
/// `try (…) { … }` 是语句，不能在其中 return）。
private func rfReadWhole(path: String): Array<UInt8> {
    var out = Array<UInt8>()
    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        out = buf[0..got]
    }
    out
}

/// 取前 n 字节的独立副本。
private func rfPrefix(bytes: Array<UInt8>, n: Int64): Array<UInt8> {
    var out = Array<UInt8>(n, repeat: 0)
    for (i in 0..n) {
        out[i] = bytes[i]
    }
    out
}

/// 造一个"帧数据被改动过"的 FLAC：改动末尾一帧里的一个字节，必然使其
/// 帧尾 CRC-16 校验失败（帧头 CRC-8 不受影响，仍能顺利 open）。
private func rfWriteCorruptFlac(name: String): String {
    var bytes = rfReadWhole("testdata/flac/flac_s16_44100_stereo.flac")
    let at = bytes.size - 100
    bytes[at] = bytes[at] ^ 0xFF
    rfWrite(name, bytes)
}

/// 在后台线程里把异步流消费完，返回结局字符串：
///   "error" = 抛出库内异常（期望结局）；"end" = 正常走到 None；
///   "other" = 抛出了非库异常（缺陷）；"runaway" = 取块数异常多（兜底）。
private func rfAsyncOutcome(s: AsyncFrameStream): String {
    try {
        var done = false
        var chunks: Int64 = 0
        while (!done) {
            match (s.next()) {
                case Some(_) =>
                    chunks += 1
                    if (chunks > 100000) {
                        return "runaway"
                    }
                case None => done = true
            }
        }
        return "end"
    } catch (e: Audio4CjException) {
        return "error"
    } catch (e: Exception) {
        return "other"
    }
}

/// 打开并有限消费：只接受正常完成或库内/文件系统异常。
private func rfOpenAndDrainIsGraceful(path: String): Bool {
    var graceful = false

    try {
        try (f = AudioFile.open(path)) {
            let s = f.stream()
            var seen: Int64 = 0
            var done = false
            while (!done) {
                match (s.next()) {
                    case Some(_) =>
                        seen += 1
                        if (seen >= 64) {
                            done = true
                        }
                    case None => done = true
                }
            }
            s.close()
        }
        graceful = true
    } catch (e: Audio4CjException) {
        graceful = true
    } catch (e: FSException) {
        graceful = true
    }

    graceful
}

/// 构造最小的畸形 ID3v2.3：TIT2 用 UTF-16 承载**孤立高代理项 0xD800**
/// （无 BOM，小端），共 23 字节。
///
/// 原值：历史实现里 `decodeUtf16` 直接 `Rune(unit)` 会抛
/// `OverflowException: in Rune(num), num is not a valid Unicode scalar value!`
private func rfBuildLoneSurrogateId3(): Array<UInt8> {
    let out = ArrayList<UInt8>()

    rfAppendAscii(out, "ID3")
    out.add(0x03u8) // 主版本 3
    out.add(0x00u8) // 次版本
    out.add(0x00u8) // 标志
    out.add(0x00u8) // 长度 13（synchsafe）
    out.add(0x00u8)
    out.add(0x00u8)
    out.add(0x0Du8)

    rfAppendAscii(out, "TIT2")
    rfAppendUInt32BE(out, 3) // 帧体长度
    out.add(0x00u8) // 标志高字节
    out.add(0x00u8) // 标志低字节

    out.add(0x01u8) // 编码 = UTF-16（带 BOM，但本帧实际无 BOM）
    out.add(0x00u8) // 0xD800 低字节
    out.add(0xD8u8) // 0xD800 高字节

    out.toArray()
}

/// 构造带**合法代理对**的 ID3v2.3：U+1F600（😀）。
/// 用于确认"代理对合成"这条正向路径没有因为补守卫而被破坏。
private func rfBuildSurrogatePairId3(): Array<UInt8> {
    let out = ArrayList<UInt8>()

    rfAppendAscii(out, "ID3")
    out.add(0x03u8)
    out.add(0x00u8)
    out.add(0x00u8)
    out.add(0x00u8) // 长度 17（synchsafe）
    out.add(0x00u8)
    out.add(0x00u8)
    out.add(0x11u8)

    rfAppendAscii(out, "TIT2")
    rfAppendUInt32BE(out, 7)
    out.add(0x00u8)
    out.add(0x00u8)

    out.add(0x01u8) // 编码 = UTF-16
    out.add(0xFFu8) // BOM（小端）
    out.add(0xFEu8)
    out.add(0x3Du8) // 高代理 0xD83D
    out.add(0xD8u8)
    out.add(0x00u8) // 低代理 0xDE00
    out.add(0xDEu8)

    out.toArray()
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class ReviewFixRegressionTest {
    /// P0-1：后台解码失败必须抛给消费者，而不是让它永久阻塞。
    @TestCase
    func asyncStreamSurfacesBackgroundDecodeFailure() {
        let path = rfWriteCorruptFlac("a4cj_rf_bad.flac")

        // 前置校验：同步路径确实在这个文件上抛库内异常。
        // 若这里不抛，说明素材没坏，后面的用例就失去意义了。
        var syncThrew = false
        let probe = AudioFile.open(path)
        try {
            let _ = probe.readAll()
        } catch (e: Audio4CjException) {
            syncThrew = true
        }
        probe.close()
        @Assert(syncThrew)

        let f = AudioFile.open(path)
        let s = AsyncFrameStream.start(f.stream())

        let outcome = ArrayList<String>()
        let signal = ArrayBlockingQueue<?AudioBuffer>(1)

        spawn {
            =>
                try {
                    outcome.add(rfAsyncOutcome(s))
                } catch (e: Exception) {
                    outcome.add("spawn-failed")
                }
                signal.add(None, Duration.millisecond * 20000)
        }

        // 关键：消费者必须在预算内返回。历史缺陷下它会永远等不到结束哨兵。
        var returned = false
        match (signal.remove(Duration.millisecond * 20000)) {
            case Some(_) => returned = true
            case None => ()
        }

        @Assert(returned)
        @Assert(outcome.size == 1)
        @Assert(outcome[0] == "error")

        s.close()
    }

    /// P0-2：孤立 UTF-16 代理项必须被替换为 U+FFFD，而不是抛标准库异常。
    @TestCase
    func loneSurrogateInId3v2IsReplacedInsteadOfThrowing() {
        let path = rfWrite("a4cj_rf_surrogate.mp3", rfBuildLoneSurrogateId3())
        let tag = AudioFile.readTags(path)
        @Expect(tag.title.getOrThrow(), String([Rune(0xFFFDu32)]))
    }

    /// P0-2 的反向保护：合法的代理对仍要正确合成增补平面码点。
    @TestCase
    func validSurrogatePairStillDecodes() {
        let path = rfWrite("a4cj_rf_emoji.mp3", rfBuildSurrogatePairId3())
        let tag = AudioFile.readTags(path)
        @Expect(tag.title.getOrThrow(), String([Rune(0x1F600u32)]))
    }

    /// P0-3：Ogg 页被截断必须报库内异常，而不是数组越界。
    ///
    /// 106 / 187 两处是审查时实测出越界的位置（段表恰好落在 EOF 边界），
    /// 其余长度一并覆盖，防止只有这两点被特判。
    @TestCase
    func truncatedOggFailsGracefully() {
        let whole = rfReadWhole("testdata/ogg/ogg_flac.oga")
        @Assert(whole.size > 210)

        let lengths: Array<Int64> = [8, 23, 27, 64, 105, 106, 107, 186, 187, 188, 300, 1024, 4096, 12999]

        for (n in lengths) {
            if (n >= whole.size) {
                continue
            }
            let path = rfWrite("a4cj_rf_trunc_${n}.oga", rfPrefix(whole, n))
            @Assert(rfOpenAndDrainIsGraceful(path))
        }
    }

    /// P0-4：极端时间戳不得抛标准库溢出异常。
    @TestCase
    func seekToExtremeTimestampDoesNotOverflow() {
        let cases: Array<String> = [
            "testdata/wav/wav_s16_44100_stereo.wav",
            "testdata/flac/flac_s16_44100_stereo.flac",
            "testdata/mp3/mp3_16000_mono.mp3"
        ]

        for (p in cases) {
            try (f = AudioFile.open(p)) {
                var graceful = false
                try {
                    let pos = f.seekTo(Int64.Max)
                    @Assert(pos >= 0)
                    graceful = true
                } catch (e: Audio4CjException) {
                    // FLAC 无 SEEKTABLE 时定位到末尾可能被拒 —— 那也是契约内结局
                    graceful = true
                }
                @Assert(graceful)
            }
        }
    }

    /// P0-4 的反向保护：正常时间戳仍要落在正确位置。
    @TestCase
    func normalSeekStillWorks() {
        try (f = AudioFile.open("testdata/wav/wav_s16_44100_stereo.wav")) {
            @Expect(f.seekTo(0), 0)
            @Expect(f.seekTo(500), 500)
        }
    }

    /// P1-1：`samples` 返回的是快照副本，外部改写不得污染内部数据。
    @TestCase
    func samplesIsAnImmutableSnapshot() {
        let buf = AudioBuffer(44100, 2, [0.0, 0.1, 0.2, 0.3])

        let snap = buf.samples
        snap[0] = 99.0
        @Expect(snap[0], 99.0)
        @Expect(buf.samples[0], 0.0)
        @Expect(buf.samples[3], 0.3)
    }

    /// P1-1：`copyInto` 是给热路径用的整块搬运，语义要与 samples 一致。
    @TestCase
    func copyIntoMovesWholeChunk() {
        let buf = AudioBuffer(44100, 2, [0.0, 0.1, 0.2, 0.3])

        let dst: Array<Float32> = [0.0, 0.0, 0.0, 0.0]
        @Expect(buf.copyInto(dst, 0), 4)
        @Expect(dst[0], 0.0)
        @Expect(dst[3], 0.3)

        let dst2: Array<Float32> = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        @Expect(buf.copyInto(dst2, 2), 4)
        @Expect(dst2[2], 0.0)
        @Expect(dst2[5], 0.3)

        @AssertThrows[Audio4CjException](buf.copyInto(dst, 1))
        let small: Array<Float32> = [0.0, 0.0]
        @AssertThrows[Audio4CjException](buf.copyInto(small, 0))
    }

    /// P1-2：`readAll()` 之后对象必须自洽 —— isClosed() 为 true，
    /// 且所有数据方法统一抛 ClosedResourceException。
    @TestCase
    func readAllLeavesAudioFileConsistentlyClosed() {
        let f = AudioFile.open("testdata/wav/wav_s16_44100_stereo.wav")

        let all = f.readAll()
        @Assert(all.frameCount > 0)

        @Assert(f.isClosed())
        @AssertThrows[ClosedResourceException](f.info())
        @AssertThrows[ClosedResourceException](f.metadata())
        @AssertThrows[ClosedResourceException](f.stream())
        @AssertThrows[ClosedResourceException](f.seekTo(0))
        @AssertThrows[ClosedResourceException](f.readAll())

        // close() 仍须幂等
        f.close()
        f.close()
        @Assert(f.isClosed())
    }

    /// P1-2 的补充：`readFrames()` 走同一条 drain 路径，行为必须一致。
    @TestCase
    func readFramesAlsoLeavesAudioFileClosed() {
        let f = AudioFile.open("testdata/flac/flac_s16_44100_stereo.flac")
        let part = f.readFrames(100)
        @Assert(part.frameCount > 0)
        @Assert(f.isClosed())
        @AssertThrows[ClosedResourceException](f.readFrames(100))
    }
}
