package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import audio4cj.probe.detectBytes
import audio4cj.meta.parseId3v1
import audio4cj.meta.parseId3v2
import audio4cj.meta.id3v2TotalSize
import audio4cj.meta.parseVorbisComment
import audio4cj.meta.parseWavInfo
import audio4cj.meta.parseFlacMetadata
import std.random.*
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * fuzz 测试 —— 开发文档 §10 M5「fuzz 测试 + 畸形输入回归」
 *
 * 目标：解析与解码路径面对**不可信输入**时，必须「要么正常返回、要么抛
 *       Audio4CjException 体系内的异常」，**绝不崩溃、越界或长时间挂起**。
 *
 * 【为什么这批测试有价值】
 *   音频文件来自用户上传、网络下载，本身就是典型的不可信输入。解析器里
 *   大量出现"从数据中读出长度字段"的逻辑，这类字段一旦被精心构造，就是
 *   缓冲区溢出与整数溢出的经典入口。
 *
 * 【可复现性】
 *   全部使用**固定种子** Random(FUZZ_SEED)：相同种子产生相同序列，
 *   因此一旦失败可以稳定复现，而不是"偶发"。
 *
 * 【覆盖目标】（这些函数均为 protected；test 包与它们同属一个 cjpm 模块）
 *   - probe.detectBytes        容器探测
 *   - meta.parseId3v1 / id3v2TotalSize / parseId3v2
 *   - meta.parseVorbisComment
 *   - meta.parseWavInfo
 *   - meta.parseFlacMetadata
 *   - AudioFile.open           完整打开链路（含 FFI 解码器构造）
 *
 * 【断言口径】
 *   本文件验证的是「不崩溃 + 异常类型在预期集合内」，**不验证解析结果正确**——
 *   后者由各解析器的自包含单测负责。因此断言多为轻量的自洽性检查。
 * ========================================================================== */

/// 固定种子：保证可复现。
private let FUZZ_SEED: UInt64 = 20261002

/// 每轮的随机样本长度（覆盖"过短以致走不进解析分支"到"足够长"）。
private let FUZZ_LENGTHS: Array<Int64> = [0, 1, 2, 3, 4, 7, 8, 10, 13, 16, 33, 64, 128, 1024, 8192]

/// 生成指定长度的随机字节。
private func fuzzBytes(rng: Random, len: Int64): Array<UInt8> {
    if (len <= 0) {
        return Array<UInt8>()
    }
    rng.nextBytes(Int32(len))
}

/// 深拷贝（仓颉 Array 赋值是共享底层存储，变异前必须复制）。
private func fuzzCopy(sample: Array<UInt8>): Array<UInt8> {
    let out = Array<UInt8>(sample.size, repeat: 0)
    for (i in 0..sample.size) {
        out[i] = sample[i]
    }
    out
}

/// 随机构造「合法头部标识 + 随机体」的样本，以便进入解析器的深层分支。
private func fuzzSeeded(rng: Random, magic: String, bodyLen: Int64): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in magic.toArray()) {
        out.add(b)
    }
    for (b in fuzzBytes(rng, bodyLen)) {
        out.add(b)
    }
    out.toArray()
}

/// 对样本做若干次单位翻转（模拟损坏）。
private func fuzzMutate(rng: Random, sample: Array<UInt8>, flips: Int64): Array<UInt8> {
    if (sample.size == 0) {
        return sample
    }
    let out = fuzzCopy(sample)
    var i: Int64 = 0
    while (i < flips) {
        let pos = rng.nextInt64(out.size)
        out[pos] = rng.nextUInt8()
        i += 1
    }
    out
}

