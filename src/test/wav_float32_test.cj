package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.FormatNotSupportedException
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * WAV 32 位浮点端到端测试（仓库侧，就地构造素材）
 *
 * 覆盖两条载体的完整链路 open → info → readAll / stream：
 *   formatTag = 3          —— 直接的 IEEE 浮点 WAV
 *   formatTag = 0xFFFE     —— WAVE_FORMAT_EXTENSIBLE，真实格式在 SubFormat GUID
 *                             （首 2 字节 = 3 表示浮点）—— DAW 导出的常见形态
 *
 * 素材由**位模式**构造（而非先算出浮点再序列化），这样"预期值"来自测试自己，
 * 不依赖被测代码的任何一环；同时越界值（>1.0）与负数的存在保证断言能区分
 * 归一化与按位重解释两条路径 —— 若浮点被误按整型口径归一化，数值会明显不同。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// WAV 构造辅助（小端）
// ---------------------------------------------------------------------------

private func wfAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func wfAppendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func wfAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

/// 按小端写入一个 32 位模式的低 `count` 个字节（浮点样本的字节表示）。
///
/// 用"逐字节取低位"而不是定长 4 字节，是为了让 64 位（拒绝路径用例）等位深的
/// 文件仍然结构自洽：data 长度与 fmt 声明的位深一致，用例失败只可能因为
/// "这个编码不被支持"，而不是因为文件本身写坏了。
private func wfAppendLowBytesLE(out: ArrayList<UInt8>, bits: UInt32, count: Int64): Unit {
    var v: UInt32 = bits
    var i: Int64 = 0
    while (i < count) {
        out.add(UInt8(v & 0xFF))
        v = v / 256
        i += 1
    }
}

/// 构造最小 WAV 文件字节流。
///
/// - `formatTag`：1 = 整型 PCM，3 = IEEE 浮点，0xFFFE = extensible（子格式取 `subFormat`）
/// - `bitsPerSample`：写入 fmt 的 wBitsPerSample；浮点载荷恒按 32 位写
private func wfBuildWav(
    sampleRate: Int64,
    channels: Int64,
    formatTag: Int64,
    bitsPerSample: Int64,
    codes: Array<UInt32>,
    extensible: Bool
): Array<UInt8> {
    let bytesPerSample = (bitsPerSample + 7) / 8
    let dataSize = Int64(codes.size) * bytesPerSample
    let fmtSize: Int64 = if (extensible) {
        40
    } else {
        16
    }
    let riffSize = 4 + 8 + fmtSize + 8 + dataSize

    let out = ArrayList<UInt8>()
    wfAppendAscii(out, "RIFF")
    wfAppendUInt32LE(out, riffSize)
    wfAppendAscii(out, "WAVE")

    wfAppendAscii(out, "fmt ")
    wfAppendUInt32LE(out, fmtSize)
    wfAppendUInt16LE(out, if (extensible) {
        0xFFFE
    } else {
        formatTag
    })
    wfAppendUInt16LE(out, channels)
    wfAppendUInt32LE(out, sampleRate)
    wfAppendUInt32LE(out, sampleRate * channels * bytesPerSample) // nAvgBytesPerSec
    wfAppendUInt16LE(out, channels * bytesPerSample) // nBlockAlign
    wfAppendUInt16LE(out, bitsPerSample)

    if (extensible) {
        // cbSize(2) + wValidBitsPerSample(2) + dwChannelMask(4) + SubFormat GUID(16)
        wfAppendUInt16LE(out, 22)
        wfAppendUInt16LE(out, bitsPerSample)
        wfAppendUInt32LE(out, if (channels == 1) {
            0x4
        } else {
            0x3
        })
        // GUID 前 2 字节即真实 wFormatTag，其余固定（KSDATAFORMAT_SUBTYPE_IEEE_FLOAT）
        wfAppendUInt16LE(out, formatTag)
        let rest: Array<Int64> = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71, 0x00, 0x00]
        for (b in rest) {
            out.add(UInt8(b))
        }
    }

    wfAppendAscii(out, "data")
    wfAppendUInt32LE(out, dataSize)
    for (c in codes) {
        wfAppendLowBytesLE(out, c, bytesPerSample)
    }

    out.toArray()
}

private func wfWrite(name: String, bytes: Array<UInt8>): String {
    let path = testTmpPath(name)
    File.writeTo(path, bytes)
    path
}

// 常用位模式
private let WF_ONE: UInt32 = 0x3F800000 // 1.0
private let WF_NEG_ONE: UInt32 = 0xBF800000 // -1.0
private let WF_HALF: UInt32 = 0x3F000000 // 0.5
private let WF_QUARTER: UInt32 = 0x3E800000 // 0.25
private let WF_ZERO: UInt32 = 0x00000000 // 0.0
private let WF_TWO_HALF: UInt32 = 0x40200000 // 2.5（越界）
private let WF_NEG_TWO_HALF: UInt32 = 0xC0200000 // -2.5（越界）

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
@Test
class WavFloat32EndToEndTest {
    /// formatTag = 3 单声道：整条链路 + 精确值 + 位深对外报告为 32
    @TestCase
    func float32MonoEndToEnd() {
        let codes: Array<UInt32> = [WF_ONE, WF_NEG_ONE, WF_HALF, WF_TWO_HALF, WF_NEG_TWO_HALF, WF_ZERO]
        let path = wfWrite("a4cj_f32_mono.wav", wfBuildWav(44100, 1, 3, 32, codes, false))

        try (f = AudioFile.open(path)) {
            let info = f.info()
            @Assert(info.sampleRate == 44100)
            @Assert(info.channels == 1)
            @Assert(info.bitDepth == 32)
            @Assert(info.totalFrames == 6)

            let buf = f.readAll()
            @Assert(buf.frameCount == 6)
            @Assert(buf.sampleCount == 6)
            @Assert(buf.samples[0] == 1.0)
            @Assert(buf.samples[1] == -1.0)
            @Assert(buf.samples[2] == 0.5)
            // 越界值原样保留 —— 若浮点被误按 32 位整型归一化，这里会得到荒谬的小数
            @Assert(buf.samples[3] == 2.5)
            @Assert(buf.samples[4] == -2.5)
            @Assert(buf.samples[5] == 0.0)
        }
        remove(path)
    }

