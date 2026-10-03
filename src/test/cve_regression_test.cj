package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * CVE 同类攻击面回归样本 —— 开发文档 §10 M5「fuzz 测试 + CVE 回归样本」
 *
 * 【诚实声明（请勿在后续维护中改写为「CVE 复现」）】
 *   本文件**不是**两个 CVE 的 PoC 复现，原因有二：
 *
 *   1. 本项目引入的 dr_libs 是**已修复的版本**：
 *        CVE-2025-14369 —— dr_flac 整数溢出致 DoS，受影响 <= 0.13.2；
 *        CVE-2026-29022 —— dr_wav 堆缓冲区溢出，受影响 <= 0.14.4。
 *      两者在仓库中的头文件里均已修复，因此「复现」在定义上就不成立。
 *   2. 漏洞作者使用的精确字节序列（公开 PoC）未获取到。本文件构造的是
 *      **同类攻击面**的畸形输入 —— 即触发该类漏洞的那类字段（声明长度
 *      远超实际数据、块链永不结束、参数取极端值），而非具体 PoC。
 *
 *   因此本文件的定位是**回归防线**：确保今后任何改动都不会让这些畸形输入
 *   重新变成崩溃或挂起。断言口径是「不崩溃 + 异常落在预期集合内」。
 *
 * 【哪些用例真的走到了 C 代码】（本节已按"MP3 解码移出范围"更新）
 *   - **现在没有任何用例走到 C 代码**：MP3 解码已移出本版本范围
 *     （`AudioFile.open` 在探测层就抛 FormatNotSupportedException，够不到任何
 *     解码器），FLAC 全族与 WAV 都是纯仓颉实现。
 *   - 因此下面两个 MP3 用例如今压的是 **ID3 解析器**（仍是纯仓颉、仍在能力内），
 *     不是 C 解码器 —— 它们原先那句 `cveOpenAndDrain` 断言已因恒真而移除。
 *   - FLAC（**原生与 Ogg 封装**）：解码都走**纯仓颉内核** —— 含帧头 CRC-8、
 *     帧尾 CRC-16，Ogg 侧还有页级重组与页 CRC-32 校验，均不经 dr_flac。
 *     相应用例针对的是**我们自己的解码器**，覆盖同类攻击面。
 *   - WAV：解码走**纯仓颉**实现，不经 dr_wav，故 CVE-2026-29022 在本项目的
 *     解码路径上并不适用。WAV 用例针对的是**我们自己的解析器**，覆盖同类
 *     攻击面（长度字段与实际数据严重不符）。
 *
 *   ⚠ 供应链侧已经收尾：dr_libs 的代码**已不在制品内**（C 依赖整体移除），
 *     那两条 CVE（dr_flac / dr_wav）的暴露面归零，清单可以就此关闭
 *     （见 LICENSES.md 第一节的留痕）。
 *     但**同类攻击面的回归不能停** —— 下面这些用例现在压的是我们自己的解析器，
 *     它们恰恰是"去掉 C 之后还敢不敢说自己健壮"的依据。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

private func cveAppendAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func cveAppendUInt16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func cveAppendUInt32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

private func cveWrite(name: String, bytes: Array<UInt8>): String {
    File.writeTo(name, bytes)
    name
}

