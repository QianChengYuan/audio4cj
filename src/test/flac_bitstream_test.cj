package audio4cj.test

import audio4cj.format.FlacDecodeKernel
import audio4cj.format.PureFlacKernel
import audio4cj.pcm.reinterpretF32Bytes
import std.collection.ArrayList

/* ============================================================================
 * 纯仓颉流式内核测试
 *
 * 【两层判据，缺一不可】（原先的"与 dr_libs 逐样本对照"已随 C 依赖移除）
 *
 *   ① **外部裁判**：与 独立第三方解码器 生成的 golden 基准逐样本比对。
 *      这是唯一一条"第三方实现"的判据，且它独立于我们的内核 ——
 *      少了它，这套测试就退化成"自己给自己判卷"。
 *
 *   ② **块大小不变性**：同一文件在 4096 / 1000 / 7 三种块大小下必须逐位相同。
 *      这条接替了原先 FFI 对照在 **pending 通路**上的覆盖：
 *      1000 与帧边界不对齐、7 小到一帧都装不下，pending 会跨多次调用累积。
 *      外部裁判管"解得对不对"，块大小不变性管"分块方式与实际无关"，两者互补：
 *      单独任何一条都盖不住另一条的失效模式。
 *
 * 【为什么 fixture 表里带"期望帧数"而不是只带基准名】
 *   基准只覆盖素材的一部分（见下表注释），且"解码器提前停下"这种失效必须能被
 *   发现 —— 只比对基准前缀会漏掉它。期望帧数由素材生成参数推出（见
 *   scripts/gen_testdata.sh 的 DUR_* 常量），属规格侧的事实。
 *
 * 【本文件的写法本身就是一次验证】`fbDecodeAll` 的参数类型是 `FlacDecodeKernel`
 *   接口 —— 同一段驱动代码服务于任何内核实现。
 * ========================================================================== */

/// 单次读取的最大帧数（与生产路径的 FLAC_CHUNK_FRAMES 一致）。
private let FB_CHUNK_ALIGNED: Int64 = 4096

/// 刻意**不与帧边界对齐**的块大小（压 pending 通路）。
private let FB_CHUNK_ODD: Int64 = 1000

/// 小到一帧都装不下的块大小（pending 会跨多次调用累积）。
private let FB_CHUNK_TINY: Int64 = 7

/// 素材表：(路径, golden 基准名, 期望帧数, 声道数)。
///
/// - `golden` 为空串表示该素材没有基准，其正确性由别的用例承担（见该行注释）。
/// - 三个"2 秒素材"共用 1 秒基准：它们是**同一段正弦**的不同封装与标签形态，
///   而 lavfi 正弦自 t=0 确定性生成、封装无损，故其前 1 秒与基准逐位相同。
private let FB_FIXTURES: Array<(String, String, Int64, Int64)> = [
    // 1 秒正弦，与基准等长（整段比对）
    ("testdata/flac/flac_s16_44100_stereo.flac", "sine_44100_stereo_s16.f32le", 44100, 2),
    ("testdata/flac/flac_s16_44100_mono.flac", "sine_44100_mono_s16.f32le", 44100, 1),
    ("testdata/flac/flac_s16_16000_mono.flac", "tone_16000_mono_s16.f32le", 16000, 1),
    ("testdata/flac/flac_s24_44100_stereo.flac", "sine_44100_stereo_s24.f32le", 44100, 2),
    ("testdata/ogg/ogg_flac.oga", "sine_44100_stereo_s16.f32le", 44100, 2),
    // 2 秒正弦（DUR_TAGGED）：基准是它的前缀
    ("testdata/flac/flac_tagged.flac", "sine_44100_stereo_s16.f32le", 88200, 2),
    ("testdata/flac/flac_cover.flac", "sine_44100_stereo_s16.f32le", 88200, 2),
    ("testdata/ogg/ogg_flac_tagged.oga", "sine_44100_stereo_s16.f32le", 88200, 2),
    // 3 秒静音：没有基准（基准集里没有静音），改由"全零 + 帧数恰为规格值"断言
    ("testdata/flac/flac_silence.flac", "", 132300, 2)
]

