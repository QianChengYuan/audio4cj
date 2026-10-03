package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import std.fs.*
import std.collection.ArrayList
import std.sync.*

/* ============================================================================
 * 长时运行稳定性与并发正确性 —— 开发文档 §10 M5
 *
 * 本文件覆盖三类问题：
 *
 *   1. **长时运行的正确性**：完整解码长素材，验证累计帧数与容器声明的总帧数
 *      一致、且分块大小始终有界（若有累积，块会越来越大）。
 *
 *   2. **句柄泄漏**：反复开关文件，每轮结束后删除它。若文件句柄泄漏，
 *      Windows 会报「文件被其它进程占用」而删除失败 —— 这正是本项目
 *      在 M5 期间真实出现过的缺陷（构造失败时未释放 dr_libs 句柄），
 *      因此这里对**成功路径与失败路径**都做回归。
 *
 *   3. **并发正确性**：多个线程各自持有独立实例解码，结果必须与串行基线
 *      逐位一致；且**必须显式汇合**（主线程退出会杀死未完成的子线程）。
 *
 * 【关于「峰值内存恒定」的诚实说明】
 *   开发文档该条目的表述是「分块解码 1 小时音频，峰值内存恒定」。本文件
 *   做到的是**结构性与正确性证据**：分块大小恒定有界 + 长素材完整解码
 *   不失败 + 反复开关不泄漏句柄。**未做进程 RSS 的量化测量** —— 仓颉 std
 *   是否提供内存统计 API 尚未核实，无法在不引入不可靠手段的前提下断言
 *   「峰值内存恒定」。此处如实记录，不把未测项写成已测项。
 *
 * 【素材依赖】
 *   长时运行用例依赖 `musics/` 下的真实素材；素材缺失时**打印提示后跳过**
 *   （不失败），以保证在无素材环境（如未来 CI）中整套测试仍为绿。
 * ========================================================================== */

/// 长素材（相对工作区根）。选体积最小的一份以控制测试时长。
private let LONG_FLAC: String = "musics/青花瓷 - 周杰伦.flac"
// 这里曾有 LONG_MP3 及其长时解码用例。MP3 解码已移出本版本范围，故一并移除 ——
// 留着它会是一个必然失败的用例，或一个永不执行的空壳，两者都比"没有"更糟。

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

private func lrAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func lrAppendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func lrAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

