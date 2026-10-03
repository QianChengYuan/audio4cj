package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.drlibs.DrLibsDecoder
import audio4cj.drlibs.DrLibsFormat

/* ============================================================================
 * 解码吞吐基准（cjpm bench）
 *
 * 【为什么需要它】
 *   开发文档 M7（原生化）把启动条件定为「FFI 开销占比 > 30%，或某平台无法
 *   分发 C 动态库」。后者已被实测证实（中心仓制品包不含任何二进制文件，
 *   见官方《制品包发布》文档与 bundle 产包检查）。
 *
 *   但前者**指标本身选错了**：本项目的 FFI 粒度是「每块 16384 帧一次调用」，
 *   调用开销摊到每帧可以忽略。真正的成本是解码算法的吞吐 —— dr_libs 是
 *   高度优化的 C，纯仓颉实现要达到什么水平才不算退步，需要有基线才知道。
 *
 *   因此本文件测的是两件事：
 *     (1) 端到端解码吞吐 —— 纯仓颉 FLAC 实现的**性能验收线**；
 *     (2) 块大小对吞吐的影响 —— 若吞吐随块大小显著变化，说明 FFI 调用开销
 *         确实是成本；若几乎平缓，说明成本全在算法本身，原生化就只剩
 *         「值不值得重写算法」这一个问题（而不是"FFI 太慢"）。
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
private let BD_MP3: String = "testdata/mp3/mp3_cbr_128k.mp3"

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

/// 绕开上层、以指定块大小直接经 FFI 读取整个 FLAC 文件，返回累计帧数。
///
/// 用途是**块大小敏感性**测量：块越小，FFI 调用次数越多，
/// 单帧摊销的跨语言调用开销越大。若总耗时随块变小而明显上升，
/// 就说明调用开销确实存在；若基本平缓，说明它相对解码算法可以忽略。
private func bdFlacScanChunks(frames: Int64): Int64 {
    let decoder = DrLibsDecoder(DrLibsFormat.Flac, BD_FLAC_16)
    let channels = decoder.channels()

    // 字节缓冲按 f32 * 声道数 计算，与 format/flac.cj 的分块策略一致
    let buf = Array<UInt8>(frames * channels * 4, repeat: 0)

    var total: Int64 = 0
    var got: Int64 = 1
    while (got > 0) {
        got = decoder.readF32Into(buf, frames)
        total += got
    }

    decoder.close()
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

    @Bench
    func mp3DecodeAll() {
        BD_SINK += bdDecodeAll(BD_MP3)
    }

    // ------------------------------------------------------------------
    // 块大小敏感性：同一文件、不同块大小
    //
    // 256 帧与 16384 帧的调用次数相差 64 倍。若"FFI 调用开销占比"真有
    // 开发文档所设的 30%，这里的耗时差异会非常显眼。
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
            (BD_FLAC_24, "FLAC 24-bit 立体声"),
            (BD_MP3, "MP3 CBR 128k")
        ]
        for ((path, name) in fixtures) {
            let frames = bdDecodeAll(path)
            if (frames <= 0) {
                @Fail("基准素材不可解码（${name}）：${path}")
            }
        }
    }
}
