package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.meta.safeSlice
import std.fs.*
import std.binary.*
import std.collection.ArrayList

/* ============================================================================
 * golden PCM 正确性基线 —— 开发文档 §9.1「v2.0 最重要的质量机制」
 *
 * 【为什么要外部裁判】
 *   「没有裁判的自研等于黑盒」。本库的所有解码都是纯仓颉实现（WAV 是位深转换，
 *   FLAC 是完整的帧解码，Ogg 还多一层页重组与页 CRC-32 校验）——
 *   换句话说，**整条链路都是"自己人说自己对"**。
 *   这里引入 **ffmpeg 的解码输出**作为独立一方，把它的结果固化成文件入库，
 *   任何机器上跑测试都能复现比对，不要求装了 ffmpeg。
 *
 *   FLAC 全族切换到纯仓颉内核之后，这条外部裁判的意义更重了：它就是
 *   "纯仓颉内核解得对不对"的最终依据（本文件通过 `AudioFile.open` 走生产路径，
 *   因此覆盖的正是切换后的内核 —— 原生与 Ogg 封装都在内）。
 *
 * 【基准为什么用 f32le 而不是整型 PCM】
 *   若基准存整型 PCM，比对前就得用**被测库自己的**位深转换函数去解释它；
 *   那个函数一旦有错，比对结果反而恒等 —— 自己给自己判卷。存 f32 则完全
 *   绕开被测代码（用 std.binary 的 Float32.readLittleEndian 直接还原），
 *   把被测库的输出与基准逐样本相减即可。
 *
 * 【三层防线，覆盖不同性质的问题】
 *   1. **无损互证（容差 0）**：同一段 PCM 分别以 WAV 与 FLAC 封装，两者都是
 *      无损，解码结果必须**逐位相同**。这条完全不需要外部工具，因此在没有
 *      ffmpeg 的环境里仍然有效 —— 它拦住的是"两条解码路径不一致"这类问题。
 *   2. **ffmpeg 逐样本比对**：拦住缩放系数、字节序、声道交错等系统性错误。
 *   3. **MP3 只做松比对**：有损解码器在量化细节与编码器延迟补偿上合法地存在
 *      差异，逐样本等同做不到。强行断言相等会把正确行为判成缺陷，
 *      因此只比帧数与整体能量。
 * ========================================================================== */

/// 素材根目录。
private let GT_DATA_ROOT: String = "testdata"

/// 基准所在目录。
private let GT_GOLDEN_DIR: String = "testdata/golden"

/// 素材 → 基准的映射表（由 scripts/gen_testdata.sh 或 .ps1 生成）。
private let GT_MANIFEST: String = "testdata/golden/GOLDEN.tsv"

/// 与 ffmpeg 基准比对的逐样本容差。
///
/// 依据：本库的归一化是 `v / 2^(n-1)`（见 pcm/convert.cj 文件头），
/// ffmpeg 转 f32 采用同一约定，因此理论上应当完全相等。
///
/// **实测结果（2026-10-02，本机 ffmpeg 9.0.2）**：映射表里 10 项 samples 比对
/// 的**最大差全部为 0** —— 包括 8/16/24 位、单/双声道、16k/44.1k，以及
/// Ogg 封装的 FLAC。也就是说双方本就逐位相同。
///
/// 那为什么容差还留 1e-6 而不是收紧到 0？因为「逐位相同」是**当前实现与
/// 当前 ffmpeg 版本**的实测事实，不是接口契约：换一个 ffmpeg 版本、换一套
/// 浮点运算实现（如不同的 swresample 路径），末位就可能差 1 ULP。把断言写成
/// 0 会让测试在无实质变化时变红，从而失去信噪比。1e-6 这个值：
///   - 大于 Float32 在 1.0 附近的 1 ULP（约 6e-8），不会误报；
///   - 远比 16 位的最小量化步长（约 3e-5）紧 30 倍，任何一位的缩放错误都跑不掉。
private let GT_TOLERANCE: Float32 = 1.0e-6

