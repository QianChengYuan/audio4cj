package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import audio4cj.meta.Tag
import audio4cj.pcm.AudioBuffer
import audio4cj.stream.AsyncFrameStream
import std.collection.ArrayList
import std.collection.concurrent.*
import std.env.*
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

    // -----------------------------------------------------------------
    // 2026-10-21 审查修复回归
    // -----------------------------------------------------------------

    /// P2-1：`openBytes` 对损坏字节流抛异常时不得残留临时文件。
    ///
    /// 【v0.2.0 后的口径】全容器已内存直通、不再产生临时文件 —— 本用例从
    /// 「验证清理逻辑」转为「验证根本不落盘」：损坏字节在任何容器上都应在
    /// **进入装配之前或装配内部**直接抛异常，全程无文件系统写入。
    @TestCase
    func openBytesCleansTempFileOnFailure() {
        // 探测可通过（"fLaC" 头）但打开必失败的截断字节
        let junk = rfPrefix(rfReadWhole("testdata/flac/flac_s16_44100_stereo.flac"), 24)

        @AssertThrows[Audio4CjException](AudioFile.openBytes(junk))

        // 临时目录里不得出现 audio4cj_*（用例运行前后都不该有）
        let dir = getVariable("TMPDIR") ?? getVariable("TEMP") ?? getVariable("TMP") ?? "."
        for (e in Directory.readFrom(dir)) {
            @Assert(!e.name.startsWith("audio4cj_"))
        }
    }

    /// P2-1 的正向路径：合法字节流 openBytes 成功后 close，同样不落盘。
    @TestCase
    func openBytesSuccessPathAlsoCleansUp() {
        let bytes = rfReadWhole("testdata/flac/flac_s16_44100_stereo.flac")
        let f = AudioFile.openBytes(bytes)
        @Assert(f.info().sampleRate > 0)
        f.close()

        let dir = getVariable("TMPDIR") ?? getVariable("TEMP") ?? getVariable("TMP") ?? "."
        for (e in Directory.readFrom(dir)) {
            @Assert(!e.name.startsWith("audio4cj_"))
        }
    }

    /// P2-1 的补充路径：readAll 的"半关闭"（drain）路径同样不落盘。
    ///
    /// 【历史说明】v0.1.6～v0.1.9 该路径曾泄漏临时文件（清理必须挂在所有
    /// 置关闭状态的路径上）；v0.2.0 内存直通后无临时文件，保留用例作为
    /// 「readAll + close 之后对象状态自洽」的守护。
    @TestCase
    func openBytesReadAllPathAlsoCleansUp() {
        let bytes = rfReadWhole("testdata/flac/flac_s16_44100_stereo.flac")
        let f = AudioFile.openBytes(bytes)
        let out = f.readAll()
        @Assert(out.frameCount > 0)
        // readAll 之后对象已"半关闭"，close() 是幂等收尾（也可能被使用者省略）
        f.close()

        let dir = getVariable("TMPDIR") ?? getVariable("TEMP") ?? getVariable("TMP") ?? "."
        for (e in Directory.readFrom(dir)) {
            @Assert(!e.name.startsWith("audio4cj_"))
        }
    }

    /// ByteSource 泛化（v0.2.0）：全部容器的 openBytes 免落盘直通。
    ///
    /// 守护口径：打开前后临时目录的 `audio4cj_` 文件数**不增**，且解码结果
    /// 与文件路径打开一致。FLAC 的 metadata() 走内核缓存（零 I/O），
    /// Ogg-FLAC 的页重组直接吃内存源 —— 两者均不再依赖文件路径。
    @TestCase
    func openBytesMp3WavNoTempFile() {
        let dir = getVariable("TMPDIR") ?? getVariable("TEMP") ?? getVariable("TMP") ?? "."
        let countBefore = countTempFiles(dir)

        // MP3：直通路径
        let mp3 = AudioFile.openBytes(rfReadWhole("testdata/mp3/mp3_cbr_128k.mp3"))
        @Assert(mp3.info().sampleRate > 0)
        let mp3Frames = mp3.readAll().frameCount
        mp3.close()
        // 与文件路径打开的解码结果交叉验证（同一份字节，帧数必须一致）
        try (f = AudioFile.open("testdata/mp3/mp3_cbr_128k.mp3")) {
            @Expect(f.readAll().frameCount, mp3Frames)
        }

        // WAV：直通路径（含 metadata 的 LIST/INFO 解析）
        let wav = AudioFile.openBytes(rfReadWhole("testdata/wav/wav_s16_44100_stereo.wav"))
        @Assert(wav.info().sampleRate > 0)
        @Assert(wav.metadata().title.isNone() || wav.metadata().title.isSome()) // metadata() 不抛异常即达意
        let wavFrames = wav.readAll().frameCount
        wav.close()
        try (f = AudioFile.open("testdata/wav/wav_s16_44100_stereo.wav")) {
            @Expect(f.readAll().frameCount, wavFrames)
        }

        // FLAC：直通路径（元数据扫描缓存标签块，metadata() 零 I/O）
        let flac = AudioFile.openBytes(rfReadWhole("testdata/flac/flac_tagged.flac"))
        @Assert(flac.info().sampleRate > 0)
        let flacTag = flac.metadata()
        @Assert(flacTag.title.isSome()) // flac_tagged 带注释头，内核缓存路径必须解析出标题
        let flacFrames = flac.readAll().frameCount
        flac.close()
        try (f = AudioFile.open("testdata/flac/flac_tagged.flac")) {
            @Expect(f.readAll().frameCount, flacFrames)
        }

        // Ogg-FLAC：直通路径（页重组吃内存源）
        let ogg = AudioFile.openBytes(rfReadWhole("testdata/ogg/ogg_flac.oga"))
        @Assert(ogg.info().sampleRate > 0)
        let oggFrames = ogg.readAll().frameCount
        ogg.close()
        try (f = AudioFile.open("testdata/ogg/ogg_flac.oga")) {
            @Expect(f.readAll().frameCount, oggFrames)
        }

        @Expect(countTempFiles(dir), countBefore)
    }

    /// 临时目录里 `audio4cj_` 前缀文件数（openBytes 桥接文件的前缀约定）。
    private func countTempFiles(dir: String): Int64 {
        var n: Int64 = 0
        for (e in Directory.readFrom(dir)) {
            if (e.name.startsWith("audio4cj_")) {
                n += 1
            }
        }
        n
    }

    /// ByteSource 泛化第二阶段（v0.2.0）：FLAC 内存直通的**语义完整性**。
    ///
    /// openBytesMp3WavNoTempFile 已验证"不落盘 + 帧数一致"，本用例进一步钉死：
    ///   1. metadata() 走内核缓存路径 —— 封面（PICTURE 块）必须取到，与文件路径
    ///      打开的结果逐字段一致（这是缓存路径独有的风险点：块收集在解码内核，
    ///      装配在 meta 层，两条代码路径的衔接处最容易漂移）；
    ///   2. seek + rewind（reopen 语义）在内存源上照常工作 ——
    ///      读几帧后 seekTo(0) 再读，须与首次读取逐样本一致。
    @TestCase
    func openBytesFlacMetadataAndSeek() {
        let bytes = rfReadWhole("testdata/flac/flac_cover.flac")

        // 1) metadata：内存直通与文件路径打开结果逐字段一致（封面走 PICTURE 块）
        let fromFile = AudioFile.open("testdata/flac/flac_cover.flac").metadata()
        let memAf = AudioFile.openBytes(bytes)
        let fromMem = memAf.metadata()
        memAf.close()
        @Expect(fromFile.title, fromMem.title)
        @Expect(fromFile.artist, fromMem.artist)
        @Assert(fromMem.coverArt.isSome())
        if (let Some(a) <- fromFile.coverArt) {
            if (let Some(b) <- fromMem.coverArt) {
                @Expect(a.size, b.size)
            } else {
                @Assert(false)
            }
        }

        // 2) seek / rewind：内存源的 reopen 必须回到流起点，逐样本复现
        let f2 = AudioFile.openBytes(bytes)
        let first = f2.readFrames(16)
        @Assert(first.frameCount > 0)
        // 注意 readFrames 的 drain 是"半关闭"：seek 须在首次读取前完成语义校验。
        // 改为：打开两个实例，一个只 seek，一个先读后对照 —— 或者简单点，
        // 直接用 stream() 低层接口避免 drain 副作用。这里用后者。
        f2.close()
        let f3 = AudioFile.openBytes(bytes)
        let s = f3.stream()
        let buf1 = s.next()
        @Assert(buf1.isSome())
        @Expect(f3.seekTo(0), 0)
        let buf2 = s.next()
        @Assert(buf2.isSome())
        // seekTo(0) 后重新读到的首块必须与首次读取逐样本一致
        let b1 = buf1.getOrThrow()
        let b2 = buf2.getOrThrow()
        @Expect(b1.frameCount, b2.frameCount)
        var i: Int64 = 0
        while (i < b1.samples.size) {
            @Expect(b1.samples[i], b2.samples[i])
            i += 1
        }
        s.close()
        f3.close()
    }

    /// P2-2：MP3 无 Xing/VBRI 锚点时，durationEstimated 必须为 true；
    /// 有锚点（或非 MP3 格式）时必须为 false。
    @TestCase
    func durationEstimatedReflectsEstimation() {
        // WAV / FLAC 从容器精确读出，恒为 false
        try (f = AudioFile.open("testdata/wav/wav_s16_44100_stereo.wav")) {
            @Assert(!f.info().durationEstimated)
        }
        try (f = AudioFile.open("testdata/flac/flac_s16_44100_stereo.flac")) {
            @Assert(!f.info().durationEstimated)
        }
        // 无锚点的裸 MP3（由 mp3_cbr_128k.mp3 剥掉 Info 锚点帧构造，现成素材）
        try (f = AudioFile.open("testdata/mp3/mp3_noanchor_cbr.mp3")) {
            let info = f.info()
            @Assert(info.durationEstimated)
            @Assert(info.totalFrames > 0)
            @Assert(info.durationMs > 0)
        }
    }
}
