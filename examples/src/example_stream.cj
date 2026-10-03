package audio4cj_examples

import audio4cj.facade.AudioFile

/* ============================================================================
 * 示例一：流式消费（FrameStream）—— 本库的主 API
 *
 * 【为什么它才是主 API】
 *   f32 交错 PCM 是 4 字节/样本，44.1 kHz 立体声下 1 小时约 1.27 GB。
 *   `readAll()` 因此只能算便捷 API；`FrameStream` 每次只交付一块，
 *   内存占用**与音频时长无关**。
 *
 * 【循环终止条件就是 `next()` 返回 None】
 *   本库的契约：`None` 只表示"结束"，**绝不用于表示错误** ——
 *   解码失败会抛异常。所以可以放心把 None 当循环条件。
 * ========================================================================== */
func exampleStream(path: String): Int64 {
    try (f = AudioFile.open(path)) {
        // 注意：必须在拿到流之前取 info —— 见文件尾的说明
        let info = f.info()
        println("[stream] ${info.sampleRate} Hz | ${info.channels} 声道 | 位深 ${info.bitDepth}")

        let s = f.stream()
        var frames: Int64 = 0
        var chunks: Int64 = 0
        var peak: Float32 = 0.0

        while (let Some(chunk) <- s.next()) {
            chunks += 1
            frames += chunk.frameCount
            for (v in chunk.samples) {
                let a = if (v < 0.0) {
                    -v
                } else {
                    v
                }
                if (a > peak) {
                    peak = a
                }
            }
        }

        println("[stream] 分 ${chunks} 块读完，共 ${frames} 帧")
        println("[stream] 峰值 |sample| = ${peak}")
        println("[stream] 全程内存占用与音频时长无关（只保留当前这一块）")
    }
    // 离开作用域自动 close()：AudioFile 实现了 Resource
    0
}

/* 一条容易踩的契约（docs/api/stream.md §3.3）：
 *   FrameStream.close() 会连带关闭底层 reader，而它与 AudioFile 共享同一个 reader。
 *   因此在关闭流之后，f.info() 之类的数据方法会抛 ClosedResourceException。
 *   实践建议：用 try-with-resources 管 AudioFile 即可，不必手动关流；
 *   需要重新遍历同一文件时，请重新 AudioFile.open()，而不要复用实例。
 */
