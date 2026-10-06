package audio4cj_examples

import audio4cj.facade.AudioFile

/* ============================================================================
 * 示例五：端到端验证（把「解码结果对不对」变成可判读的一行结论）
 *
 * 【为什么要有这个示例】
 *   `info` 示例只回答"这是什么格式、参数是多少"，`stream` 示例只回答"能读完"。
 *   但"能读"不等于"读对了"：帧数少了一段、时长差一截，前两个示例都不会吭声。
 *   本示例把**声明与实际**摆在一起做对照，并给出一行结论 —— 可以直接粘给别人看，
 *   也能在 CI 里当守卫（结论为「不通过」时进程返回 1）。
 *
 * 【判据不是本示例自创的，全部来自库内既有口径】
 *   · 无损（wav / flac / ogg+flac）：**声明帧数 == 实际解出帧数**。
 *     依据：同一段 PCM 的两种无损封装必须逐位相同（`src/test/golden_test.cj`
 *     的 `losslessCrossContainerIsBitIdentical`），帧数自然也必须相等。
 *   · 有损（mp3）：允许**实际 ≥ 声明**，且差值 ≤ **2 个压缩帧**（MPEG1 每帧
 *     1152 个 PCM 帧 → 上界 2304）。依据：`src/test/golden_test.cj` 的
 *     `GT_ENVELOPE_MAX_EXTRA_SAMPLES = 9216`（交错样本口径，立体声 9216 / 2 = 4608）
 *     与包络用例 `mp3MatchesInEnvelopeNotSampleBySample`。
 *     多出来的原因是**编码器延迟与末尾填充帧**（LAME 会在流首写入延迟、流尾补一个
 *     填充帧），这是有损格式的固有现象，**不是缺陷**。
 *     MPEG2 / MPEG2.5 每帧只有 576 个样本，多出的量只会更小，故同一上界对它们也成立。
 *   · 声明不可知（`totalFrames == -1`，例如未写 Xing 的流）：**不比差值**，
 *     只报实际帧数 —— 判据要求"两边都得有数"，只有一边就不该硬判。
 *
 * 【与 ffmpeg 的关系】本示例**不依赖任何外部工具**（示例要能被任何人直接跑起来）。
 *   与 ffmpeg 的逐样本/包络比对属于测试层的事，见 `src/test/golden_test.cj`。
 * ========================================================================== */

/// 有损格式允许比"声明帧数"多出的 PCM 帧上限：2 个 MPEG1 压缩帧。
///
/// 取值理由见文件头：一是与 `GT_ENVELOPE_MAX_EXTRA_SAMPLES`（9216 个交错样本，
/// 立体声即 4608 帧）同源；二是保留 2 帧而不是 1 帧的余量 —— 不同编码器
/// 写入的延迟/填充组合不同，卡到 1 帧会把合法文件判成失败。
///
/// 【实测校准（2026-10-06）】`testdata/mp3/mp3_cbr_128k.mp3` 与两首真实歌曲
/// （各约 5 分钟）**都恰好只多出 1152 帧**（1 个压缩帧）。也就是说实际余量
/// 比上限大得多，上限选 2 帧是刻意留出的安全边界，而不是"贴着实测值卡"。
private let VERIFY_LOSSY_EXTRA_FRAME_CAP: Int64 = 2 * 1152

/// 判断该容器/编码是否属于**无损**（帧数必须严格相等）。
///
/// Ogg 封装的 FLAC 也要算进来：它是同一段无损数据的另一种封装
/// （本库解它时先重建出与原生 FLAC 逐字节等同的流），故同样要求相等。
private func verifyIsLossless(container: String, codec: String): Bool {
    if (container == "wav" || container == "flac") {
        return true
    }
    if (container == "ogg" && codec == "flac") {
        return true
    }
    false
}

/// 生成结论行（不含前缀），并在判定为「不通过」时由调用方转成非零退出码。
private func verifyVerdict(container: String, codec: String, declared: Int64, actual: Int64): String {
    if (declared < 0) {
        return "无法判定 —— 文件未声明总帧数（只报实际值，不做差值比较）"
    }

    let diff = actual - declared

    if (verifyIsLossless(container, codec)) {
        if (diff == 0) {
            return "通过 —— 无损格式：实际帧数与声明帧数完全相等（${actual}）"
        }
        return "不通过 —— 无损格式要求逐位相同，但实际 ${actual} 与声明 ${declared} 相差 ${diff} 帧"
    }

    // 有损（当前即 mp3）：允许"多出编码器延迟 + 末尾填充帧"，但不允许"少"
    if (diff < 0) {
        return "不通过 —— 有损格式不允许丢失数据，但实际 ${actual} 少于声明 ${declared}（缺 ${-diff} 帧）"
    }
    if (diff > VERIFY_LOSSY_EXTRA_FRAME_CAP) {
        return "不通过 —— 有损格式最多允许多出 ${VERIFY_LOSSY_EXTRA_FRAME_CAP} 帧（编码器延迟 + 末尾填充），" +
            "实际多出 ${diff} 帧，超出合理范围"
    }
    return "通过 —— 有损格式：实际 ${actual} ≥ 声明 ${declared}，多出 ${diff} 帧" +
        "（编码器延迟 + 末尾填充，属正常现象；上限 ${VERIFY_LOSSY_EXTRA_FRAME_CAP} 帧）"
}

