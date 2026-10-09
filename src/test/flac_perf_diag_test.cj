package audio4cj.test

import audio4cj.facade.AudioFile
import std.collection.*
import std.fs.*
import std.time.*

/* ============================================================================
 * FLAC 性能诊断扫描：清单驱动的逐文件计时（**不引入任何插桩**）
 *
 * 【它回答什么问题】
 *   分段计时（`testdata/diag/phase_timing.on` 那套）会改被测代码，且只能回答
 *   "内部哪一段贵"。本轮要的是两个**对外可比**的数，两者都不需要碰解码器内部：
 *     · 地板基准 —— 我们解最轻的内容（静音）与 ffmpeg 解同一份文件差多少；
 *     · 块长扫描 —— 同一段音频、只改 FLAC 块长（1152/2048/4096/4608），
 *       用 t = A + B·N 解出"每帧固定成本 A"与"每采样成本 B"。
 *   因此本文件只做**外层计时**：调用公开 API（`AudioFile.open` + `stream`），
 *   不改任何产品代码、不加时钟、不加计数。
 *
 * 【为什么 best-of-3 取最小值】
 *   耗时噪声是单边的（只会被抢占拖慢、不会变快），最小值是最稳的容量估计 ——
 *   与 `mp3_throughput_test.cj` 的门槛口径一致，便于互相对照。
 *
 * 【为什么清单驱动而不是写死素材】
 *   语料（`eval_work/`、`musics/`）不入库：第三方版权 + 体积两重原因。
 *   清单 `testdata/diag/perf.list` 不存在 ⇒ 本用例打印一行跳过即返回
 *   （常规 `cjpm test` 零开销），与 `dump.list` 的约定完全一致。
 *   清单每行一条：`<源路径>[|<标签>]`，`#` 开头为注释。
 *
 * 【单位口径（本轮统一）】
 *   一律报 **ns / 单个采样值**：除数 = 累计 `buf.samples.size`（交错样本值个数，
 *   即 帧数 × 声道数），并在每行里**显式打印该除数**。此前同一份文档里存在两种
 *   除数（per-channel 采样点 与 交错采样值），差 2 倍，是三次误读的来源 ⇒
 *   本文件把除数写进输出行，读表的人不必再猜。
 *
 * 【运行方式】（`--show-all-output` 必需：测试框架默认捕获用例 stdout）
 *     cjpm test --filter FlacPerfDiagTest --show-all-output --no-color
 * ========================================================================== */

/// 清单路径（相对仓库根 —— `cjpm test` 的工作目录即仓库根）。
let FPD_LIST: String = "testdata/diag/perf.list"

/// 每个文件重复测量的轮数（取最小值）。
let FPD_RUNS: Int64 = 3

/// 清单条目：源路径 + 展示标签。
class FpdJob {
    let src: String
    let label: String

    init(src: String, label: String) {
        this.src = src
        this.label = label
    }
}

/// 读取清单，返回条目列表；文件不存在返回空列表。
private func fpdLoadList(path: String): ArrayList<FpdJob> {
    let jobs = ArrayList<FpdJob>()
    if (!exists(Path(path))) {
        return jobs
    }

    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        let text = String.fromUtf8(buf[0..got])

        for (line in text.lines()) {
            let s = line.trimAscii()
            if (s.isEmpty() || s.startsWith("#")) {
                continue
            }
            let parts = s.split("|")
            let src = parts[0].trimAscii()
            if (src.isEmpty()) {
                continue
            }
            // 标签缺省用源路径 —— 输出行永远可读，不依赖调用方写标签
            let label = if (parts.size >= 2) {
                parts[1].trimAscii()
            } else {
                src
            }
            jobs.add(FpdJob(src, label))
        }
    }

    jobs
}

/// 解码整个文件，返回**交错样本值**个数（0 表示没解出东西）。
///
/// 必须走 `stream()` + `next()`：`readFrames` 内部经 `drain()` 会关掉共享 reader，
/// 只能调用一次；"取到 None 才是正常结束"的语义只有流式接口给得出。
private func fpdDecodeAll(path: String): Int64 {
    var total: Int64 = 0
    try (f = AudioFile.open(path)) {
        let st = f.stream()
        while (true) {
            match (st.next()) {
                case Some(buf) => total += buf.samples.size
                case None => break
            }
        }
        // FrameStream 未实现 Resource，只能手动关闭（关闭它与 AudioFile 共享的 reader，
        // 幂等；f 的 try-with-resources 会再关一次）。
        st.close()
    }
    total
}

/// 测量一个文件并打印一行；返回 true 表示测到了（未测到时不判失败，只标注）。
private func fpdMeasureOne(job: FpdJob): Bool {
    if (!exists(Path(job.src))) {
        println("PERF-SKIP| ${job.label} | 源文件不存在：${job.src}")
        return false
    }

    var rate: Int64 = 0
    var channels: Int64 = 0
    var durMs: Int64 = 0
    var frames: Int64 = 0
    try (f = AudioFile.open(job.src)) {
        let info = f.info()
        rate = info.sampleRate
        channels = info.channels
        durMs = info.durationMs
        frames = info.totalFrames
    }

    var bestSeconds = 1.0e18
    var samples: Int64 = 0
    var run = 0
    while (run < FPD_RUNS) {
        let t0 = MonoTime.now()
        let n = fpdDecodeAll(job.src)
        let dt = Float64((MonoTime.now() - t0).toNanoseconds()) / 1.0e9
        if (n <= 0) {
            println("PERF-FAIL| ${job.label} | 解码得到 0 个样本，测量无意义：${job.src}")
            return false
        }
        samples = n
        if (dt < bestSeconds) {
            bestSeconds = dt
        }
        run += 1
    }

    let audioSeconds = Float64(durMs) / 1000.0
    // 除数固定为**交错样本值个数**（帧数 × 声道数），并打印出来
    let nsPerSample = bestSeconds * 1.0e9 / Float64(samples)
    let realtime = if (audioSeconds > 0.0) {
        audioSeconds / bestSeconds
    } else {
        0.0
    }

    println(
        "PERF| ${job.label} | ${job.src} | 时长 ${audioSeconds}s | ${rate} Hz ${channels} ch | " +
            "声明帧 ${frames} | 除数（交错样本值）${samples} | " +
            "best ${bestSeconds * 1000.0} ms | ${nsPerSample} ns/采样值 | ${realtime} x 实时")
    true
}

@Test
class FlacPerfDiagTest {
    /// 按 `testdata/diag/perf.list` 逐条计时（best-of-3）
    ///
    /// 清单不存在 → 打印跳过并返回；清单里的源文件不存在 → 逐条标注跳过，
    /// **不判失败**（第三方版权素材与中间产物不入库）。
    @TestCase
    func flacPerfScanByManifest() {
        let jobs = fpdLoadList(FPD_LIST)
        if (jobs.isEmpty()) {
            println("跳过（无 ${FPD_LIST} 或无有效条目，未请求性能扫描）：flacPerfScanByManifest")
            return
        }

        println(
            "PERF-BEGIN| 清单 ${jobs.size} 条 | best-of-${FPD_RUNS} | " +
                "除法口径：ns / 单个采样值（除数 = 帧数 × 声道数）")
        var measured: Int64 = 0
        var skipped: Int64 = 0
        for (job in jobs) {
            if (fpdMeasureOne(job)) {
                measured += 1
            } else {
                skipped += 1
            }
        }
        println("PERF-END| 已测 ${measured} 条，跳过 ${skipped} 条（清单 ${jobs.size} 条）")
    }
}
