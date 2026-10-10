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
 *     · 440 Hz 正弦（`mp3_cbr_128k.mp3`，1 秒）：文件太短，量到的其实是
 *       "每文件固定开销 + 启动噪声"，且频谱稀疏、count1 区几乎全零；
 *     · 20 秒合成混合内容（粉噪声 + 每 0.4 秒一个瞬变 + 多音）：**最坏情形**
 *       （count1 区被填满，Huffman/反量化每帧的码字数远高于音乐）。
 *   因此**门槛挂在最坏情形素材上**：它守住了，真实内容必然更好。真实音乐素材无法入库
 *   （第三方版权），合成素材可复现、无版权，这是能入库的唯一正确选择。
 *
 * 【门槛取值：以本文件下方的常量为唯一真相，且以**最低声明 SDK** 为基准】
 *   `MP_RED_LINE` 是硬断言，`MP_TARGET` **只报告、不判定**（达到后再刷新红线）。
 *   红线的基准是 `cjpm.toml` 的 `cjc-version`（**最低支持**的 SDK），不是开发机上更快的那个：
 *   同一素材、同一份代码，实测随工具链版本相差约 1.6 倍 ——
 *     · SDK **1.1.0**：320.8× / 222.2× / 286.8×（三次，各取 best-of-3）
 *     · SDK **1.2.0**：456.9× / 462.1× / 456.2×（约 460×）
 *   故红线取 **150×**（低于 1.1.0 实测最小值 222×，留 ~32% 余量吸收机器抖动），目标 800×。
 *   红线必须落在**当前实测之下**才有意义：取满实录值会因抖动变红，那等于
 *   "写了个必然失败的断言"，比没有门槛更糟。
 *   历史沿革：`2.5× / 4.0× / 6.0×` 与"目标 12×"是**未设 `-O`（`-O0`）**时的旧口径；
 *   补 `-O2` 后曾定为 250×（当时只按 1.2.0 校准），现按上表改为 **150×**。
 *   引用本门槛时请以常量为准，不要复述历史数字。
 *
 * 【为什么 best-of-3 取最小值】
 *   耗时测量的噪声是**单边**的（只会被抢占拖慢、不会变快），因此最小值是容量最稳
 *   的估计；用均值会把 CI 抖动算成性能退化。
 * ========================================================================== */

/// 素材时长（秒）。改素材必须同步改这里，否则实时倍速会算错。
let MP_AUDIO_SECONDS: Float64 = 20.0

/// 红线：最坏情形素材上的实时倍速下限（硬断言）。
/// **以最低声明 SDK（`cjpm.toml` 的 `cjc-version`）的实测为基准**：
///   SDK 1.1.0 实测 320.8× / 222.2× / 286.8×；SDK 1.2.0 实测约 460×。
///   取 **150×** —— 低于 1.1.0 最小值 222× 留约 32% 余量，既不误报又守得住明显退化。
/// 口径沿革（每一版都写在其时实测之下）：`-O0` 时代 2.5× -> 4.0× -> 6.0×；
/// 补 `-O2` 后 250×（仅按 1.2.0 校准）；现按最低声明 SDK 改为 150×。
let MP_RED_LINE: Float64 = 150.0

/// 目标：达到后把红线提升上去（当前只报告、不判定）。
/// 这是"值得投入"的方向线，不是门槛 —— 未达到不产生红灯。
/// （`-O0` 时代的目标为 5× / 12×，同样已随 `-O2` 口径作废。）
let MP_TARGET: Float64 = 800.0
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