/// 用给定内核把整个文件分块解码，返回 f32 交错样本。
private func fbDecodeAll(kernel: FlacDecodeKernel, chunkFrames: Int64): Array<Float32> {
    let channels = kernel.channels()
    let buf = Array<UInt8>(chunkFrames * channels * 4, repeat: 0)
    let out = ArrayList<Float32>()

    var got: Int64 = 1
    while (got > 0) {
        got = kernel.readF32Into(buf, chunkFrames)
        if (got <= 0) {
            break
        }
        for (v in reinterpretF32Bytes(buf[0..got * channels * 4])) {
            out.add(v)
        }
    }
    out.toArray()
}

/// 解码一个素材；失败时取出内核的窗口/游标状态一起报出来。
///
/// 为什么要这些内部量：`readF32Into` 抛出的"比特流截断"只给一个位偏移，
/// 无法区分三种完全不同的成因 ——
///   (a) 帧跨越了窗口末端（"窗口容得下最坏一帧"这一前提被违反）；
///   (b) 游标记账错（少消费了字节，下一帧从数据中间开始）；
///   (c) 结束判定错（声明的样本数与实际帧数之和不等）。
/// 有了这几个数就能直接判定，而不必靠猜（见 diagnosticState 的说明）。
private func fbDecodeFile(path: String, oggWrapped: Bool, chunkFrames: Int64): Array<Float32> {
    let kernel = PureFlacKernel(path, oggWrapped)
    var out = Array<Float32>(0, repeat: 0.0)
    var failure: ?String = None

    try {
        out = fbDecodeAll(kernel, chunkFrames)
    } catch (e: Exception) {
        failure = e.message
    }

    if (let Some(message) <- failure) {
        let (cursor, windowOffset, valid, firstFrame, delivered) = kernel.diagnosticState()
        kernel.close()
        @Fail(
            "${path}（块 ${chunkFrames}）解码失败：${message}\n" +
            "    游标=${cursor} 窗口起点=${windowOffset} 有效长度=${valid} 首帧偏移=${firstFrame} 已交付=${delivered}")
        return out
    }
    kernel.close()
    out
}

/// 是否 Ogg 封装（决定用哪个字节源）。
private func fbIsOgg(path: String): Bool {
    path.contains(".oga")
}

@Test
class FlacBitstreamTest {
    /// ①+② 逐素材：帧数符合规格、与 golden 基准逐样本一致（取交集部分）。
    ///
    /// 【为什么先断帧数再比样本】帧数不符时逐样本比对给出的信息最没用
    /// （会报"第 0 个样本就不同"，而真正的问题是长度）。先断长度，报错才指向原因。
    @TestCase
    func goldenBaselineMatchesOnAllFixtures() {
        if (gsSkipIfNoFixtures("goldenBaselineMatchesOnAllFixtures")) {
            return
        }

        for ((path, golden, expectFrames, channels) in FB_FIXTURES) {
            let actual = fbDecodeFile(path, fbIsOgg(path), FB_CHUNK_ALIGNED)

            if (actual.size != expectFrames * channels) {
                @Fail(
                    "${path}：帧数不符（实际 ${actual.size / channels}，规格 ${expectFrames}，" +
                        "声道 ${channels}）")
                continue
            }

            if ((golden).isEmpty()) {
                // 静音素材：规格要求它解出**恰好全零**，不是"接近零"。
                // 若哪天真出现非零，那是解码把静音解成了噪声 —— 必须红。
                var bad: Int64 = -1
                var i: Int64 = 0
                while (i < actual.size) {
                    if (actual[i] != 0.0) {
                        bad = i
                        break
                    }
                    i += 1
                }
                if (bad >= 0) {
                    @Fail("${path}：静音素材解出非零样本（第 ${bad} 个 = ${actual[bad]}）")
                }
                continue
            }

            let expected = gsLoadGolden(golden)
            // 素材可能是基准的超集（2 秒素材 vs 1 秒基准），故比前缀
            let count = if (expected.size < actual.size) {
                expected.size
            } else {
                actual.size
            }
            if (let Some(msg) <- gsDiffPrefix(actual, 0, expected, count)) {
                @Fail("${path} vs ${golden}：${msg}")
            }
        }
    }

