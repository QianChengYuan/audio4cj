package audio4cj_examples

import audio4cj.facade.AudioFile
import audio4cj.stream.AsyncFrameStream

/* ============================================================================
 * 示例二：后台解码 + 有界队列背压（AsyncFrameStream）
 *
 * 【与 FrameStream 的区别】
 *   FrameStream 是同步拉取：不调用 next() 就不解码。它天然节流，
 *   但**解码与消费无法并行** —— 消费侧一慢（写盘、重采样、推声卡），
 *   多核就闲置了。
 *   AsyncFrameStream 让解码在后台线程进行，经**有界阻塞队列**交给消费线程：
 *      · 两侧并行 —— 消费慢时解码提前做；
 *      · 队列满则生产者阻塞 —— 这就是**背压**，同时把内存封顶在
 *        「队列容量 × 单块大小」。
 *
 * 【何时该用】消费很快（只统计帧数、求和）→ 用 FrameStream 即可，异步没有收益；
 *             消费较慢 → 用 AsyncFrameStream；要严格控内存 → 把容量调小。
 * ========================================================================== */
func exampleAsync(path: String): Int64 {
    try (f = AudioFile.open(path)) {
        // AsyncFrameStream 实现了 Resource，可直接用于 try-with-resources；
        // close() 会请求取消源流 → **等待后台线程真正退出** → 再关闭源流（幂等）。
        try (s = AsyncFrameStream.start(f.stream(), queueCapacity: 4)) {
            var frames: Int64 = 0
            var chunks: Int64 = 0

            while (let Some(chunk) <- s.next()) {
                chunks += 1
                frames += chunk.frameCount
                // 真实场景里这里可以是编码写出 / 重采样 / 推送设备等耗时处理；
                // 此处只累加，读者可自行替换为耗时操作来观察并行效果。
            }

            println("[async] 分 ${chunks} 块读完，共 ${frames} 帧")
            println("[async] 队列容量 4 —— 解码最多超前 4 块，内存因此有界")
        }
    }
    0
}