/// 写临时文件。
private func fuzzWrite(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 尝试打开畸形文件。
///
/// 只接受两类异常：库内异常与文件系统异常。其它异常（类型转换失败、
/// 数组越界、空指针解引用等）会向上传播并使用例报 ERROR —— 那正是缺陷。
private func fuzzTryOpen(path: String): Bool {
    var handled = false
    try {
        let f = AudioFile.open(path)
        f.close() // 意外打开成功也要正常关闭，避免句柄泄漏
        handled = true
    } catch (e: Audio4CjException) {
        handled = true
    } catch (e: FSException) {
        handled = true
    }
    handled
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class FuzzTest {
    /// 全部标签解析器对纯随机字节都不崩溃
    @TestCase
    func tagParsersSurviveRandomBytes() {
        let rng = Random(FUZZ_SEED)
        var rounds: Int64 = 0

        for (len in FUZZ_LENGTHS) {
            var repeat: Int64 = 0
            while (repeat < 8) {
                let bytes = fuzzBytes(rng, len)

                // 五个解析器逐个打一遍；任何一个崩溃或抛非预期异常都会失败
                let t1 = parseId3v1(bytes)
                let t2 = parseId3v2(bytes)
                let t3 = parseVorbisComment(bytes)
                let t4 = parseWavInfo(bytes)
                let t5 = parseFlacMetadata(bytes)
                let _ = id3v2TotalSize(bytes)

                // 轻量自洽性：解析产物不应出现异常大的字段（说明产生了失控拼接）
                if (let Some(v) <- t1.title) {
                    @Assert(v.size <= 4096)
                }
                if (let Some(v) <- t2.title) {
                    @Assert(v.size <= 65536)
                }
                if (let Some(v) <- t3.title) {
                    @Assert(v.size <= 65536)
                }
                if (let Some(v) <- t4.title) {
                    @Assert(v.size <= 65536)
                }
                if (let Some(v) <- t5.title) {
                    @Assert(v.size <= 65536)
                }

                rounds += 1
                repeat += 1
            }
        }

        @Assert(rounds == FUZZ_LENGTHS.size * 8)
    }

    /// 标签解析器对「带合法头部标识的随机体」不崩溃（能进入更深的分支）
    @TestCase
    func tagParsersSurviveSeededSamples() {
        let rng = Random(FUZZ_SEED + 1)
        var repeat: Int64 = 0

        while (repeat < 60) {
            let bodyLen = rng.nextInt64(2048)

            let id3 = fuzzSeeded(rng, "ID3", bodyLen)
            let flac = fuzzSeeded(rng, "fLaC", bodyLen)
            let info = fuzzSeeded(rng, "INFO", bodyLen)

            let _ = parseId3v2(id3)
            let _ = id3v2TotalSize(id3)
            let _ = parseFlacMetadata(flac)
            let _ = parseWavInfo(info)

            repeat += 1
        }

        @Assert(repeat == 60)
    }

    /// 对有效前缀做位翻转与截断：解析器仍需安全
    @TestCase
    func tagParsersSurviveMutations() {
        let rng = Random(FUZZ_SEED + 2)

        // 一个结构完整的 ID3v2.3 标签作为变异基底（TIT2 = "abc"）。
        //
        // 构造方式刻意采用「分件装配」而不是「先写占位、再回填下标」：
        // 后者极易算错偏移 —— 本用例曾因此把帧长度写进了标签长度的位置，
        // 结果帧长度为 0、样本根本不合法，变异测试也就失去了意义。
        //
        // 两个长度字段的含义不同，必须分清：
        //   帧长度字段 = **帧数据长度**，不含 10 字节帧头；
        //   标签长度字段 = 全部帧的长度之和（synchsafe），不含 10 字节标签头。
        let frameData = ArrayList<UInt8>()
        frameData.add(0u8) // 编码 = Latin-1
        for (b in "abc".toArray()) {
            frameData.add(b)
        }
        let frameDataLen = frameData.size

        let body = ArrayList<UInt8>()
        for (b in "TIT2".toArray()) {
            body.add(b)
        }
        body.add(UInt8((frameDataLen >> 24) & 0xFF))
        body.add(UInt8((frameDataLen >> 16) & 0xFF))
        body.add(UInt8((frameDataLen >> 8) & 0xFF))
        body.add(UInt8(frameDataLen & 0xFF))
        body.add(0u8) // 帧标志
        body.add(0u8)
        for (b in frameData) {
            body.add(b)
        }
        let bodyTotal = body.size

        let header = ArrayList<UInt8>()
        for (b in "ID3".toArray()) {
            header.add(b)
        }
        header.add(3u8) // 主版本
        header.add(0u8) // 次版本
        header.add(0u8) // 标志
        header.add(UInt8((bodyTotal >> 21) & 0x7F))
        header.add(UInt8((bodyTotal >> 14) & 0x7F))
        header.add(UInt8((bodyTotal >> 7) & 0x7F))
        header.add(UInt8(bodyTotal & 0x7F))

        let assembled = ArrayList<UInt8>()
        for (b in header) {
            assembled.add(b)
        }
        for (b in body) {
            assembled.add(b)
        }

        let valid = assembled.toArray()

        // 基线：未变异的样本应当解析出标题
        let t0 = parseId3v2(valid)
        @Assert(t0.title.getOrThrow() == "abc")

        // 变异：位翻转
        var i: Int64 = 0
        while (i < 200) {
            let mutated = fuzzMutate(rng, valid, 1 + rng.nextInt64(4))
            let _ = parseId3v2(mutated)
            i += 1
        }

        // 截断：每个前缀长度都要安全
        var cut: Int64 = 0
        while (cut <= valid.size) {
            let _ = parseId3v2(valid[0..cut])
            let _ = id3v2TotalSize(valid[0..cut])
            cut += 1
        }

        @Assert(i == 200)
    }

    /// 扩展名/长度字段被置为极端值时仍安全
    @TestCase
    func extremeLengthFieldsAreSafe() {
        // ID3v2 的 synchsafe 长度取最大值（268435455），远超实际数据
        let huge: Array<UInt8> = [
            0x49u8,
            0x44u8,
            0x33u8, // "ID3"
            0x04u8,
            0x00u8,
            0x00u8,
            0x7Fu8,
            0x7Fu8,
            0x7Fu8,
            0x7Fu8 // 最大 synchsafe 长度
        ]
        let _ = parseId3v2(huge)
        @Assert(id3v2TotalSize(huge).isSome())

        // FLAC：块长度字段全 0xFF（1600 万字节），数据远不足
        let flac = ArrayList<UInt8>()
        for (b in "fLaC".toArray()) {
            flac.add(b)
        }
        flac.add(0x80u8) // 最后一块，类型 0
        flac.add(0xFFu8)
        flac.add(0xFFu8)
        flac.add(0xFFu8)
        for (x in fuzzBytes(Random(7), 16)) {
            flac.add(x)
        }
        let _ = parseFlacMetadata(flac.toArray())

        // RIFF INFO：子块长度字段为 0xFFFFFFFF
        let info = ArrayList<UInt8>()
        for (b in "INFOINAM".toArray()) {
            info.add(b)
        }
        info.add(0xFFu8)
        info.add(0xFFu8)
        info.add(0xFFu8)
        info.add(0xFFu8)
        for (x in fuzzBytes(Random(8), 8)) {
            info.add(x)
        }
        let _ = parseWavInfo(info.toArray())

        // Vorbis comment：条目长度字段为 0xFFFFFFFF
        let vc: Array<UInt8> = [
            0x00u8,
            0x00u8,
            0x00u8,
            0x00u8, // vendor 长度 0
            0x01u8,
            0x00u8,
            0x00u8,
            0x00u8, // 条目数 1
            0xFFu8,
            0xFFu8,
            0xFFu8,
            0xFFu8 // 条目长度极大
        ]
        let _ = parseVorbisComment(vc)

        // 只要能执行到此处即说明上述极端输入均未导致崩溃
        @Assert(true)
    }

    /// 容器探测对随机字节不崩溃
    @TestCase
    func detectSurvivesRandomBytes() {
        let rng = Random(FUZZ_SEED + 3)
        var i: Int64 = 0

        while (i < 200) {
            let bytes = fuzzBytes(rng, 16)
            let r = detectBytes(bytes)
            // 探测结果必属于有限的容器集合
            @Assert(r.container.size > 0)
            @Assert(r.mimeType.size > 0)
            i += 1
        }

        @Assert(i == 200)
    }

    /// AudioFile.open 对畸形文件只抛库内异常或文件系统异常，绝不崩溃
    @TestCase
    func openSurvivesMalformedFiles() {
        let rng = Random(FUZZ_SEED + 4)
        var caseNo: Int64 = 0

        // 各类"看起来像某个容器"的畸形文件。结局有两种，用例都接受：
        //   · 容器可解码（RIFF / fLaC / OggS / ID3）—— 探测器放行，
        //     由各自的纯仓颉解析层/解码层拒绝或优雅收场；
        //   · 识别不出的—— 在门面就被拦下。
        // 换言之这里验的是"任何畸形输入都不得崩溃"，而非"必须走到解析层"。
        let magics: Array<String> = ["RIFF", "fLaC", "ID3", "OggS"]

        for (magic in magics) {
            var len: Int64 = 0
            while (len <= 2048) {
                let bytes = fuzzSeeded(rng, magic, len)
                let path = fuzzWrite("a4cj_fuzz_${caseNo}.bin", bytes)

                @Assert(fuzzTryOpen(path))

                remove(path)
                caseNo += 1
                // 长度按阶梯增长，避免用例过多
                if (len == 0) {
                    len = 8
                } else {
                    len = len * 4
                }
            }
        }

        // 纯随机字节
        var i: Int64 = 0
        while (i < 40) {
            let bytes = fuzzBytes(rng, rng.nextInt64(4096))
            let path = fuzzWrite("a4cj_fuzz_rand_${i}.bin", bytes)
            @Assert(fuzzTryOpen(path))
            remove(path)
            i += 1
        }

        @Assert(caseNo > 0)
    }

    /// 合法 WAV 被逐字节截断：任何前缀都不能让 open 崩溃
    @TestCase
    func openSurvivesTruncatedWav() {
        // 构造一个最小但完整的 WAV（16-bit 单声道 4 帧）
        let wav = ArrayList<UInt8>()
        for (b in "RIFF".toArray()) {
            wav.add(b)
        }
        // RIFF 长度
        wav.add(36u8)
        wav.add(0u8)
        wav.add(0u8)
        wav.add(0u8)
        for (b in "WAVEfmt ".toArray()) {
            wav.add(b)
        }
        wav.add(16u8)
        wav.add(0u8)
        wav.add(0u8)
        wav.add(0u8)
        wav.add(1u8)
        wav.add(0u8) // PCM
        wav.add(1u8)
        wav.add(0u8) // 单声道
        wav.add(0x44u8)
        wav.add(0xACu8)
        wav.add(0u8)
        wav.add(0u8) // 44100
        wav.add(0x88u8)
        wav.add(0x58u8)
        wav.add(0x01u8)
        wav.add(0u8)
        wav.add(2u8)
        wav.add(0u8) // block align
        wav.add(16u8)
        wav.add(0u8) // 16 bit
        for (b in "data".toArray()) {
            wav.add(b)
        }
        wav.add(8u8)
        wav.add(0u8)
        wav.add(0u8)
        wav.add(0u8)
        for (i in 0..8) {
            wav.add(UInt8(i * 16))
        }

        let full = wav.toArray()
        var cut: Int64 = 0
        while (cut <= full.size) {
            let path = fuzzWrite("a4cj_fuzz_cut.wav", full[0..cut])
            @Assert(fuzzTryOpen(path))
            remove(path)
            cut += 1
        }

        @Assert(cut == full.size + 1)
    }
}
