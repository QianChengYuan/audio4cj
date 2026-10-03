package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.format.PureFlacKernel

/* ============================================================================
 * 解码吞吐基准（cjpm bench）
 *
 * 【为什么需要它】
 *   纯仓颉内核替换掉 dr_libs 之后，"性能退步了吗"就成了必须能回答的问题。
 *   （原先的启动条件里有一条「FFI 开销占比 > 30%」——那条指标本身选错了：
 *   本项目的 FFI 粒度是「每块 16384 帧一次调用」，调用开销摊到每帧可以忽略，
 *   真正的成本在解码算法本身。Tier 4 移除 C 依赖后，这条争议随之消失。）
 *
 *   因此本文件只回答两件事：
 *     (1) 端到端解码吞吐 —— 纯仓颉实现的**性能验收线**，也是后续优化的对照；
 *     (2) 块大小对吞吐的影响 —— 反映**窗口回填**（未消费数据前移 + 从源补足）
 *         的摊薄成本：块越小回填越频繁。若耗时随块变小而明显上升，
 *         说明回填值得优化；若基本平缓，说明成本全在帧解码算法本身。
 *
 * 【与功能测试的分工】
 *   本文件的 @Bench **只测性能、不做正确性断言**；正确性由 golden 基线与
 *   各格式解码测试负责。唯一的例外是下面那个健全性 @TestCase —— 它只为
 *   防止"素材缺失导致基准测了个寂寞"。
 *
 * 【如何运行】
 *   cjpm bench --filter "BenchDecode*.*"
 *   cjpm bench --filter "BenchDecode*.*" --report-path bench_report --report-format csv
 *
 *   首次记录基线后，后续用 --baseline-path bench_report 做性能回归对比。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 素材：全部来自仓库内 testdata/，不依赖外部工具或网络
// ---------------------------------------------------------------------------
private let BD_WAV_16: String = "testdata/wav/wav_s16_44100_stereo.wav"
private let BD_FLAC_16: String = "testdata/flac/flac_s16_44100_stereo.flac"
private let BD_FLAC_24: String = "testdata/flac/flac_s24_44100_stereo.flac"
// 这里曾有 BD_MP3 及其基准。MP3 解码已移出本版本范围（它依赖 C 库 dr_mp3，
// 而带 C 的制品包在中心仓审核中被退回），故相应基准与健全性断言一并移除。

/// 累加器：让基准体的计算结果"有去处"，避免被优化掉。
///
/// 基准不做断言，故只累加、不校验；也正是因此它必须是可变的文件级变量，
/// 否则编译器完全有理由把整个解码过程优化成空操作。
private var BD_SINK: Int64 = 0

/// 流式解码整个文件，返回累计帧数。
///
/// 走的是用户实际使用的路径（AudioFile.open + stream + next），
/// 因此测得的是**端到端吞吐**，含 demuxer、位深转换与分块开销。
private func bdDecodeAll(path: String): Int64 {
    var frames: Int64 = 0
    try (f = AudioFile.open(path)) {
        // 注意：FrameStream 未实现 Resource，不能写进 try-with-resources，
        // 只能手动关闭（关闭它会连带关闭底层 reader，与 AudioFile 共享）。
        let s = f.stream()
        while (let Some(chunk) <- s.next()) {
            frames += chunk.frameCount
        }
        s.close()
    }
    frames
}

/// 绕开上层、以指定块大小直接调用**纯仓颉内核**读整个 FLAC 文件，返回累计帧数。
///
/// 用途是**块大小敏感性**测量：块越小，窗口回填（未消费数据前移 + 从源补足）
/// 的次数越多，单帧摊销的拷贝开销越大。若总耗时随块变小而明显上升，
/// 说明回填开销值得优化；若基本平缓，说明成本全在帧解码算法本身。
private func bdFlacScanChunks(frames: Int64): Int64 {
    let kernel = PureFlacKernel(BD_FLAC_16, false)
    let channels = kernel.channels()

    // 字节缓冲按 f32 * 声道数 计算，与 format/flac.cj 的分块策略一致
    let buf = Array<UInt8>(frames * channels * 4, repeat: 0)

    var total: Int64 = 0
    var got: Int64 = 1
    while (got > 0) {
        got = kernel.readF32Into(buf, frames)
        total += got
    }

    kernel.close()
    total
}

@Test
class BenchDecode {
    // ------------------------------------------------------------------
    // 端到端吞吐：三种格式的当前实现
    //
    // WAV 走的是**纯仓颉**路径（其"解码"即位深转换），因此它的数字同时
    // 充当"纯仓颉实现能达到什么吞吐"的参照系。
    // ------------------------------------------------------------------

    @Bench
    func wavDecodeAll() {
        BD_SINK += bdDecodeAll(BD_WAV_16)
    }

    @Bench
    func flac16DecodeAll() {
        BD_SINK += bdDecodeAll(BD_FLAC_16)
    }

    @Bench
    func flac24DecodeAll() {
        BD_SINK += bdDecodeAll(BD_FLAC_24)
    }

    // ------------------------------------------------------------------
    // 块大小敏感性：同一文件、不同块大小
    //
    // 256 帧与 16384 帧的回填次数相差 64 倍，因此这里的耗时差异直接反映
    // 窗口回填（前移 + 补足）的摊薄开销有多大。
    // ------------------------------------------------------------------

    @Bench[size in [ 256, 1024, 4096, 16384 ]]
    func flacBlockSizeScan(size: Int64) {
        BD_SINK += bdFlacScanChunks(size)
    }

    // ------------------------------------------------------------------
    // 健全性守卫：基准不做断言，但素材缺失会让所有数字失去意义
    // ------------------------------------------------------------------
    @TestCase
    func fixturesAreDecodable() {
        let fixtures = [
            (BD_WAV_16, "WAV 16-bit 立体声"),
            (BD_FLAC_16, "FLAC 16-bit 立体声"),
            (BD_FLAC_24, "FLAC 24-bit 立体声")
        ]
        for ((path, name) in fixtures) {
            let frames = bdDecodeAll(path)
            if (frames <= 0) {
                @Fail("基准素材不可解码（${name}）：${path}")
            }
        }
    }
}
