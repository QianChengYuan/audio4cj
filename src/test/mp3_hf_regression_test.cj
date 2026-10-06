package audio4cj.test

import audio4cj.facade.AudioFile
import std.collection.*
import std.fs.*
import std.math.*

/* ============================================================================
 * MP3 高频完整性回归 —— 钉死"count1 区被整段丢弃"这一类缺陷
 *
 * 【为什么必须有它：包络判据看不见这类损失】
 *   MP3 频谱分两段编码：低频走 `big_values`（大值），**高频走 `count1`**（四元码表，
 *   ±1 的小值）。所以"高频解出来没有"等价于"count1 区跑完了没有"。
 *   而 count1 覆盖的只是 576 条谱线里最高的一段，它占**整体能量**的比例很小 ——
 *   `golden_test` 的 enevelope 模式（长度 + 总能量）对它不敏感（实测：总能量差
 *   < 0.1 dB，而高频已经丢了 7~9 dB）。这类缺陷只能靠**分频段**判据抓。
 *
 * 【真实教训】本库曾有一处移植缺陷：`mp3_huffman.cj` 里 count1 二级查表的下标
 *
 *       idx1 = (leaf >> 3) + (((bc.cache & 0xFFFFFFFF) << 4) >> (32 - (leaf & 3)))
 *
 *   把 32 位掩码写在了左移**之前**，丢掉了参照实现里 `bs_cache` 是 uint32 时才有的
 *   回绕语义：缓存最高 4 位被抬到 bit32..35 并一并取出，下标由 26/27 变成 58，
 *   越界撞上守卫后 **count1 循环整体 break** —— 该 granule 高频谱线再未被写入（保持 0）。
 *   端到端表现就是"8–16 kHz 比参照低 7~9 dB"，且低码率更明显（count1 占比更大）。
 *
 * 【判据：与 ffmpeg 基准比"高频能量"，容差 0.5 dB】
 *   高频能量用**差分算子**定义，不用 FFT：
 *     · 一阶差分 (1 − z⁻¹)：+6 dB/oct 高通，重心在最高八度；
 *     · 二阶差分 (1 − z⁻¹)²：+12 dB/oct 高通，更聚焦于顶部。
 *   这样选是**确定性**与**零依赖**：不引 FFT/窗/分箱，方差远小于 0.1 dB，
 *   且两侧跑**同一个估计器**，其差只反映"解码结果本身"。
 *   0.5 dB 的容差覆盖两类**合法**差异：本库保留 Info 帧与末尾填充带来的长度差
 *   （能量被稀释 ~0.1 dB）与两套解码器的量化细节。
 *
 * 【素材】`testdata/mp3/mp3_noise_64k_mono.mp3`（白噪声 + 每 0.25 s 一个瞬变，
 *   44.1 kHz 单声道 64 kbps 共 2 秒）—— 低码率 + 噪声/瞬变正是 count1 占比最大、
 *   该缺陷最容易显形的内容。基准 `testdata/golden/mp3_noise_64k_mono.f32le`
 *   由 `scripts/gen_testdata.*` 用 ffmpeg 解出（与其它 golden 同一套工具链）。
 * ========================================================================== */

/// 判据容差（dB）。含义见文件头：覆盖"Info 帧/填充造成的长度差"与量化细节两类合法差异。
let MH_TOL_DB: Float64 = 0.5
private let MH_MP3: String = "testdata/mp3/mp3_noise_64k_mono.mp3"
private let MH_GOLDEN: String = "mp3_noise_64k_mono.f32le"

/// 把整个 MP3 解成 f32 交错样本。
///
/// 必须走 `stream()` + `next()`：`readFrames` 内部经 `drain()` 会关掉与 `AudioFile`
/// 共享的 reader，因此**只能调用一次**；全量读取要用"取到 None 才算结束"的流式接口。
private func mhDecodeAll(path: String): Array<Float32> {
    let out = ArrayList<Float32>()
    try (f = AudioFile.open(path)) {
        let st = f.stream()
        while (true) {
            match (st.next()) {
                case Some(buf) =>
                    var i: Int64 = 0
                    while (i < buf.samples.size) {
                        out.add(buf.samples[i])
                        i += 1
                    }
                case None => break
            }
        }
        st.close()
    }
    out.toArray()
}

/// 高频能量（dB）：k 阶差分的均方。
///
/// `order = 1` 是一阶差分（+6 dB/oct 高通），`order = 2` 是二阶差分（+12 dB/oct）。
/// 差分把直流与低频压掉、把最高八度放大，因此"频谱顶部被整段写零"会让它骤降，
/// 而它在整体能量里的份额小到几乎不影响总能量 —— 这正是要用它的原因。
private func mhDiffEnergyDb(samples: Array<Float32>, order: Int64): Float64 {
    if (samples.size <= order) {
        return -300.0
    }

    var acc = 0.0
    var i = order
    if (order == 0) {
        // 0 阶 = 不做差分（整体能量），只作对照量打印，不参与判据
        while (i < samples.size) {
            let v = Float64(samples[i])
            acc = acc + v * v
            i += 1
        }
        let ms = acc / Float64(samples.size)
        if (ms <= 0.0) {
            return -300.0
        }
        return 10.0 * log10(ms)
    }
    while (i < samples.size) {
        let cur = Float64(samples[i])
        var d = 0.0
        if (order == 1) {
            d = cur - Float64(samples[i - 1])
        } else {
            d = cur - 2.0 * Float64(samples[i - 1]) + Float64(samples[i - 2])
        }
        acc = acc + d * d
        i += 1
    }

    let mean = acc / Float64(samples.size - order)
    // 全零（或近乎全零）时返回一个"极低"的有限值：既要能参与比较，
    // 又不能让 log10(0) 产生 -Inf 把差值算成 NaN。
    if (mean <= 0.0) {
        return -300.0
    }
    10.0 * log10(mean)
}

