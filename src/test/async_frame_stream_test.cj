package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.stream.AsyncFrameStream
import audio4cj.core.Audio4CjException
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * AsyncFrameStream 测试 —— 开发文档 §10 M5（有界队列背压）
 *
 * 自包含：在内存中构造 WAV 字节流写入临时文件，不依赖外部素材。
 *
 * 覆盖重点：
 *   1. 异步流的输出与同步流**逐块一致**（否则背压实现引入了数据错误）；
 *   2. 队列容量为 1（最严格的背压）时不丢帧；
 *   3. 取消/关闭**不会死锁** —— 这是本实现最需要保障的一点：
 *      生产者在队列满时阻塞，若消费者不再取数据，必须能借助超时 + 标志
 *      自行退出，否则 close() 会永久挂起；
 *   4. close 幂等、关闭后 next() 抛异常（与 FrameStream 语义一致）。
 *
 * 注意：单次读取上限为 64 KiB（见 format/wav.cj 的 nextPacket），
 * 因此 16-bit 单声道下约 32768 帧/块；用例统一构造 10 万帧以产生多块。
 * ========================================================================== */
private func asyncAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func asyncAppendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func asyncAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

/// 构造 16-bit 单声道 WAV（样本值为可预测的锯齿波，便于比对首尾）。
private func asyncBuildWav(frameCount: Int64): Array<UInt8> {
    let bytesPerSample: Int64 = 2
    let dataSize = frameCount * bytesPerSample
    let riffSize = 4 + 8 + 16 + 8 + dataSize

    let out = ArrayList<UInt8>()
    asyncAppendAscii(out, "RIFF")
    asyncAppendUInt32LE(out, riffSize)
    asyncAppendAscii(out, "WAVE")

    asyncAppendAscii(out, "fmt ")
    asyncAppendUInt32LE(out, 16)
    asyncAppendUInt16LE(out, 1) // PCM
    asyncAppendUInt16LE(out, 1) // 单声道
    asyncAppendUInt32LE(out, 44100)
    asyncAppendUInt32LE(out, 88200)
    asyncAppendUInt16LE(out, 2) // nBlockAlign
    asyncAppendUInt16LE(out, 16) // 位深

    asyncAppendAscii(out, "data")
    asyncAppendUInt32LE(out, dataSize)

    for (i in 0..frameCount) {
        let sample = Int32(i % 2000) - 1000
        out.add(UInt8(sample & 0xFF))
        out.add(UInt8((sample >> 8) & 0xFF))
    }

    out.toArray()
}

private func asyncWrite(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class AsyncFrameStreamTest {
    /// 异步流与同步流输出一致：块数、帧数、首尾样本三项都要相同
    @TestCase
    func asyncStreamMatchesSyncStream() {
        let n: Int64 = 100000
        let path = asyncWrite("a4cj_async_cmp.wav", asyncBuildWav(n))

        // ---- 同步基线 ----
        var syncFrames: Int64 = 0
        var syncChunks: Int64 = 0
        var syncFirst: Float32 = 0.0
        var syncLast: Float32 = 0.0

        try (f = AudioFile.open(path)) {
            let s = f.stream()
            while (let Some(buf) <- s.next()) {
                if (syncChunks == 0 && buf.sampleCount > 0) {
                    syncFirst = buf.samples[0]
                }
                if (buf.sampleCount > 0) {
                    syncLast = buf.samples[buf.sampleCount - 1]
                }
                syncFrames += buf.frameCount
                syncChunks += 1
            }
        }

        // ---- 异步（队列容量 2，刻意制造背压）----
        var asyncFrames: Int64 = 0
        var asyncChunks: Int64 = 0
        var asyncFirst: Float32 = 0.0
        var asyncLast: Float32 = 0.0

        try (f2 = AudioFile.open(path)) {
            try (s2 = AsyncFrameStream.start(f2.stream(), queueCapacity: 2)) {
                while (let Some(buf) <- s2.next()) {
                    if (asyncChunks == 0 && buf.sampleCount > 0) {
                        asyncFirst = buf.samples[0]
                    }
                    if (buf.sampleCount > 0) {
                        asyncLast = buf.samples[buf.sampleCount - 1]
                    }
                    asyncFrames += buf.frameCount
                    asyncChunks += 1
                }
            }
        }

        @Assert(syncFrames == n)
        @Assert(asyncFrames == n)
        @Assert(syncChunks == asyncChunks)
        @Assert(syncFirst == asyncFirst)
        @Assert(syncLast == asyncLast)

        remove(path)
    }

    /// 队列容量为 1（最严格背压）时仍然不丢帧
    @TestCase
    func capacityOneDoesNotLoseFrames() {
        let n: Int64 = 100000
        let path = asyncWrite("a4cj_async_small.wav", asyncBuildWav(n))

        try (f = AudioFile.open(path)) {
            try (s = AsyncFrameStream.start(f.stream(), queueCapacity: 1)) {
                var frames: Int64 = 0
                var chunks: Int64 = 0
                while (let Some(buf) <- s.next()) {
                    frames += buf.frameCount
                    chunks += 1
                }
                @Assert(frames == n)
                @Assert(chunks > 1) // 确认确实分包了
            }
        }

        remove(path)
    }

    /// 容量非法时立即抛异常（不做静默降级）
    @TestCase
    func invalidCapacityThrows() {
        let path = asyncWrite("a4cj_async_bad.wav", asyncBuildWav(1000))

        try (f = AudioFile.open(path)) {
            @AssertThrows[Audio4CjException](
                AsyncFrameStream.start(f.stream(), queueCapacity: 0)
            )
        }

        remove(path)
    }

    /// 只消费一块就关闭：生产者应能自行解除阻塞并退出，不产生死锁
    @TestCase
    func cancelEndsStreamWithoutDeadlock() {
        let n: Int64 = 200000
        let path = asyncWrite("a4cj_async_cancel.wav", asyncBuildWav(n))

        try (f = AudioFile.open(path)) {
            let s = AsyncFrameStream.start(f.stream(), queueCapacity: 2)

            let first = s.next()
            @Assert(first.isSome())

            // 此刻队列大概率是满的、生产者阻塞在入队处；
            // close() 必须能在一两个超时周期内完成，否则说明实现有死锁缺陷。
            s.close()
            @Assert(s.isClosed())
        }

        remove(path)
    }

    /// close 幂等；关闭后 next() 抛异常（与 FrameStream 的既有语义一致）
    @TestCase
    func closeIsIdempotentAndNextAfterCloseThrows() {
        let path = asyncWrite("a4cj_async_close.wav", asyncBuildWav(10000))

        try (f = AudioFile.open(path)) {
            let s = AsyncFrameStream.start(f.stream())

            s.close()
            s.close() // 第二次应无副作用
            @Assert(s.isClosed())

            @AssertThrows[Audio4CjException](s.next())
        }

        remove(path)
    }

    /// 完整消费后 isEnded 为真，且帧数与文件声明一致
    @TestCase
    func isEndedAfterFullConsumption() {
        let n: Int64 = 100000
        let path = asyncWrite("a4cj_async_end.wav", asyncBuildWav(n))

        try (f = AudioFile.open(path)) {
            try (s = AsyncFrameStream.start(f.stream())) {
                var frames: Int64 = 0
                while (let Some(buf) <- s.next()) {
                    frames += buf.frameCount
                }
                @Assert(frames == n)
                @Assert(s.isEnded())
            }
        }

        remove(path)
    }
}
