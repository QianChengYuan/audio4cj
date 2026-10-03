package audio4cj_play

import audio4cj.facade.AudioFile
import audio4cj.pcm.*
import winsound4cj.*

/* ============================================================================
 * 解码 → 播放：audio4cj（解码）+ winsound4cj（发声）
 *
 * 用法：
 *     cjpm run -- <音频文件>
 *
 * 【这条链路能做什么、不能做什么 —— 请先读这一段】
 *
 *   winsound4cj 封装的是 Win32 `PlaySound`，其 `SND_MEMORY` 语义是
 *   **一次性把一整段 WAV 交给系统**。因此：
 *
 *     ✅ 适合提示音、几秒到几十秒的片段；
 *     ❌ 不适合长音频 —— 必须先把整段解码结果放进内存。
 *
 *   1 小时 44.1kHz 立体声约占 300 MB（16 位）。这恰恰说明本库为何把
 *   `FrameStream` 当主 API：**PlaySound 用不上流式的优势**。
 *
 *   真正与 FrameStream 匹配的是 Win32 的 waveOut 系列（打开设备 → 反复
 *   waveOutWrite 小块 → 边解码边播、内存恒定、支持任意时长），
 *   而 winsound4cj 当前只封装了 PlaySound。
 *
 * 【为什么用 readAll 而不是 stream】
 *   正因为上面那条：PlaySound 要的是"整段"，用流式也得自己攒起来 ——
 *   不如直接说明这个取舍，而不是假装流式可用。
 * ========================================================================== */

/// `readAll()` 的默认安全上限（帧）。超过它会被截断，长音频应当改用 FrameStream。
let READ_ALL_CAP_FRAMES: Int64 = 10_000_000

main(args: Array<String>): Int64 {
    if (args.size < 1) {
        println("用法：cjpm run -- <音频文件>")
        return 2
    }
    let path = args[0]

    var buffer: ?AudioBuffer = None
    try (f = AudioFile.open(path)) {
        let fmt = f.format()
        let info = f.info()

        println("格式：${fmt.codecId}（${fmt.mimeType}）")
        println("参数：${info.sampleRate} Hz / ${info.channels} 声道 / 位深 ${info.bitDepth}")
        println("时长：${info.durationMs} ms")

        // 用时长反推大致帧数，提前提醒截断风险（readAll 有安全上限）
        if (info.sampleRate > 0 && info.durationMs > 0) {
            let expected = info.sampleRate * info.durationMs / 1000
            if (expected > READ_ALL_CAP_FRAMES) {
                println(
                    "⚠ 该文件约 ${expected} 帧，超过 readAll 的默认上限 " +
                        "${READ_ALL_CAP_FRAMES}，播放会被截断（长音频请改用 FrameStream，" +
                        "并换用支持流式的发声接口）")
            }
        }

        // PlaySound 需要整段数据，故这里一次性解码（见文件头说明）
        buffer = f.readAll()
    }

    match (buffer) {
        case Some(buf) =>
            let wav = wavBytes(buf, bitsPerSample: 16)
            println("")
            println("已打包 WAV：${buf.frameCount} 帧 / ${wav.size / 1024} KB")
            println("（整段驻留内存 —— 这是 PlaySound 的固有要求，不是本库的选择）")
            println("开始播放（同步接口，播完返回）...")

            playWavData(wav)

            println("播放结束。")
            0
        case None =>
            println("解码失败：未取到音频数据")
            1
    }
}