/// 本库解码 vs ffmpeg 基准：同一估计器、两条 PCM，比较分频段能量。
private func mhCompare(name: String, ours: Array<Float32>, ref: Array<Float32>, order: Int64, bad: ArrayList<String>): Float64 {
    let a = mhDiffEnergyDb(ours, order)
    let b = mhDiffEnergyDb(ref, order)
    let delta = a - b
    if (abs(delta) > MH_TOL_DB) {
        bad.add("${name}：本库 ${a} dB vs 基准 ${b} dB（差 ${delta}，容差 ±${MH_TOL_DB}）")
    }
    delta
}

@Test
class Mp3HighFrequencyRegressionTest {
    /// 【核心回归】低码率"噪声+瞬变"片段的分频段能量必须与 ffmpeg 基准一致。
    ///
    /// 修复前实测：一阶差分（≈最高八度权重）差 −11 dB 量级、二阶差分差更多；
    /// 修复后两者都在 ±0.1 dB 内（容差因此可以取到 0.5 dB）。
    @TestCase
    func lowBitrateHighFrequencyMatchesGolden() {
        if (gsSkipIfNoFixtures("lowBitrateHighFrequencyMatchesGolden")) {
            return
        }

        let ours = mhDecodeAll(MH_MP3)
        let ref = gsLoadGolden(MH_GOLDEN)

        // 长度：本库保留 Info 帧与末尾填充，**合法地**比 ffmpeg 多若干帧（约 2.5%），
        // 这里只做粗查，防止"解出个空流却靠 0 dB 差异通过"。
        let ratio = Float64(ours.size) / Float64(ref.size)
        @Assert(ratio > 0.9 && ratio < 1.1)

        let bad = ArrayList<String>()
        let hf = mhCompare("高频（一阶差分）", ours, ref, 1, bad)
        let vhf = mhCompare("更高频（二阶差分）", ours, ref, 2, bad)
        let total = mhCompare("整体能量（对照，非判据）", ours, ref, 0, ArrayList<String>())
        if (!bad.isEmpty()) {
            @Fail(String.join(bad.toArray(), delimiter: " | "))
        }

        println("分频段能量：一阶差分 ${hf} dB、二阶差分 ${vhf} dB、" + "整体 ${total} dB（均相对基准）")
    }

    /// 【判据自检】把基准做一次 2 抽头低通（相邻平均）后再算高频能量，
    /// 必须显著下降 —— 否则这套判据在"高频被整段丢掉"时也不会报警。
    ///
    /// 没有这一条，日后有人把判据换成"总能量"之类的不敏感量时，
    /// 回归测试会**静默失效**，而它恰恰是用来防这种沉默损失的。
    @TestCase
    func highFrequencyMetricIsSensitive() {
        if (gsSkipIfNoFixtures("highFrequencyMetricIsSensitive")) {
            return
        }

        let ref = gsLoadGolden(MH_GOLDEN)
        // 低通用 **3 级级联** 的 2 抽头平均（等效三角 4 抽头）：
        // 单级对最高频只削约 6 dB，而 64 kbps 编码本身已把 11 kHz 以上裁掉，
        // 单级降幅不足以体现灵敏度（实测 < 4 dB）；级联 3 级后降幅与真实缺陷
        // 的量级相当（真实缺陷实测 8.6~10.0 dB）。
        var lp = Array<Float32>(ref.size, repeat: 0.0)
        var i: Int64 = 0
        while (i < ref.size) {
            lp[i] = ref[i]
            i += 1
        }
        var stage = 0
        while (stage < 3) {
            let nxt = Array<Float32>(ref.size, repeat: 0.0)
            nxt[0] = lp[0]
            var k: Int64 = 1
            while (k < ref.size) {
                nxt[k] = (lp[k] + lp[k - 1]) * 0.5
                k += 1
            }
            lp = nxt
            stage += 1
        }

        let dropHf = mhDiffEnergyDb(ref, 1) - mhDiffEnergyDb(lp, 1)
        let dropVhf = mhDiffEnergyDb(ref, 2) - mhDiffEnergyDb(lp, 2)
        // 阈值取 4 dB（真实缺陷 8.6~10.0 dB）：只要判据仍能感到"高频被削"就够报警
        @Assert(dropHf > 4.0)
        @Assert(dropVhf > 4.0)
        println("判据灵敏度：2 抽头低通后一阶差分降 ${dropHf} dB、" + "二阶差分降 ${dropVhf} dB")
    }
}