/// 有损格式（MP3）包络比对：**总能量**（平方和）的相对容差。
///
/// 【为什么有损格式不能用逐样本比对】两套有损解码器在量化细节与编码器延迟
/// 补偿上**合法地**存在差异（不同实现的合成滤波器组舍入不同，实测噪声素材上
/// 逐样本相关只有 0.99 量级）。逐样本相等在这里不是"更高标准"，而是一个错误
/// 标准 —— 它会把正确行为判成缺陷。因此改用**包络**判据：
///   · 长度：我们的输出必须**不少于**基准，且多出的部分不超过编码器延迟/填充
///     的合理上限（见 GT_ENVELOPE_MAX_EXTRA_SAMPLES）；
///   · 能量：**总能量（平方和）**的相对差 <= 5%（不用平均功率 —— 理由见
///     gtTotalEnergy 的说明：样本数不同会把长度差异误算成能量差异）。
/// 实测（2026-10-05，本机 ffmpeg 9.0.2，mp3_cbr_128k，正弦）：
/// 长度 94464 vs 88200 交错样本（多出 6264 = 编码器延迟 + 末尾填充帧），
/// **总能量相对差 0.0%** —— 能量这一项才是拦住"缩放系数错、声道错位、
/// 频谱算错"的那道闸。
private let GT_ENVELOPE_ENERGY_TOLERANCE: Float64 = 0.05

/// 有损格式允许比基准多出的交错样本数上限。
///
/// 依据：LAME 会在流首写入编码器延迟（576 样本/声道）、流尾补一个填充帧，
/// ffmpeg 解码时按 Xing/Info 的 gapless 信息把它们裁掉，而我们输出**完整**
/// 帧序列。1 秒 44.1kHz 立体声实测多出 6264 个交错样本（≈2.7 个 MP3 帧），
/// 这里取 2 个 MPEG1 帧的 4 倍（2 × 1152 × 2ch × 2 = 9216）作为上限，
/// 既容得下合法的延迟/填充，又拦得住"多解出一整段"这类真错误。
private let GT_ENVELOPE_MAX_EXTRA_SAMPLES: Int64 = 9216

/// 无损互证对：同一段 PCM 的两种无损封装。
///
/// 两侧必须由**同一参考信号、同一时长、同一声道数**生成 —— 这是"互证"成立
/// 的前提。素材若被改动（比如某一边换了时长），这里会立刻失败，这正是我们要的：
/// 前提被破坏时，互证就失去意义，不该静默通过。
private let GT_LOSSLESS_PAIRS: Array<(String, String)> = [
    ("wav/wav_s16_44100_stereo.wav", "flac/flac_s16_44100_stereo.flac"),
    ("wav/wav_s24_44100_stereo.wav", "flac/flac_s24_44100_stereo.flac"),
    ("wav/wav_s16_44100_mono.wav", "flac/flac_s16_44100_mono.flac"),
    ("wav/wav_s16_16000_mono.wav", "flac/flac_s16_16000_mono.flac")
]

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

