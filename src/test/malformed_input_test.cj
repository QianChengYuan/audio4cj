package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * 畸形输入回归 —— 开发文档 §10 M5「fuzz 测试 + 畸形输入回归」
 *
 * 【这一组用例压的是什么】
 *   面向**不可信输入**的健壮性：把「声明长度远超实际数据」「块链永不结束」
 *   「容器参数取极端值」这类畸形字段喂进探测层、标签解析器与打开链路，
 *   断言口径是「**不崩溃 + 异常落在预期集合内**」。
 *
 *   它们针对的是**我们自己的解析器**（纯仓颉）：WAV、FLAC（含帧头 CRC-8、
 *   帧尾 CRC-16）、Ogg 封装的 FLAC（页重组 + 页 CRC-32），以及 ID3 标签解析。
 *   本库不依赖任何第三方解码实现，因此这些用例是「敢不敢说自己健壮」的直接依据。
 *
 * 【为什么反复测这几类字段】
 *   它们是解析器最容易写错、也最容易被恶意构造的地方：长度字段参与内存分配与
 *   读取窗口计算、块链决定循环能否终止、容器参数决定后续按位/按字节的解释方式。
 *   一旦某个改动让这类输入重新变成崩溃或挂起，本文件会立刻变红。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

private func mfAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func mfAppendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func mfAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

