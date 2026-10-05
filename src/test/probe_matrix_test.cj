package audio4cj.test

import audio4cj.probe.detectFile
import audio4cj.probe.detectBytes
import audio4cj.probe.PROBE_HEAD_SIZE
import audio4cj.facade.AudioFile
import audio4cj.core.FormatNotSupportedException
import audio4cj.meta.safeSlice
import std.fs.*
import std.collection.ArrayList

/* ============================================================================
 * 素材识别矩阵 —— 覆盖探测层对全部 testdata 素材的判定
 *
 * 【对照基准从哪来】
 *   testdata/MANIFEST.tsv 由 sctiptr/gen_audio_fixtures.py 生成，其中每行的
 *   「容器 / 子编码」是那个脚本用 Python 的 sniff() **独立**识别出来的。
 *   本测试用仓颉的探测层判定同一批文件，两边必须一致 —— 这是两套独立实现的
 *   交叉检查，而不是"用被测对象验证被测对象"。
 *
 * 【为什么素材缺失要判失败 —— 但"制品包内"是例外，两者必须分开】
 *   testdata/ 是随仓库分发的固定测试资产（由 ffmpeg 从合成信号生成，无版权
 *   问题），不是可选的本地素材。**在仓库内**缺失说明仓库不完整，应当立即暴露，
 *   因此这里不做"缺了就跳过"（与本项目的真实歌曲素材策略相反 —— 那些是第三方
 *   版权内容，不入库，见 long_run_test.cj）。
 *
 *   **但在制品包内是另一回事**：cjpm bundle 不打包二进制文件，所以 testdata/
 *   下的音频素材**根本不会随包分发**（实测：61 个素材一个都没进包，只有两个
 *   .tsv 文本文件进去了）。那不是"仓库不完整"，而是分发方式的必然结果 ——
 *   而一个"解压后跑测试就成片失败"的包，等于主动展示自己坏掉了。
 *   故守卫按**根目录是否整体存在**区分两种场景：
 *     根目录缺失（= 包内）  → gsSkipIfNoFixtures 打印原因并跳过；
 *     个别素材缺失（仓库内）→ 仍然判失败，即本段原本的意图，未被削弱。
 *   判据的实现与完整理由见 golden_support_test.cj 的 gsSkipIfNoFixtures。
 *
 * 【本文件覆盖的一类真实缺陷】
 *   探测层原只读文件头 16 字节，而 Ogg 的子编码标识位于**首个页面的 payload**
 *   （第 28 字节起），16 字节根本到不了 —— 于是 Ogg 的子编码判定从未生效过，
 *   "不支持"的信息一直笼统到容器级。probeWindowCoversOggPayload 用例专门守住
 *   这个下限。
 * ========================================================================== */

/// 素材识别基准（由 sctiptr/gen_audio_fixtures.py 生成）。
private let PM_MANIFEST: String = "testdata/MANIFEST.tsv"

/// 素材根目录。
private let PM_ROOT: String = "testdata"

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

