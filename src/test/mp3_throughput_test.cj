package audio4cj.test

import audio4cj.facade.AudioFile
import std.collection.*
import std.fs.*
import std.time.*

/* ============================================================================
 * MP3 吞吐门槛 —— 让"慢"变成红/绿，而不是感觉
 *
 * 【为什么门槛必须绑素材口径】
 *   同一实现在不同内容上的实时倍速相差数倍，因此"≥ N× 实时"离开素材就没有意义：
 *     · 440 Hz 正弦（`mp3_cbr_128k.mp3`，1 秒）：4.3× —— 频谱稀疏、count1 区几乎
 *       全零，而且文件太短，量到的其实是"每文件固定开销 + 启动噪声"；
 *     · 真实音乐（30 秒）：8.8×（还含写出 10.6 MB f32le 的 IO）；
 *     · 20 秒合成混合内容（粉噪声 + 每 0.4 秒一个瞬变 + 多音）：**3.3×**。
 *   噪声是最坏情形：count1 区被填满，Huffman/反量化每帧的码字数远高于音乐，
 *   而音乐因编码器更省比特反而更轻。因此**门槛挂在最坏情形素材上**：
 *   它守住了，真实内容必然更好。真实音乐素材无法入库（第三方版权），
 *   合成素材可复现、无版权，这是能入库的唯一正确选择。
 *
 * 【为什么取 2.5×，而不是 6× / 10×】
 *   红线必须落在**当前实测之下**才有意义：最坏情形实测 3.3×，取 2.5× 留约 25%
 *   余量吸收机器抖动。10× 在本素材上会当场变红 —— 那是"写了个必然失败的断言"，
 *   比没有门槛更糟。换算参照：本素材 3.3× 对应真实音乐约 8.8×，所以
 *   `MP_TARGET = 5×`（本素材）大体相当于"真实音乐 ≥ 13×"，是"值得投入"的方向线，
 *   **先作报告项、不做硬断言**，等真达到再把它提升成红线。
 *
 * 【为什么 best-of-3 取最小值】
 *   耗时测量的噪声是**单边**的（只会被抢占拖慢、不会变快），因此最小值是容量最稳
 *   的估计；用均值会把 CI 抖动算成性能退化。
 * ========================================================================== */

/// 素材时长（秒）。改素材必须同步改这里，否则实时倍速会算错。
let MP_AUDIO_SECONDS: Float64 = 20.0

/// 红线：最坏情形素材上的实时倍速下限（硬断言）。
let MP_RED_LINE: Float64 = 2.5

/// 目标：达到后把红线提升上去（当前只报告、不判定）。
let MP_TARGET: Float64 = 5.0
private let MP_FIXTURE: String = "testdata/mp3/mp3_mix_128k_20s.mp3"

/// 把整个 MP3 解成 f32 交错样本，并返回样本总数（用于防空解）。
///
/// 走 `stream()` + `next()`：`readFrames` 内部经 `drain()` 会关掉共享 reader，
/// 只能调用一次；全量解码必须用"取到 None 才算结束"的流式接口。
private func mpDecodeAllCount(path: String): Int64 {
    var total: Int64 = 0
    try (f = AudioFile.open(path)) {
        let st = f.stream()
        while (true) {
            match (st.next()) {
                case Some(buf) => total += buf.samples.size
                case None => break
            }
        }
        st.close()
    }
    total
}

@Test
class Mp3ThroughputTest {
    /// 最坏情形素材（20 秒混合内容）上的解码吞吐必须守住红线。
    @TestCase
    func decodeThroughputMeetsRedLine() {
        if (gsSkipIfNoFixtures("decodeThroughputMeetsRedLine")) {
            return
        }

        var bestSeconds = 1.0e18
        var frames: Int64 = 0
        var run = 0
        while (run < 3) {
            let t0 = MonoTime.now()
            let n = mpDecodeAllCount(MP_FIXTURE)
            let dt = Float64((MonoTime.now() - t0).toNanoseconds()) / 1.0e9
            if (n <= 0) {
                @Fail("解码 ${MP_FIXTURE} 得到 0 个样本：门槛失去意义")
            }
            frames = n
            if (dt < bestSeconds) {
                bestSeconds = dt
            }
            run += 1
        }

        let realtime = MP_AUDIO_SECONDS / bestSeconds
        println(
            "解码吞吐：${MP_FIXTURE} ${MP_AUDIO_SECONDS}s / ${bestSeconds}s = " +
                "${realtime}x 实时（${frames} 样本，best-of-3）" + "；红线 ${MP_RED_LINE}x，目标 ${MP_TARGET}x")
        @Assert(realtime >= MP_RED_LINE)
    }
}