    /// ② 块大小不变性：4096（对齐）/ 1000（不对齐）/ 7（装不下一帧）必须逐位相同。
    ///
    /// 这条是原来的 FFI 对照在 pending 通路上的**接替者**：三种块大小下
    /// pending 的搬运次数与时机完全不同，只要有一条路径记账错位，输出就会出现
    /// 边界处的错位样本。
    @TestCase
    func chunkSizesAgreeOnAllFixtures() {
        if (gsSkipIfNoFixtures("chunkSizesAgreeOnAllFixtures")) {
            return
        }

        for ((path, _, _, _) in FB_FIXTURES) {
            let ogg = fbIsOgg(path)
            let aligned = fbDecodeFile(path, ogg, FB_CHUNK_ALIGNED)
            if (let Some(msg) <- gsDiffIdentical(fbDecodeFile(path, ogg, FB_CHUNK_ODD), aligned)) {
                @Fail("${path}（块 1000 vs 4096）：${msg}")
            }
            if (let Some(msg) <- gsDiffIdentical(fbDecodeFile(path, ogg, FB_CHUNK_TINY), aligned)) {
                @Fail("${path}（块 7 vs 4096）：${msg}")
            }
        }
    }

    /// seek 后读出的样本，必须与"从头顺序解码到该位置"的样本逐位相同。
    ///
    /// 目标刻意包含**落在帧中间**的位置（如 4097、1001）：
    /// 帧粒度与请求粒度不一致是 seek 最容易出错的地方。
    @TestCase
    func seekMatchesSequentialDecode() {
        if (gsSkipIfNoFixtures("seekMatchesSequentialDecode")) {
            return
        }

        let path = "testdata/flac/flac_s16_44100_stereo.flac"
        let full = fbDecodeFile(path, false, FB_CHUNK_ALIGNED)
        @Assert(full.size > 0)

        let channels: Int64 = 2
        let targets = [0, 1, 1001, 4096, 4097, 20000, 40000]

        for (target in targets) {
            let kernel = PureFlacKernel(path, false)
            if (!kernel.seekToFrame(target)) {
                @Fail("seek 到 ${target} 返回 false")
                kernel.close()
                continue
            }

            let buf = Array<UInt8>(512 * channels * 4, repeat: 0)
            let got = kernel.readF32Into(buf, 512)
            let samples = reinterpretF32Bytes(buf[0..got * channels * 4])

            var i: Int64 = 0
            while (i < samples.size) {
                let refIndex = target * channels + i
                if (refIndex >= full.size) {
                    break
                }
                if (samples[i] != full[refIndex]) {
                    @Fail(
                        "seek 到 ${target} 后第 ${i} 个样本不符：${samples[i]} vs 顺序解码的 ${full[refIndex]}")
                    break
                }
                i += 1
            }
            kernel.close()
        }
    }

    /// Ogg 封装的 FLAC：seek 后同样必须与顺序解码逐位相同。
    ///
    /// 【为什么 Ogg 侧要单独验】它与原生文件的 seek 是**不同的错误面**：
    ///   原生：按 SEEKTABLE 偏移移动文件指针即可；
    ///   Ogg ：要先在重建流的坐标系里跳到该偏移 —— 源必须逐页按段表算出
    ///         页体长度越过，并正确定位到"落在某页中间"的那个字节。
    /// 一个是移动指针，一个是要自己算出跨了几页、页内偏移多少，
    /// 不能靠原生用例通过来推断。
    ///
    /// 注意 Ogg-FLAC 的 STREAMINFO 常把总样本数写成 0（不可知），
    /// 故本用例只比对**实际解出的样本**，不依赖 totalFrames。
    @TestCase
    func oggSeekMatchesSequentialDecode() {
        if (gsSkipIfNoFixtures("oggSeekMatchesSequentialDecode")) {
            return
        }

        let path = "testdata/ogg/ogg_flac.oga"
        let full = fbDecodeFile(path, true, FB_CHUNK_ALIGNED)
        @Assert(full.size > 0)

        let channels: Int64 = 2
        let targets = [0, 1, 1001, 4096, 4097, 20000]

        for (target in targets) {
            let kernel = PureFlacKernel(path, true)
            if (!kernel.seekToFrame(target)) {
                @Fail("Ogg/FLAC seek 到 ${target} 返回 false")
                kernel.close()
                continue
            }

            let buf = Array<UInt8>(512 * channels * 4, repeat: 0)
            let got = kernel.readF32Into(buf, 512)
            let samples = reinterpretF32Bytes(buf[0..got * channels * 4])

            var i: Int64 = 0
            while (i < samples.size) {
                let refIndex = target * channels + i
                if (refIndex >= full.size) {
                    break
                }
                if (samples[i] != full[refIndex]) {
                    @Fail(
                        "Ogg/FLAC seek 到 ${target} 后第 ${i} 个样本不符：${samples[i]} vs 顺序解码的 ${full[refIndex]}")
                    break
                }
                i += 1
            }
            kernel.close()
        }
    }
}