private func mfWrite(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 打开并**有限地**消费数据。
///
/// 只接受两种结局：正常完成，或抛出库内异常 / 文件系统异常。
/// 其它异常（数组越界、空指针、类型转换失败等）会向上传播并使用例失败 ——
/// 那正是我们想要暴露的缺陷。返回 true 仅表示「结局在预期集合内」。
private func mfOpenAndDrain(path: String): Bool {
    var graceful = true

    try (f = AudioFile.open(path)) {
        // 注意：FrameStream 未实现 Resource，不能用 try-with-resources，
        // 只能手动关闭（关闭它会连带关闭底层 reader，与 AudioFile 共享）。
        let s = f.stream()

        // 只读有限块：畸形文件的长度字段可能谎报出天文数字的帧数，
        // 不加限制会让用例跑很久（这里关心的是不崩溃，而非读完）
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
    } catch (e: Audio4CjException) {
        graceful = true
    } catch (e: FSException) {
        graceful = true
    }

    graceful
}

/// 仅读标签（不要求可解码）：同样只接受正常返回或预期异常。
private func mfReadTagsOnly(path: String): Bool {
    var graceful = true

    try {
        let tag = AudioFile.readTags(path)
        let _ = tag.hasNoStandardFields()
    } catch (e: Audio4CjException) {
        graceful = true
    } catch (e: FSException) {
        graceful = true
    }

    graceful
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class MalformedInputTest {
    /// FLAC：元数据块声明长度 0xFFFFFF（约 16 MB），实际仅 8 字节
    ///
    /// 压的是「声明长度参与范围与偏移计算」这一类畸形输入：长度字段必须被
    /// 当作不可信值 —— 任何按它分配内存或计算读取窗口的做法都会在这里暴露。
    @TestCase
    func flacBlockLengthFarExceedsFile() {
        let out = ArrayList<UInt8>()
        mfAppendAscii(out, "fLaC")
        out.add(0x80u8) // isLast = 1、类型 0（STREAMINFO）
        out.add(0xFFu8) // 声明长度 0xFFFFFF
        out.add(0xFFu8)
        out.add(0xFFu8)
        for (i in 0..8) { // 实际只给 8 字节
            out.add(0u8)
        }

        let path = mfWrite("a4cj_mf_flac_huge.flac", out.toArray())
        @Assert(mfOpenAndDrain(path))
        @Assert(mfReadTagsOnly(path))
        remove(path)
    }

    /// FLAC：块链永不置结束位（声称后面还有块，实则已到文件末尾）
    ///
    /// 覆盖"无终止的块链"这一攻击面：解析器必须在文件末尾安全停下，
    /// 不能因为循环条件依赖那个永远不来的结束位而挂起。
    @TestCase
    func flacUnterminatedBlockChain() {
        let out = ArrayList<UInt8>()
        mfAppendAscii(out, "fLaC")

        // 首个块：非最后一块、类型 0、长度 34（合法的 STREAMINFO 长度）
        out.add(0x00u8)
        out.add(0u8)
        out.add(0u8)
        out.add(34u8)
        for (i in 0..34) {
            out.add(0u8) // 全零 STREAMINFO：参数取极端值
        }

        // 之后追加 3000 个"非最后一块、长度 0"的 PADDING 块头，且不提供块体
        var i: Int64 = 0
        while (i < 3000) {
            out.add(0x01u8) // isLast = 0、类型 1（PADDING）
            out.add(0u8)
            out.add(0u8)
            out.add(0u8) // 长度 0
            i += 1
        }

        let path = mfWrite("a4cj_mf_flac_chain.flac", out.toArray())
        @Assert(mfOpenAndDrain(path))
        @Assert(mfReadTagsOnly(path))
        remove(path)
    }

    /// FLAC：STREAMINFO 全零（采样率 0、块大小 0、位深 1）
    ///
    /// 用于验证**我们自己的参数校验**是否生效：`FlacFormatReader` 在构造
    /// 时会检查采样率/声道/位深是否为正，异常情况必须抛 CorruptedFileException
    /// 而不是带着 0 采样率继续做除法。
    @TestCase
    func flacAbsurdStreamInfoIsHandled() {
        let out = ArrayList<UInt8>()
        mfAppendAscii(out, "fLaC")
        out.add(0x80u8)
        out.add(0u8)
        out.add(0u8)
        out.add(34u8)
        for (i in 0..34) {
            out.add(0u8)
        }
        for (i in 0..256) { // 补伪帧数据，诱使解码器继续读
            out.add(0xAAu8)
        }

        let path = mfWrite("a4cj_mf_flac_zero.flac", out.toArray())
        @Assert(mfOpenAndDrain(path))
        @Assert(mfReadTagsOnly(path))
        remove(path)
    }

    /// WAV：RIFF 长度与 data 长度都被谎报为极大值
    ///
    /// 这些样本针对的是**我们自己的 WAV 解析器**，覆盖「长度字段远超实际数据」
    /// 这一类畸形输入；断言口径是不崩溃、不挂起、异常落在预期集合内。
    @TestCase
    func wavOversizedLengthFields() {
        let out = ArrayList<UInt8>()
        mfAppendAscii(out, "RIFF")
        mfAppendUInt32LE(out, 0xFFFFFFFF) // RIFF 长度谎报
        mfAppendAscii(out, "WAVE")

        mfAppendAscii(out, "fmt ")
        mfAppendUInt32LE(out, 16)
        mfAppendUInt16LE(out, 1) // PCM
        mfAppendUInt16LE(out, 1) // 单声道
        mfAppendUInt32LE(out, 44100)
        mfAppendUInt32LE(out, 88200)
        mfAppendUInt16LE(out, 2)
        mfAppendUInt16LE(out, 16)

        mfAppendAscii(out, "data")
        mfAppendUInt32LE(out, 0xFFFFFFF0) // data 长度谎报（约 4 GB）
        for (i in 0..32) { // 实际只有 32 字节
            out.add(0u8)
        }

        let path = mfWrite("a4cj_mf_wav_huge.wav", out.toArray())
        @Assert(mfOpenAndDrain(path))
        remove(path)
    }

    /// WAV：fmt 字段取极端非法值（声道数 0、位深 0、block align 0）
    @TestCase
    func wavAbsurdFormatFields() {
        let out = ArrayList<UInt8>()
        mfAppendAscii(out, "RIFF")
        mfAppendUInt32LE(out, 36)
        mfAppendAscii(out, "WAVE")

        mfAppendAscii(out, "fmt ")
        mfAppendUInt32LE(out, 16)
        mfAppendUInt16LE(out, 1) // PCM
        mfAppendUInt16LE(out, 0) // 声道数 0（非法）
        mfAppendUInt32LE(out, 44100)
        mfAppendUInt32LE(out, 0) // 平均字节率 0
        mfAppendUInt16LE(out, 0) // block align 0
        mfAppendUInt16LE(out, 0) // 位深 0（非法）

        mfAppendAscii(out, "data")
        mfAppendUInt32LE(out, 4)
        for (i in 0..4) {
            out.add(0u8)
        }

        let path = mfWrite("a4cj_mf_wav_fmt.wav", out.toArray())
        @Assert(mfOpenAndDrain(path))
        remove(path)
    }

    /// MP3：ID3v2 头声明 synchsafe 最大长度（约 256 MB），实际不足 140 字节
    ///
    /// 【重点变了】解码路径已不在范围内，`AudioFile.open` 在探测层就被拦下、
    /// 够不到任何解码器 —— 原先那句 `mfOpenAndDrain` 断言现在**恒真**，
    /// 留着只会让人以为这里还在验 C 路径。真正仍有价值的是 **ID3 解析器**：
    /// 它仍是纯仓颉、仍在本版本能力内，`mfReadTagsOnly` 正是压它的那条。
    @TestCase
    func mp3OversizedId3Tag() {
        let out = ArrayList<UInt8>()
        mfAppendAscii(out, "ID3")
        out.add(3u8)
        out.add(0u8)
        out.add(0u8)
        out.add(0x7Fu8) // synchsafe 四字节全 0x7F
        out.add(0x7Fu8)
        out.add(0x7Fu8)
        out.add(0x7Fu8)
        for (i in 0..128) {
            out.add(0x55u8)
        }

        let path = mfWrite("a4cj_mf_mp3_id3.mp3", out.toArray())
        @Assert(mfReadTagsOnly(path))
        remove(path)
    }

    /// MP3：以合法帧同步字开头，其后全是垃圾（无任何有效 MPEG 帧）
    ///
    /// 同上：解码路径已不在范围内，本条压的是"**ID3 解析器**面对垃圾字节
    /// 仍能优雅收场"（探测器会把 0xFF 0xFB 认成 mp3，故标签路径确实会被走到）。
    @TestCase
    func mp3GarbageAfterSyncWord() {
        let out = ArrayList<UInt8>()
        out.add(0xFFu8)
        out.add(0xFBu8) // MPEG 帧同步字
        out.add(0x90u8)
        out.add(0x00u8)
        for (i in 0..2048) {
            out.add(UInt8(i & 0xFF))
        }

        let path = mfWrite("a4cj_mf_mp3_garbage.mp3", out.toArray())
        @Assert(mfReadTagsOnly(path))
        remove(path)
    }
}