/// 端到端验证：格式识别 + 流式解码 + 声明/实际帧数对照 + 一行结论。
///
/// 返回 **0 = 通过或无法判定（不算失败）**、**1 = 不通过**、**2 = 打开失败**。
/// 之所以让"不通过"返回非零，是为了能直接当 CI 守卫用（见 examples/README.md）。
func exampleVerify(path: String): Int64 {
    var code: Int64 = 0

    // 注意：try-with-resources 是**表达式且类型为 Unit**，因此返回值必须在块外给出
    // （在块内 `return` 虽然能编译，但与资源释放的写法不一致；这里统一用 code 变量）
    try (f = AudioFile.open(path)) {
        let fmt = f.format()
        let info = f.info()

        println("[verify] 文件      : ${path}")
        println("[verify] 容器      : ${fmt.container}")
        println(
            "[verify] 编码      : ${if (fmt.codec.isEmpty()) { "(无，容器本身即编码)" } else { fmt.codec }}" +
                " → ${fmt.codecId}（${fmt.mimeType}）")
        println("[verify] 参数      : ${info.sampleRate} Hz / ${info.channels} 声道 / 位深 ${info.bitDepth}")
        println("[verify] 声明时长  : ${info.durationMs} ms")

        // ---- 声明值（来自文件头/标签，MP3 即 Xing/Info；-1 表示不可知）----
        let declared = info.totalFrames
        if (declared >= 0) {
            println("[verify] 声明帧数  : ${declared}")
        } else {
            println("[verify] 声明帧数  : 不可知（未声明总帧数，如无 Xing 头的 MP3 流）")
        }

        // ---- 实际解码（流式：内存占用与音频时长无关）----
        let s = f.stream()
        var chunks: Int64 = 0
        var frames: Int64 = 0
        var peak: Float32 = 0.0
        // 平方和：有损格式的"整体能量"判据（与 golden 用例的包络口径一致）。
        // 用 Float64 累加，避免长音频上 Float32 丢有效位。
        var sumSq: Float64 = 0.0
        var sampleCount: Int64 = 0

        // 峰值的位置也要记下来：有损格式"峰值偏高"时，第一件事就是看它出现在哪 ——
        // 若落在流首（编码器延迟区）就与音频内容无关（详见 examples/README.md）。
        var peakFrame: Int64 = 0

        while (let Some(chunk) <- s.next()) {
            chunks += 1
            let samples = chunk.samples
            let ch = if (chunk.channels > 0) {
                chunk.channels
            } else {
                1
            }
            for (i in 0..samples.size) {
                let v = samples[i]
                let a = if (v < 0.0) {
                    -v
                } else {
                    v
                }
                if (a > peak) {
                    peak = a
                    peakFrame = frames + i / ch
                }
                let d = Float64(v)
                sumSq += d * d
            }
            frames += chunk.frameCount
            sampleCount += chunk.sampleCount
        }

        // 实测时长：用"实际帧数 ÷ 采样率"算，与声明时长对照（只作参考，不参与判定）
        let actualMs = if (info.sampleRate > 0) {
            frames * 1000 / info.sampleRate
        } else {
            0
        }

        println("[verify] 实际帧数  : ${frames}")
        println("[verify] 分块      : ${chunks} 块（流式：内存占用与时长无关）")
        println("[verify] 实际时长  : ${actualMs} ms")
        let peakMs = if (info.sampleRate > 0) {
            peakFrame * 1000 / info.sampleRate
        } else {
            0
        }
        // 【峰值口径按格式区分，别拿一个标准套两种格式】
        //   · 无损：样本由整数按 v / 2^(n-1) 归一化，**必然 <= 1.0**
        //     （16 位下 -32768 恰好对应 -1.0，所以"峰值 = 1.000000"是正常值）；
        //   · 有损：解码输出不做削顶，素材本身的过冲会原样保留 —— **可以 > 1.0**。
        //     这不是缺陷：用 ffmpeg 在浮点域测同一素材同样 > 1.0（实测 baihu 1.096）。
        println("[verify] 峰值      : ${peak}（出现在第 ${peakFrame} 帧 / ${peakMs} ms）")

        // 整体能量：既是"有损格式与参照实现对不对得上"的判据（本库 golden 用的就是它），
        // 也能给无损格式一个"音频是否为空/静音"的侧面证据。
        if (sampleCount > 0) {
            let meanPower = sumSq / Float64(sampleCount)
            println("[verify] 平均功率  : ${meanPower}（样本平方的均值：有损格式的包络判据）")
        }

        // ---- 结论 ----
        let verdict = verifyVerdict(fmt.container, fmt.codec, declared, frames)
        println("[verify] 结论      : ${verdict}")

        if (verdict.startsWith("不通过")) {
            code = 1
        }
    } catch (e: Exception) {
        // 打开失败：文件不存在 / 无权限 / 格式不支持 / 结构损坏。
        // 分不清是哪一种时，把异常原文照打 —— 本库的异常信息里带编码级标识。
        println("[verify] 文件      : ${path}")
        println("[verify] 结论      : 打开失败 —— ${e.message}")
        code = 2
    }

    code
}