/// 读取基准文件并还原为交错 f32 样本。
///
/// 直接按 IEEE754 小端还原，**不经过被测库的任何转换函数**（理由见文件头）。
private func gtLoadGolden(fileName: String): Array<Float32> {
    var bytes = Array<UInt8>()

    try (f = File("${GT_GOLDEN_DIR}/${fileName}", Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        bytes = safeSlice(buf, 0, got)
    }

    let count = bytes.size / 4
    let out = Array<Float32>(count, repeat: 0.0)
    for (i in 0..count) {
        out[i] = Float32.readLittleEndian(safeSlice(bytes, i * 4, 4))
    }
    out
}

/// 完整解码一个素材，返回其交错 f32 样本。
private func gtDecode(relPath: String): Array<Float32> {
    var out = Array<Float32>()
    try (f = AudioFile.open("${GT_DATA_ROOT}/${relPath}")) {
        out = f.readAll().samples
    }
    out
}

/// 返回逐样本最大绝对差；长度不一致时返回一个明显超限的值以触发断言。
private func gtMaxDiff(a: Array<Float32>, b: Array<Float32>): Float32 {
    if (a.size != b.size) {
        return 999.0
    }

    var maxDiff: Float32 = 0.0
    for (i in 0..a.size) {
        var d = a[i] - b[i]
        if (d < 0.0) {
            d = -d
        }
        if (d > maxDiff) {
            maxDiff = d
        }
    }
    maxDiff
}

/// 整体平均功率（单样本能量；不开方，既省 std.math 又不丢信息）。
private func gtMeanPower(samples: Array<Float32>): Float64 {
    if (samples.size == 0) {
        return 0.0
    }
    var sum: Float64 = 0.0
    for (v in samples) {
        let d = Float64(v)
        sum += d * d
    }
    sum / Float64(samples.size)
}

/// 整体能量（平方和）。
///
/// 【为什么有损格式要比"总能量"而不是"平均功率"】我们的输出包含编码器延迟
/// 与末尾填充帧（ffmpeg 会按 gapless 信息裁掉），两侧**样本数不同**。平均功率
/// 分母不同，会把这点长度差异直接放大成 7% 的"能量差"（实测），而总能量不受
/// 样本数影响 —— 它才是"解码是否正确还原了这段声音"的不变量。
private func gtTotalEnergy(samples: Array<Float32>): Float64 {
    var sum: Float64 = 0.0
    for (v in samples) {
        let d = Float64(v)
        sum += d * d
    }
    sum
}

/// 相对差：|x - y| / max(|y|, eps)，避免基准为零时除零。
private func gtRelativeDiff(x: Float64, y: Float64): Float64 {
    let eps = 1.0e-12
    var base = y
    if (base < 0.0) {
        base = -base
    }
    if (base < eps) {
        base = eps
    }
    var d = x - y
    if (d < 0.0) {
        d = -d
    }
    d / base
}

/// 读取 GOLDEN.tsv，返回 (素材相对路径, 基准文件名, 比对模式)。
private func gtLoadManifest(): ArrayList<(String, String, String)> {
    let rows = ArrayList<(String, String, String)>()

    try (f = File(GT_MANIFEST, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        let text = String.fromUtf8(safeSlice(buf, 0, got))

        for (line in text.lines()) {
            let s = line.trimAscii()
            if (s.isEmpty() || s.startsWith("#")) {
                continue
            }
            let parts = s.split("\t")
            if (parts.size < 2) {
                continue
            }
            let mode = if (parts.size >= 3) {
                parts[2]
            } else {
                "samples"
            }
            rows.add((parts[0], parts[1], mode))
        }
    }

    rows
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class GoldenTest {
    /// 映射表里的每个素材与每个基准都必须存在
    ///
    /// 这条守住"基准与素材不同步"：改了素材名或删了基准却忘了重新生成，
    /// 后面的比对会因为读不到文件而失败，但报错信息会指向比对逻辑，
    /// 让人误以为是解码出了问题。这里先把定位问题的那句话说出来。
    @TestCase
    func manifestEntriesResolve() {
        if (gsSkipIfNoFixtures("manifestEntriesResolve")) {
            return
        }

        let rows = gtLoadManifest()
        @Assert(rows.size > 0)

        let missing = ArrayList<String>()
        for (row in rows) {
            let (fixture, golden, _mode) = row
            if (!exists(Path("${GT_DATA_ROOT}/${fixture}"))) {
                missing.add("素材缺失: ${fixture}")
            }
            if (!exists(Path("${GT_GOLDEN_DIR}/${golden}"))) {
                missing.add("基准缺失: ${golden}")
            }
        }

        if (!missing.isEmpty()) {
            @Fail(String.join(missing.toArray(), delimiter: " | "))
        }
    }

    /// 无损互证：同一段 PCM 的 WAV 与 FLAC 封装，解码结果必须**逐位相同**
    ///
    /// 容差为 0 —— 两侧都是无损，没有任何合法的理由产生差异。这条不需要
    /// 外部工具，因此是无 ffmpeg 环境下的主力防线。
    @TestCase
    func losslessCrossContainerIsBitIdentical() {
        if (gsSkipIfNoFixtures("losslessCrossContainerIsBitIdentical")) {
            return
        }

        let bad = ArrayList<String>()

        for (pair in GT_LOSSLESS_PAIRS) {
            let (wavPath, flacPath) = pair
            let a = gtDecode(wavPath)
            let b = gtDecode(flacPath)

            let diff = gtMaxDiff(a, b)
            // 打印实测值：失败时能立刻看出差异量级（是浮点末位还是真错了）
            println("${wavPath} vs ${flacPath}: 样本 ${a.size}/${b.size}, 最大差 ${diff}")

            if (diff != 0.0) {
                bad.add("${wavPath} 与 ${flacPath} 不逐位相同（最大差 ${diff}）")
            }
        }

        if (!bad.isEmpty()) {
            @Fail(String.join(bad.toArray(), delimiter: " | "))
        }
    }

    /// 与 ffmpeg 基准逐样本比对（沿用映射表里的 samples 模式项）
    @TestCase
    func ffmpegGoldenMatchesSampleBySample() {
        if (gsSkipIfNoFixtures("ffmpegGoldenMatchesSampleBySample")) {
            return
        }

        let rows = gtLoadManifest()
        let bad = ArrayList<String>()
        var checked: Int64 = 0

        for (row in rows) {
            let (fixture, golden, mode) = row
            if (mode != "samples") {
                continue
            }

            let actual = gtDecode(fixture)
            let expected = gtLoadGolden(golden)
            let diff = gtMaxDiff(actual, expected)

            println("${fixture} vs ${golden}: 样本 ${actual.size}/${expected.size}, 最大差 ${diff}")

            if (diff > GT_TOLERANCE) {
                bad.add("${fixture} 与基准 ${golden} 的最大差 ${diff} 超过容差 ${GT_TOLERANCE}")
            }
            checked += 1
        }

        @Assert(checked > 0)
        if (!bad.isEmpty()) {
            @Fail(String.join(bad.toArray(), delimiter: " | "))
        }
    }

    /// 有损格式（MP3）的包络比对：长度 + 整体能量，**不做**逐样本比对
    ///
    /// 沿用映射表里 `envelope` 模式的行。判据与容差见 GT_ENVELOPE_* 常量的说明。
    @TestCase
    func mp3MatchesInEnvelopeNotSampleBySample() {
        if (gsSkipIfNoFixtures("mp3MatchesInEnvelopeNotSampleBySample")) {
            return
        }

        let rows = gtLoadManifest()
        let bad = ArrayList<String>()
        var checked: Int64 = 0

        for (row in rows) {
            let (fixture, golden, mode) = row
            if (mode != "envelope") {
                continue
            }

            let actual = gtDecode(fixture)
            let expected = gtLoadGolden(golden)
            let extra = actual.size - expected.size
            let energyRelDiff = gtRelativeDiff(gtTotalEnergy(actual), gtTotalEnergy(expected))

            println(
                "${fixture} vs ${golden}（包络）: 样本 ${actual.size}/${expected.size} " +
                    "(多 ${extra}), 总能量相对差 ${energyRelDiff}")

            // 输出必须不少于基准：少说明丢了音频，是真缺陷
            if (extra < 0) {
                bad.add("${fixture} 输出样本数 ${actual.size} 少于基准 ${expected.size}")
            }
            // 多出的只能是编码器延迟/填充；超过上限说明多解出了内容
            if (extra > GT_ENVELOPE_MAX_EXTRA_SAMPLES) {
                bad.add("${fixture} 比基准多出 ${extra} 个样本，超过上限 ${GT_ENVELOPE_MAX_EXTRA_SAMPLES}")
            }
            if (energyRelDiff > GT_ENVELOPE_ENERGY_TOLERANCE) {
                bad.add("${fixture} 总能量相对差 ${energyRelDiff} 超过容差 ${GT_ENVELOPE_ENERGY_TOLERANCE}")
            }
            checked += 1
        }

        @Assert(checked > 0)
        if (!bad.isEmpty()) {
            @Fail(String.join(bad.toArray(), delimiter: " | "))
        }
    }
}