private func lrWrite(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 构造 16-bit 单声道 WAV（样本值可预测）。
private func lrBuildWav(frameCount: Int64): Array<UInt8> {
    let dataSize = frameCount * 2
    let riffSize = 4 + 8 + 16 + 8 + dataSize

    let out = ArrayList<UInt8>()
    lrAppendAscii(out, "RIFF")
    lrAppendUInt32LE(out, riffSize)
    lrAppendAscii(out, "WAVE")

    lrAppendAscii(out, "fmt ")
    lrAppendUInt32LE(out, 16)
    lrAppendUInt16LE(out, 1)
    lrAppendUInt16LE(out, 1)
    lrAppendUInt32LE(out, 44100)
    lrAppendUInt32LE(out, 88200)
    lrAppendUInt16LE(out, 2)
    lrAppendUInt16LE(out, 16)

    lrAppendAscii(out, "data")
    lrAppendUInt32LE(out, dataSize)

    for (i in 0..frameCount) {
        let sample = Int32(i % 1000) - 500
        out.add(UInt8(sample & 0xFF))
        out.add(UInt8((sample >> 8) & 0xFF))
    }

    out.toArray()
}

/// 构造「STREAMINFO 全零」的 FLAC：参数非法，`AudioFile.open` 必然抛异常。
/// 用于验证**构造失败路径**不泄漏文件句柄。
private func lrBuildZeroStreamInfoFlac(): Array<UInt8> {
    let out = ArrayList<UInt8>()
    lrAppendAscii(out, "fLaC")
    out.add(0x80u8) // isLast = 1、类型 0（STREAMINFO）
    out.add(0u8)
    out.add(0u8)
    out.add(34u8) // 长度 34
    for (i in 0..34) {
        out.add(0u8) // 全零：采样率 0、最大块大小 0
    }
    out.toArray()
}

/// 解码签名：帧数与样本和，用于跨线程比对一致性。
private class LrSignature {
    let frames: Int64
    let checksum: Float64

    init(frames: Int64, checksum: Float64) {
        this.frames = frames
        this.checksum = checksum
    }
}

/// 完整解码一个文件并求签名。
///
/// 累加顺序固定，因此同一文件的签名在串行与并发下应当**逐位相同**
/// （浮点加法同序即确定性）。
private func lrDecodeSignature(path: String): LrSignature {
    var frames: Int64 = 0
    var checksum: Float64 = 0.0

    try (f = AudioFile.open(path)) {
        // FrameStream 未实现 Resource，不能用 try-with-resources，手动关闭
        let s = f.stream()
        var done = false
        while (!done) {
            match (s.next()) {
                case Some(buf) =>
                    frames += buf.frameCount
                    for (v in buf.samples) {
                        checksum += Float64(v)
                    }
                case None => done = true
            }
        }
        s.close()
    }

    LrSignature(frames, checksum)
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class LongRunTest {
    /// 长 FLAC 完整解码：累计帧数与 STREAMINFO 声明的总帧数**精确一致**
    ///
    /// FLAC 是无损格式，样本总数在 STREAMINFO 中精确定义，不存在编码器
    /// 延迟/填充，因此这里断言精确相等。
    @TestCase
    func longFlacFrameConservation() {
        if (!exists(Path(LONG_FLAC))) {
            println("跳过（素材缺失）：${LONG_FLAC}")
            return
        }

        try (f = AudioFile.open(LONG_FLAC)) {
            let info = f.info()
            @Assert(info.totalFrames > 0)

            let s = f.stream()
            var frames: Int64 = 0
            var chunks: Int64 = 0
            var maxChunkFrames: Int64 = 0

            var done = false
            while (!done) {
                match (s.next()) {
                    case Some(buf) =>
                        frames += buf.frameCount
                        chunks += 1
                        if (buf.frameCount > maxChunkFrames) {
                            maxChunkFrames = buf.frameCount
                        }
                    case None => done = true
                }
            }
            s.close()

            @Assert(frames == info.totalFrames)
            @Assert(chunks > 1)
            // 结构性证据：分块大小恒定有界。若实现存在数据累积，
            // 越靠后的块会越大（而这里是固定上限）。
            @Assert(maxChunkFrames <= 65536)

            println("FLAC: ${frames} 帧 / ${chunks} 块 / 峰值块 ${maxChunkFrames} 帧")
        }
    }

    /// 反复开关同一文件（成功路径）：不得泄漏文件句柄
    ///
    /// 检测手段是每轮之后删除该文件 —— 句柄若未释放，删除会失败。
    @TestCase
    func repeatedOpenCloseDoesNotLeakHandles() {
        var round: Int64 = 0
        while (round < 20) {
            let path = lrWrite("a4cj_lr_leak_${round}.wav", lrBuildWav(5000))

            try (f = AudioFile.open(path)) {
                let s = f.stream()
                let _ = s.next()
                s.close()
            }

            // 若上一轮遗留了句柄，这里会抛 FSException 而暴露问题
            remove(path)
            round += 1
        }

        @Assert(round == 20)
    }

    /// 反复触发**构造失败**路径：即便 open 抛异常，句柄也必须已释放
    ///
    /// 这是对 M5 期间发现并修复的真实缺陷的回归：`FlacFormatReader.init`
    /// 先打开 dr_libs 句柄、后校验参数，校验失败时若不显式 close()，
    /// 该句柄（及其 FILE*）将无人释放。
    @TestCase
    func failedOpenDoesNotLeakHandles() {
        var round: Int64 = 0
        while (round < 20) {
            let path = lrWrite("a4cj_lr_leak_bad_${round}.flac", lrBuildZeroStreamInfoFlac())

            var threw = false
            try {
                let f = AudioFile.open(path)
                f.close()
            } catch (e: Audio4CjException) {
                threw = true
            }
            @Assert(threw)

            // 关键断言：open 失败也不许占着文件
            remove(path)
            round += 1
        }

        @Assert(round == 20)
    }

    /// 并发正确性：多线程解码同一文件，签名与串行基线逐位一致
    @TestCase
    func concurrentDecodingMatchesSerialBaseline() {
        let n: Int64 = 60000
        let path = lrWrite("a4cj_lr_conc.wav", lrBuildWav(n))

        let base = lrDecodeSignature(path)
        @Assert(base.frames == n)

        let threads: Int64 = 4
        let futures = ArrayList<Future<LrSignature>>()

        var i: Int64 = 0
        while (i < threads) {
            // 每个线程持有自己的路径副本并独立 open，互不共享实例
            let p = path
            futures.add(spawn {lrDecodeSignature(p)})
            i += 1
        }

        // 必须显式汇合：主线程退出会杀死未完成的子线程
        for (fut in futures) {
            let sig = fut.get()
            @Assert(sig.frames == base.frames)
            @Assert(sig.checksum == base.checksum)
        }

        remove(path)
        @Assert(i == threads)
    }

    /// 并发正确性：多线程各解各的文件，互不干扰
    @TestCase
    func concurrentDecodingOfDistinctFiles() {
        let count: Int64 = 4
        let paths = ArrayList<String>()
        let expected = ArrayList<Int64>()

        var i: Int64 = 0
        while (i < count) {
            let n = 10000 * (i + 1)
            let p = lrWrite("a4cj_lr_dist_${i}.wav", lrBuildWav(n))
            paths.add(p)
            expected.add(n)
            i += 1
        }

        let futures = ArrayList<Future<LrSignature>>()
        i = 0
        while (i < count) {
            let p = paths[i]
            futures.add(spawn {lrDecodeSignature(p)})
            i += 1
        }

        i = 0
        for (fut in futures) {
            let sig = fut.get()
            @Assert(sig.frames == expected[i])
            i += 1
        }

        for (p in paths) {
            remove(p)
        }
    }
}
