package audio4cj_examples

import audio4cj.facade.AudioFile
import audio4cj.core.Audio4CjException

/* ============================================================================
 * 示例四：基本信息
 *
 * 【本库不对外暴露探测 API（当前设计如此，见文末）】
 *   「探测」发生在 `AudioFile.open()` 内部（读文件头 512 字节 → 判别容器与
 *   子编码 → 选择实现），但**结果不通过公开 API 暴露**：
 *     · probe 层的 `detectFile` / `ProbeResult` 是 `protected`
 *     · 各 reader 产出的 `Track`（含 `codecId`）只在包内流转
 *   `AudioInfo` 提供的只有采样率、声道、位深、时长、总帧数。
 *
 *   因此，使用者能直接读到的格式信息仅限于**失败时** ——
 *   `FormatNotSupportedException` 的信息里会写明具体编码（如 `ogg/opus`）。
 * ========================================================================== */
func exampleInfo(path: String): Int64 {
    try {
        let f = AudioFile.open(path)
        try {
            let info = f.info()

            println("[info] 采样率  : ${info.sampleRate} Hz")
            println("[info] 声道数  : ${info.channels}")
            println("[info] 位深    : ${info.bitDepth}")
            println("[info] 总帧数  : ${info.totalFrames}")
            println("[info] 时长    : ${info.durationMs} ms")
        } finally {
            f.close()
        }

        println("")
        println("字段语义（见 docs/api/core.md）：")
        println("  bitDepth    MP3 恒为 32 —— 有损格式无源位深，32 表示输出为 float32")
        println("  totalFrames -1 表示不可知（例如未写 totalSamples 的 Ogg-FLAC）")
        println("")
        println("注意：本库当前**不暴露**\"这是什么容器/编码\"的查询 ——")
        println("      容器与子编码只在 open() 内部判别，仅当不受支持时才通过")
        println("      FormatNotSupportedException 的信息告知使用者（如 ogg/opus）。")
    } catch (e: Audio4CjException) {
        // 走到这里通常意味着「容器/编码不受支持」或「结构损坏」——
        // 此时异常信息里会写明具体编码。
        println("[info] open() 失败：${e.message}")
        println("")
        println("提示：本例失败的**信息本身**就是本库对外提供格式识别的方式之一；")
        println("      另外，只读标签（示例 tags）不要求容器可解码，通常仍可用。")
    }
    0
}
