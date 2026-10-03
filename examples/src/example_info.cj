package audio4cj_examples

import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException

/* ============================================================================
 * 示例四：容器 / 编码识别 + 基本信息
 *
 * 【探测结果的两种暴露方式】
 *   · `format()` —— 容器与编码，`container` / `codec` 分开可读，
 *                   因此程序化判断不必去切字符串；
 *   · `tracks()` —— 轨道信息（当前都是单轨）。
 *
 *   两者都是 `open()` 时的**快照**：`close()` 之后**依然可读**。
 *   这一点对"媒体库扫盘"很重要 —— 先看是什么格式，再决定要不要解码，
 *   不该为了问一句格式而让文件保持打开。
 *
 * 【不受支持的格式仍能被识别】
 *   探测与解码是两件事：**MP3（其解码已移出本版本范围）**、Ogg/Vorbis、MP4 等
 *   都会被准确识别（连子编码一起），只是 `open()` 会抛
 *   `FormatNotSupportedException` —— 异常信息里写的就是 `format().codecId`
 *   那套标识。要读它们的**标签**请用示例 tags。
 * ========================================================================== */
func exampleInfo(path: String): Int64 {
    try (f = AudioFile.open(path)) {
        // ---- 格式（探测结果）----
        let fmt = f.format()
        println("[info] 容器     : ${fmt.container}")
        println("[info] 子编码   : ${if (fmt.codec.isEmpty()) { "(无，容器本身即编码)" } else { fmt.codec }}")
        println("[info] 归一化标识: ${fmt.codecId}")
        println("[info] MIME     : ${fmt.mimeType}")

        // ---- 轨道 ----
        let tracks = f.tracks()
        println("[info] 轨道数   : ${tracks.size}")
        for (t in tracks) {
            println("         #${t.index} ${t.codecId} ${t.sampleRate} Hz ${t.channels} 声道")
        }

        // ---- 基本信息 ----
        let info = f.info()
        println("[info] 采样率   : ${info.sampleRate} Hz")
        println("[info] 声道数   : ${info.channels}")
        println("[info] 位深     : ${info.bitDepth}")
        println("[info] 总帧数   : ${info.totalFrames}")
        println("[info] 时长     : ${info.durationMs} ms")

        println("")
        println("字段语义（见 docs/api/core.md）：")
        println("  bitDepth    无损格式即源位深（16 / 24）；32 保留给 float32 输出（有损格式用）")
        println("  totalFrames -1 表示不可知（例如未写 totalSamples 的 Ogg-FLAC）")
    } catch (e: Audio4CjException) {
        // 走到这里通常意味着「识别出来了，但当前没有解码实现」或「结构损坏」——
        // 异常信息里会写明编码级标识，与 format().codecId 用的是同一套写法。
        println("[info] open() 失败：${e.message}")
        println("")
        println("提示：这**不是**识别失败 —— 探测层已认出具体编码，只是没有解码实现。")
        println("      要读这类文件的标签，请用示例 tags（标签读取不要求容器可解码）。")
    }
    0
}