    /// 立体声交错：声道顺序不得被打乱
    @TestCase
    func float32StereoKeepsInterleaving() {
        let codes: Array<UInt32> = [WF_ONE, WF_HALF, WF_NEG_ONE, WF_QUARTER, WF_ZERO, WF_NEG_ONE]
        let path = wfWrite("a4cj_f32_stereo.wav", wfBuildWav(48000, 2, 3, 32, codes, false))

        try (f = AudioFile.open(path)) {
            @Assert(f.info().channels == 2)
            let buf = f.readAll()
            @Assert(buf.frameCount == 3)
            @Assert(buf.sampleCount == 6)
            @Assert(buf.samples[0] == 1.0)
            @Assert(buf.samples[1] == 0.5)
            @Assert(buf.samples[2] == -1.0)
            @Assert(buf.samples[3] == 0.25)
            @Assert(buf.samples[4] == 0.0)
            @Assert(buf.samples[5] == -1.0)
        }
        remove(path)
    }

    /// WAVE_FORMAT_EXTENSIBLE + SubFormat = IEEE float：DAW 导出的常见形态
    @TestCase
    func extensibleFloat32IsAccepted() {
        let codes: Array<UInt32> = [WF_ONE, WF_NEG_ONE, WF_TWO_HALF]
        let path = wfWrite("a4cj_f32_extensible.wav", wfBuildWav(44100, 1, 3, 32, codes, true))

        try (f = AudioFile.open(path)) {
            @Assert(f.format().container == "wav")
            let buf = f.readAll()
            @Assert(buf.frameCount == 3)
            // 关键：extensible 里的子格式被正确识别为浮点，而不是当整型解释
            @Assert(buf.samples[0] == 1.0)
            @Assert(buf.samples[1] == -1.0)
            @Assert(buf.samples[2] == 2.5)
        }
        remove(path)
    }

    /// 流式路径与 readAll 必须给出相同结果（浮点不因分包被改变）
    @TestCase
    func float32StreamingMatchesReadAll() {
        // 32 位浮点每帧 4 字节、单包上限 64 KiB ≈ 16384 帧 → 40000 帧必然分包
        let n: Int64 = 40000
        let codes = Array<UInt32>(n, repeat: 0)
        for (i in 0..n) {
            codes[i] = if (i % 3 == 0) {
                WF_ONE
            } else if (i % 3 == 1) {
                WF_NEG_ONE
            } else {
                WF_HALF
            }
        }
        let path = wfWrite("a4cj_f32_stream.wav", wfBuildWav(44100, 1, 3, 32, codes, false))

        var frames: Int64 = 0
        var chunks: Int64 = 0
        var streamSum: Float32 = 0.0
        try (f = AudioFile.open(path)) {
            let s = f.stream()
            while (let Some(chunk) <- s.next()) {
                frames += chunk.frameCount
                chunks += 1
                for (v in chunk.samples) {
                    streamSum += v
                }
            }
        }
        @Assert(frames == n)
        @Assert(chunks > 1) // 确认确实发生了分包

        var allSum: Float32 = 0.0
        try (f2 = AudioFile.open(path)) {
            let all = f2.readAll()
            @Assert(all.frameCount == n)
            for (v in all.samples) {
                allSum += v
            }
        }
        @Assert(streamSum == allSum)
        remove(path)
    }

    /// 64 位浮点明确拒绝：本库统一表示为 f32，收进来只能降精度
    @TestCase
    func float64IsRejected() {
        let codes: Array<UInt32> = [WF_ONE, WF_ZERO]
        let path = wfWrite("a4cj_f64_reject.wav", wfBuildWav(44100, 1, 3, 64, codes, false))

        var caught = false
        try {
            AudioFile.open(path)
        } catch (e: FormatNotSupportedException) {
            caught = true
            @Assert(e.message.contains("32 位 IEEE 浮点"))
        }
        @Assert(caught)
        remove(path)
    }

    /// 非 PCM 编码（如 2 = MS ADPCM）仍拒绝，且报错文案要能指导使用者
    @TestCase
    func nonPcmTagIsRejected() {
        let codes: Array<UInt32> = [WF_ZERO, WF_ZERO]
        let path = wfWrite("a4cj_adpcm_reject.wav", wfBuildWav(44100, 1, 2, 4, codes, false))

        var caught = false
        try {
            AudioFile.open(path)
        } catch (e: FormatNotSupportedException) {
            caught = true
            @Assert(e.message.contains("暂不支持的 WAV 编码"))
        }
        @Assert(caught)
        remove(path)
    }
}