/// 读取 MANIFEST.tsv，返回 (相对路径, 容器, 子编码) 列表。
/// 以 '#' 开头的行为注释；行为空则跳过。
private func pmLoadManifest(): ArrayList<(String, String, String)> {
    let rows = ArrayList<(String, String, String)>()

    try (f = File(PM_MANIFEST, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        let text = String.fromUtf8(safeSlice(buf, 0, got))

        for (line in text.lines()) {
            let s = line.trimAscii()
            if (s.isEmpty() || s.startsWith("#")) {
                continue
            }

            let parts = s.split("\t")
            if (parts.size < 2) {
                continue
            }

            // 子编码为空时该列可能是空串，也可能被 split 丢掉结尾空字段，
            // 两种情形都归为空串
            let codec = if (parts.size >= 3) {
                parts[2]
            } else {
                ""
            }
            rows.add((parts[0], parts[1], codec))
        }
    }

    rows
}

/// 依据「容器 + 子编码」判断预期的可解码性。
///
/// 这份判断刻意在测试里独立写一遍，不复用探测层的实现 —— 否则探测层写错时
/// 测试会跟着一起错。可解码集合的权威定义在门面 `AudioFile.open()` 的分派分支。
private func pmExpectSupported(container: String, codec: String): Bool {
    // mp3 曾在这张表里、现已移除：MP3 解码移出本版本范围后，它**仍然会被识别**
    // （本文件另一条用例按 MANIFEST 校验容器与子编码，mp3 行照旧生效），
    // 只是 supported 变为 false —— "能认出来"与"能解码"是两件事，本表只管后者。
    if (container == "wav" || container == "flac") {
        return true
    }
    // Ogg 容器里只有 FLAC 编码可解码（由本库自己的纯仓颉 Ogg 源实现）
    if (container == "ogg") {
        return codec == "flac"
    }
    false
}

/// ASCII 文本转字节数组（仅用于构造魔数，不涉及多字节字符）。
private func pmAscii(s: String): Array<UInt8> {
    s.toArray()
}

/// 构造一个 Ogg 首页面：27 字节页头 + `segments` 项段表 + payload。
///
/// 页头布局（偏移逐字节对应 Ogg 规范）：
///   0..3  "OggS" | 4 版本 | 5 页头类型 | 6..13 granule | 14..17 serial
///   18..21 页序列号 | 22..25 校验和 | 26 段数 | 27.. 段表 | 之后 payload
///
/// 段数可变正是"payload 起点不能写死"的原因，因此本辅助**允许指定段数**。
private func pmOggPage(segments: Int64, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()

    for (b in pmAscii("OggS")) {
        out.add(b)
    }
    out.add(0u8) // 版本
    out.add(0u8) // 页头类型
    for (i in 0..8) {
        out.add(0u8) // granule position
    }
    for (i in 0..4) {
        out.add(0u8) // serial number
    }
    for (i in 0..4) {
        out.add(0u8) // page sequence
    }
    for (i in 0..4) {
        out.add(0u8) // checksum
    }
    out.add(UInt8(segments)) // 第 26 字节：段数
    for (i in 0..segments) {
        out.add(255u8) // 段表（取值本身不影响子编码判定）
    }
    for (b in payload) {
        out.add(b)
    }

    out.toArray()
}

/// 只构造页头（27 字节）并写入指定的段数，**不带段表与 payload**。
/// 用于验证"段数声称很大、数据却不够"这类畸形输入不会导致越界。
private func pmOggHeaderOnly(segmentCount: UInt8): Array<UInt8> {
    let out = ArrayList<UInt8>()

    for (b in pmAscii("OggS")) {
        out.add(b)
    }
    for (i in 0..22) { // 版本 ~ 校验和
        out.add(0u8)
    }
    out.add(segmentCount) // 恰为第 26 字节

    out.toArray()
}

/// 交给探测层判定，只取子编码。
private func pmCodecOf(page: Array<UInt8>): String {
    detectBytes(page).codec
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class ProbeMatrixTest {
    /// 探测读取窗口必须覆盖 Ogg 子编码判定的最坏需求
    ///
    /// 这是对一类真实缺陷的回归守卫。算术：
    ///   27（页头）+ 255（段数上限，决定 payload 起点）+ 8（最长子编码标识）= 290
    ///
    /// 探测窗口原为 16 字节 —— 连 payload 起点（第 28 字节）都到不了，
    /// 子编码判定静默失效。将来若有人为"省一点 I/O"把它调小，这条会立刻失败。
    @TestCase
    func probeWindowCoversOggPayload() {
        @Assert(PROBE_HEAD_SIZE >= 27 + 255 + 8)
    }

    /// 识别矩阵：每个素材的容器与子编码都必须与基准一致
    @TestCase
    func everyFixtureMatchesManifest() {
        if (gsSkipIfNoFixtures("everyFixtureMatchesManifest")) {
            return
        }

        let rows = pmLoadManifest()

        // 基准文件缺失或为空说明仓库不完整，立即失败（不静默跳过）
        @Assert(rows.size > 0)

        let bad = ArrayList<String>()
        for (row in rows) {
            let (rel, container, codec) = row
            let probe = detectFile("${PM_ROOT}/${rel}")
            if (probe.container != container || probe.codec != codec) {
                bad.add("${rel}: 期望 ${container}/${codec}，实得 ${probe.container}/${probe.codec}")
            }
        }

        // 一次性报出全部不符项，避免"改一个跑一次"
        if (!bad.isEmpty()) {
            @Fail(String.join(bad.toArray(), delimiter: " | "))
        }
    }

    /// 每类素材的可解码性与预期一致
    @TestCase
    func decodableSetMatchesExpectation() {
        if (gsSkipIfNoFixtures("decodableSetMatchesExpectation")) {
            return
        }

        let rows = pmLoadManifest()
        @Assert(rows.size > 0)

        let bad = ArrayList<String>()
        for (row in rows) {
            let (rel, container, codec) = row
            let probe = detectFile("${PM_ROOT}/${rel}")
            let want = pmExpectSupported(container, codec)
            if (probe.supported != want) {
                bad.add("${rel}（${container}/${codec}）期望 supported=${want}，实得 ${probe.supported}")
            }
        }

        if (!bad.isEmpty()) {
            @Fail(String.join(bad.toArray(), delimiter: " | "))
        }
    }

    /// 不支持的素材必须抛出**精确到编码级**的不支持异常
    ///
    /// 这是探测层区分 Ogg 子编码的直接目的：用户拿到"ogg 不支持"无法判断
    /// 该换成什么，而"ogg/opus 不支持"是可处置的信息。
    @TestCase
    func unsupportedFixturesReportPreciseEncoding() {
        if (gsSkipIfNoFixtures("unsupportedFixturesReportPreciseEncoding")) {
            return
        }

        // (素材路径, 错误信息中必须出现的格式标签)
        let cases = [
            ("${PM_ROOT}/ogg/ogg_vorbis_q4.ogg", "ogg/vorbis"),
            ("${PM_ROOT}/ogg/ogg_opus_32k.opus", "ogg/opus"),
            ("${PM_ROOT}/ogg/ogg_speex_16000.spx", "ogg/speex"),
            ("${PM_ROOT}/aac/aac_adts_128k.aac", "aac"),
            ("${PM_ROOT}/mp4/aac_mp4_128k.m4a", "mp4")
        ]

        for (c in cases) {
            let (path, label) = c

            var message = ""
            try {
                let f = AudioFile.open(path)
                f.close()
            } catch (e: FormatNotSupportedException) {
                message = e.toString()
            }

            @Assert(!message.isEmpty())
            @Assert(message.contains(label))
        }
    }

    /// Ogg 子编码判定：四种编码 + 多段页 + 越界防护
    ///
    /// 重点验证「payload 起点按段数计算」而非写死第 28 字节：段数为 2 时
    /// payload 落在第 29 字节，写死 28 就会读错位、判定失败。
    @TestCase
    func oggSubCodecBoundaries() {
        // ---- 四种子编码（段数为 1，payload 起点 = 28）----
        // Vorbis: 0x01 + "vorbis"（0x01 是 identification header 的 packet 类型）
        @Assert(pmCodecOf(pmOggPage(1, [0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73])) == "vorbis")
        // Opus: "OpusHead"
        @Assert(pmCodecOf(pmOggPage(1, pmAscii("OpusHead"))) == "opus")
        // FLAC-in-Ogg: 0x7F + "FLAC"
        @Assert(pmCodecOf(pmOggPage(1, [0x7F, 0x46, 0x4C, 0x41, 0x43])) == "flac")
        // Speex: "Speex   "（末尾三个空格补齐 8 字节）
        @Assert(pmCodecOf(pmOggPage(1, pmAscii("Speex   "))) == "speex")

        // ---- 段数变化时 payload 起点随之变化 ----
        let vorbisPayload: Array<UInt8> = [0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]
        @Assert(pmCodecOf(pmOggPage(2, vorbisPayload)) == "vorbis")
        @Assert(pmCodecOf(pmOggPage(5, vorbisPayload)) == "vorbis")
        @Assert(pmCodecOf(pmOggPage(40, vorbisPayload)) == "vorbis")

        // ---- 认不出的内容：返回空串（不是错误，也不误判成某种编码）----
        @Assert(pmCodecOf(pmOggPage(1, pmAscii("????"))).isEmpty())

        // ---- 越界防护：数据不足时必须安全返回空串，不得越界 ----
        // 只有页头，没有段表也没有 payload
        @Assert(pmCodecOf(pmOggHeaderOnly(0u8)).isEmpty())
        // 段数被写成上限 255，而段表与 payload 都不存在
        @Assert(pmCodecOf(pmOggHeaderOnly(255u8)).isEmpty())
        // 段数合法但 payload 短于最长标识（8 字节）
        @Assert(pmCodecOf(pmOggPage(1, pmAscii("FL"))).isEmpty())
    }

    /// Ogg 封装的 FLAC **可解码** —— 本轮修掉的"本可支持却被拒绝"缺口
    ///
    /// 依据：该能力当初是借助 dr_flac 对 Ogg 封装的 transparent 支持接出来的；
    /// 现在 **Ogg-FLAC 已改由本库自己的纯仓颉页级读取器实现**
    /// （见 format/ogg_flac_source.cj），故本条同时是那套实现的端到端回归。
    ///
    /// 同时做一次**无损互证**：同一参考信号分别以原生 FLAC 与 Ogg/FLAC 两种
    /// 封装编码，两者都是无损的，解码输出必须**逐位相同**。这条不需要任何
    /// 外部工具（不依赖 ffmpeg），因此在任何有素材的环境都能跑（**包内无素材，本用例会跳过** —— 见文件头说明）。
    ///
    /// 【它现在验的是什么，不要与另一条混淆】两条路径如今都走同一个纯仓颉内核，
    /// 所以本条验的是"**两种容器**的解码结果一致"（页重组有没有把音频弄错）；
    /// 而"解得对不对"由与 **ffmpeg 的 golden 基准**逐样本比对负责
    /// （见 src/test/flac_bitstream_test.cj 与 golden_support_test.cj）。
    /// 一个是自洽对照、一个是外部裁判，缺任一个都会留下盲区。
    @TestCase
    func flacInOggIsDecodableAndMatchesNativeFlac() {
        if (gsSkipIfNoFixtures("flacInOggIsDecodableAndMatchesNativeFlac")) {
            return
        }

        let oggPath = "${PM_ROOT}/ogg/ogg_flac.oga"
        let nativePath = "${PM_ROOT}/flac/flac_s16_44100_stereo.flac"

        try (a = AudioFile.open(oggPath)) {
            let infoA = a.info()
            @Assert(infoA.sampleRate > 0)
            @Assert(infoA.channels > 0)

            let bufA = a.readAll()
            @Assert(bufA.frameCount > 0)

            // 注意这里**不断言 totalFrames > 0**：
            //   Ogg 封装 FLAC 的 STREAMINFO 常把总样本数写成 0 —— 编码器在写
            //   Ogg 时未必能预知长度（与原生 FLAC 不同，后者可两遍写入）。
            //   此时本项目如实报告 -1「不可知」，这正是 §4.1 的契约，
            //   而不是把 0 当作有效帧数报出去。
            //   因此只在长度可知时校验它与实际解码帧数一致。
            @Assert(infoA.totalFrames != 0)
            if (infoA.totalFrames > 0) {
                @Assert(infoA.totalFrames == bufA.frameCount)
            }

            try (b = AudioFile.open(nativePath)) {
                let infoB = b.info()
                @Assert(infoA.sampleRate == infoB.sampleRate)
                @Assert(infoA.channels == infoB.channels)

                let bufB = b.readAll()

                // 无损互证的前提：两者容器里装的是同一段 PCM
                @Assert(bufA.frameCount == bufB.frameCount)
                @Assert(bufA.sampleCount == bufB.sampleCount)

                let sa = bufA.samples
                let sb = bufB.samples
                var diff: Int64 = 0
                for (i in 0..sa.size) {
                    if (sa[i] != sb[i]) {
                        diff += 1
                    }
                }
                @Assert(diff == 0)
            }
        }
    }
}
