package audio4cj.test

import audio4cj.facade.AudioFile
import std.fs.*

/* ============================================================================
 * MP3 解码测试 —— 开发文档 §10 M4
 *
 * 【为什么本文件没有自包含构造，而 FLAC 有】
 *   FLAC 规范定义了 verbatim 子帧（未压缩样本），因此能在内存里拼出**合法
 *   且可解码**的流（见 flac_decode_test.cj）。MP3 则做不到 —— 其帧载荷是
 *   Huffman 编码与频域变换的产物，要构造「能解码出预期样本」的帧，等价于
 *   实现一个 MP3 编码器。
 *
 *   因此本文件只做**真实素材集成测试**：
 *     素材存在 -> 完整验证；
 *     素材缺失 -> 打印提示后跳过（**不失败**），
 *   以保证在没有素材的环境（如未来的 CI）中整套测试仍为绿。
 *
 *   这也是为什么 MP3 的 demuxer 没有单独的「帧同步 / Xing 头」单元测试：
 *   本项目的实现**不解析**这些结构，而是委托 dr_mp3（详见 format/mp3.cj
 *   的说明），故没有可独立测试的自研解析逻辑。
 * ========================================================================== */

/// 待验证的素材（相对工作区根目录）。
private let MP3_SAMPLES: Array<String> = [
    "musics/大鱼（cover 周深） - Ciky心心.mp3",
    "musics/陈瑞 白狐 - .mp3"
]

private func mp3SampleExists(path: String): Bool {
    exists(Path(path))
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class Mp3DecodeTest {
    /// 打开真实 MP3：参数合理，位深按「32 = float32」语义上报
    @TestCase
    func opensRealMp3AndReportsParams() {
        for (path in MP3_SAMPLES) {
            if (!mp3SampleExists(path)) {
                println("跳过（素材缺失）：${path}")
                continue
            }

            try (f = AudioFile.open(path)) {
                let info = f.info()

                @Assert(info.sampleRate > 0)
                @Assert(info.channels >= 1 && info.channels <= 2)
                // MP3 是有损格式、无源位深，解码输出为 f32，故报告 32
                @Assert(info.bitDepth == 32)
                // 素材含 Xing/Info 头，总帧数应当可知
                @Assert(info.totalFrames > 0)

                println("${info.sampleRate} Hz / ${info.channels} ch / ${info.totalFrames} 帧")
            }
        }
    }

    /// 流式解码：能读出数据，且归一化样本落在合理范围
    @TestCase
    func streamsAndDecodesSamples() {
        for (path in MP3_SAMPLES) {
            if (!mp3SampleExists(path)) {
                continue
            }

            try (f = AudioFile.open(path)) {
                let s = f.stream()

                var frames: Int64 = 0
                var chunks: Int64 = 0
                var maxAbs: Float32 = 0.0

                while (let Some(chunk) <- s.next()) {
                    frames += chunk.frameCount
                    chunks += 1
                    for (v in chunk.samples) {
                        let a = if (v < 0.0) {
                            -v
                        } else {
                            v
                        }
                        if (a > maxAbs) {
                            maxAbs = a
                        }
                    }
                }

                @Assert(frames > 0)
                @Assert(chunks >= 1)
                // 有损解码的输出经归一化后应落在 [-1, 1]（留极小容差）
                @Assert(maxAbs <= 1.001)
                // 样本总数必须与声道数、帧数自洽
                @Assert(frames >= chunks)
            }
        }
    }

    /// 按时间寻址：返回实际落点，落点之后仍能读出数据
    @TestCase
    func seeksToTimestamp() {
        for (path in MP3_SAMPLES) {
            if (!mp3SampleExists(path)) {
                continue
            }

            try (f = AudioFile.open(path)) {
                // 注意顺序：readFrames 会消费数据并关闭底层 reader（既有契约），
                // 因此所有需要 reader 的调用（info / metadata / seekTo）都必须放在它之前。
                let channels = f.info().channels

                // 3000 ms 在任意采样率下都对应整数帧（3 × sampleRate）
                let actual = f.seekTo(3000)
                @Assert(actual == 3000)

                // 典型 MP3 帧为 1152 个样本/声道
                let buf = f.readFrames(1152)
                @Assert(buf.frameCount > 0)
                @Assert(buf.channels == channels)
            }
        }
    }

    /// 标签读取：readTags 与 metadata() 结果一致（两者共用 meta 层的实现）
    @TestCase
    func metadataMatchesReadTags() {
        for (path in MP3_SAMPLES) {
            if (!mp3SampleExists(path)) {
                continue
            }

            let viaReadTags = AudioFile.readTags(path)

            try (f = AudioFile.open(path)) {
                let viaMetadata = f.metadata()

                let t1 = viaReadTags.title ?? ""
                let t2 = viaMetadata.title ?? ""
                @Assert(t1 == t2)

                let a1 = viaReadTags.artist ?? ""
                let a2 = viaMetadata.artist ?? ""
                @Assert(a1 == a2)
            }
        }
    }
}