/// 打开并**有限地**消费数据。
///
/// 只接受两种结局：正常完成，或抛出库内异常 / 文件系统异常。
/// 其它异常（数组越界、空指针、类型转换失败等）会向上传播并使用例失败 ——
/// 那正是我们想要暴露的缺陷。返回 true 仅表示「结局在预期集合内」。
private func cveOpenAndDrain(path: String): Bool {
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
private func cveReadTagsOnly(path: String): Bool {
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
class CveRegressionTest {
    /// FLAC：元数据块声明长度 0xFFFFFF（约 16 MB），实际仅 8 字节
    ///
    /// 这是 CVE-2025-14369 的同类攻击面 —— 该漏洞正是由"声明长度"参与
    /// 整数运算时溢出引发的。
    @TestCase
    func flacBlockLengthFarExceedsFile() {
        let out = ArrayList<UInt8>()
        cveAppendAscii(out, "fLaC")
        out.add(0x80u8) // isLast = 1、类型 0（STREAMINFO）
        out.add(0xFFu8) // 声明长度 0xFFFFFF
        out.add(0xFFu8)
        out.add(0xFFu8)
        for (i in 0..8) { // 实际只给 8 字节
            out.add(0u8)
        }

        let path = cveWrite("a4cj_cve_flac_huge.flac", out.toArray())
        @Assert(cveOpenAndDrain(path))
        @Assert(cveReadTagsOnly(path))
        remove(path)
    }

    /// FLAC：块链永不置结束位（声称后面还有块，实则已到文件末尾）
    ///
    /// 覆盖"无终止的块链"这一攻击面：解析器必须在文件末尾安全停下，
    /// 不能因为循环条件依赖那个永远不来的结束位而挂起。
    @TestCase
    func flacUnterminatedBlockChain() {
        let out = ArrayList<UInt8>()
        cveAppendAscii(out, "fLaC")

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

        let path = cveWrite("a4cj_cve_flac_chain.flac", out.toArray())
        @Assert(cveOpenAndDrain(path))
        @Assert(cveReadTagsOnly(path))
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
        cveAppendAscii(out, "fLaC")
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

        let path = cveWrite("a4cj_cve_flac_zero.flac", out.toArray())
        @Assert(cveOpenAndDrain(path))
        @Assert(cveReadTagsOnly(path))
        remove(path)
    }

    /// WAV：RIFF 长度与 data 长度都被谎报为极大值
    ///
    /// 注意：这些样本针对的是**纯仓颉的 WAV 解析器**（本项目解码 WAV 不经
    /// dr_wav），覆盖"长度字段远超实际数据"这一类攻击面。
    @TestCase
    func wavOversizedLengthFields() {
        let out = ArrayList<UInt8>()
        cveAppendAscii(out, "RIFF")
        cveAppendUInt32LE(out, 0xFFFFFFFF) // RIFF 长度谎报
        cveAppendAscii(out, "WAVE")

        cveAppendAscii(out, "fmt ")
        cveAppendUInt32LE(out, 16)
        cveAppendUInt16LE(out, 1) // PCM
        cveAppendUInt16LE(out, 1) // 单声道
        cveAppendUInt32LE(out, 44100)
        cveAppendUInt32LE(out, 88200)
        cveAppendUInt16LE(out, 2)
        cveAppendUInt16LE(out, 16)

        cveAppendAscii(out, "data")
        cveAppendUInt32LE(out, 0xFFFFFFF0) // data 长度谎报（约 4 GB）
        for (i in 0..32) { // 实际只有 32 字节
            out.add(0u8)
        }

        let path = cveWrite("a4cj_cve_wav_huge.wav", out.toArray())
        @Assert(cveOpenAndDrain(path))
        remove(path)
    }

    /// WAV：fmt 字段取极端非法值（声道数 0、位深 0、block align 0）
    @TestCase
    func wavAbsurdFormatFields() {
        let out = ArrayList<UInt8>()
        cveAppendAscii(out, "RIFF")
        cveAppendUInt32LE(out, 36)
        cveAppendAscii(out, "WAVE")

        cveAppendAscii(out, "fmt ")
        cveAppendUInt32LE(out, 16)
        cveAppendUInt16LE(out, 1) // PCM
        cveAppendUInt16LE(out, 0) // 声道数 0（非法）
        cveAppendUInt32LE(out, 44100)
        cveAppendUInt32LE(out, 0) // 平均字节率 0
        cveAppendUInt16LE(out, 0) // block align 0
        cveAppendUInt16LE(out, 0) // 位深 0（非法）

        cveAppendAscii(out, "data")
        cveAppendUInt32LE(out, 4)
        for (i in 0..4) {
            out.add(0u8)
        }

        let path = cveWrite("a4cj_cve_wav_fmt.wav", out.toArray())
        @Assert(cveOpenAndDrain(path))
        remove(path)
    }

    /// MP3：ID3v2 头声明 synchsafe 最大长度（约 256 MB），实际不足 140 字节
    ///
    /// 【重点变了】解码路径已不在范围内，`AudioFile.open` 在探测层就被拦下、
    /// 够不到任何解码器 —— 原先那句 `cveOpenAndDrain` 断言现在**恒真**，
    /// 留着只会让人以为这里还在验 C 路径。真正仍有价值的是 **ID3 解析器**：
    /// 它仍是纯仓颉、仍在本版本能力内，`cveReadTagsOnly` 正是压它的那条。
    @TestCase
    func mp3OversizedId3Tag() {
        let out = ArrayList<UInt8>()
        cveAppendAscii(out, "ID3")
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

        let path = cveWrite("a4cj_cve_mp3_id3.mp3", out.toArray())
        @Assert(cveReadTagsOnly(path))
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

        let path = cveWrite("a4cj_cve_mp3_garbage.mp3", out.toArray())
        @Assert(cveReadTagsOnly(path))
        remove(path)
    }
}
