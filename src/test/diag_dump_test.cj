package audio4cj.test

import audio4cj.facade.AudioFile
import std.binary.*
import std.collection.*
import std.fs.*

/* ============================================================================
 * 诊断导出：把本库解出的 PCM 逐字节写成 f32le，供仓库外工具做**带定位的偏差检测**
 *
 * 【它解决什么问题】
 *   本库的比对工具（`golden_test.cj` 的 gtMaxDiff / gtMeanPower / gtTotalEnergy 等）
 *   给出的全是**全局标量**：它们能回答"整体对不对"，**不能**回答"偏在哪一秒"。
 *   当某个素材出现"整体能量吻合、但局部峰值对不上"这类疑点时（实测：真实歌曲
 *   某时刻本库峰值 1.2372 / ffmpeg 1.0378），必须把双方的 PCM 落到文件上，
 *   再用专门的比对器逐段定位。本用例就是那个**出口**。
 *
 * 【为什么长在测试目录里】
 *   诊断工具不属于产品能力：它不进 `cjpm.toml` 的打包白名单（`/src/test` 已被
 *   include 白名单天然排除），也不会给使用者带来任何依赖。放在这里能与
 *   `testdata/` 的素材、`gsSkipIfNoFixtures` 的守卫语义保持一致。
 *
 * 【默认不工作，也绝不失败】
 *   清单文件 `testdata/diag/dump.list` 不存在时，本用例只打印一行"跳过"就返回。
 *   理由：
 *     · 常规 `cjpm test` 不该被诊断任务拖慢 —— 一首 5 分钟的歌，纯仓颉 MP3 解码
 *       要按分钟计（单帧约十几毫秒）；
 *     · 清单里的源文件可能不在（`musics/` 是第三方版权素材、不入库），
 *       此时逐行打印"跳过（源文件不存在）"，**不判失败** —— 与 `musics/` 的
 *       软依赖惯例一致。
 *
 * 【清单格式】`testdata/diag/dump.list`，每行一条，`#` 开头为注释：
 *     <源音频路径>|<目标 f32le 路径>
 *   例如：
 *     musics/song.mp3|eval_work/ours/song.f32le
 *   目标目录需先存在（由调用方 `scripts/diag/` 下的脚本创建）。
 *
 *   注意：本段注释里**不能**出现形如"斜杠 + 星号"的字面量 —— 仓颉的块注释
 *   是**可嵌套**的，编译器会把那种写法当成嵌套注释的开头，导致本段注释
 *   "未闭合"（实测踩过一次）。
 *
 * 【为什么用 f32le 而不是 wav】
 *   与 `testdata/golden/` 下的 `.f32le` 基准同口径：无头、无对齐歧义、四字节交错，
 *   Python / C 侧都能零成本读入（`numpy.fromfile(dtype='<f4')`）。
 *
 * 【内存：为什么走 stream() 而不是 readAll()】
 *   一首 5 分钟 44.1kHz 立体声的歌有 1300 万帧，全量驻留是 100 MB 量级的数组
 *   （且会撞上 `readAll` 默认 1000 万帧的上限）。流式分块把峰值内存压到
 *   单块 + 输出缓冲，与文件长度无关。
 *
 * 【运行方式】清单就绪后：
 *     cjpm test --filter dumpDecodedPcmForDiagnosis --show-all-output
 *   `--show-all-output` 是必需的：测试框架默认**捕获**用例的 stdout，
 *   否则你看不到导出的逐条回显（这一条与 golden_support_test 的说明同源）。
 * ========================================================================== */

/// 诊断清单路径（相对仓库根 —— `cjpm test` 的工作目录即仓库根）。
let DD_LIST: String = "testdata/diag/dump.list"

/// 安全切片：越界与负长度一律收敛成空切片。
///
/// 直接用 `src[start..start+len]` 需要先证明两个下标都在范围内，
/// 在这里（文件内容驱动）把边界条件收在一处比散在调用点更可靠。
private func ddSlice(src: Array<UInt8>, start: Int64, len: Int64): Array<UInt8> {
    if (len <= 0 || start < 0 || start >= src.size) {
        return Array<UInt8>()
    }
    let end = min(start + len, src.size)
    src[start..end]
}

/// 把交错 f32 样本编码为小端字节流（4 字节/样本）。
private func ddEncodeF32Le(samples: Array<Float32>): Array<UInt8> {
    let out = Array<UInt8>(samples.size * 4, repeat: 0)
    let quad = Array<UInt8>(4, repeat: 0)
    var i: Int64 = 0
    while (i < samples.size) {
        samples[i].writeLittleEndian(quad)
        out[i * 4] = quad[0]
        out[i * 4 + 1] = quad[1]
        out[i * 4 + 2] = quad[2]
        out[i * 4 + 3] = quad[3]
        i += 1
    }
    out
}

/// 读取清单，返回 (源路径, 目标路径) 列表；文件不存在返回空列表。
private func ddLoadList(path: String): ArrayList<(String, String)> {
    let jobs = ArrayList<(String, String)>()
    if (!exists(Path(path))) {
        return jobs
    }

    try (f = File(path, Read)) {
        let size = f.length
        let buf = Array<UInt8>(size, repeat: 0)
        let got = f.read(buf)
        let text = String.fromUtf8(ddSlice(buf, 0, got))

        for (line in text.lines()) {
            let s = line.trimAscii()
            if (s.isEmpty() || s.startsWith("#")) {
                continue
            }
            let parts = s.split("|")
            if (parts.size < 2) {
                continue
            }
            let src = parts[0].trimAscii()
            let dst = parts[1].trimAscii()
            if (src.isEmpty() || dst.isEmpty()) {
                continue
            }
            jobs.add((src, dst))
        }
    }

    jobs
}

/// 解码一个文件并写成 f32le，返回写出的帧数（-1 表示源文件不存在）。
///
/// 【为什么必须走 stream() + next()，而不是循环 readFrames】
///   `readFrames(count)` 内部走 `drain()`，而 `drain()` 返回前会 `s.close()`；
///   FrameStream 的关闭**连带关闭底层 reader**（它与 AudioFile 共享 reader）。
///   因此第一次 `readFrames` 返回后 reader 已死，第二次调用会抛
///   `ClosedResourceException`（实测："对已关闭的 MP3 reader 执行操作"）。
///   注意：`drain()` 现在会同步置位 AudioFile 的关闭状态，故
///   `f.isClosed()` 返回 true，与"reader 已死"一致（此前是 false，属实现缺陷，
///   已修复）。这里改用 `stream()` 是因为它给出"取到 None 才是正常结束"的
///   完整语义，是官方主推用法，且不是一次性 API。
private func ddDumpOne(src: String, dst: String): Int64 {
    if (!exists(Path(src))) {
        return -1
    }

    var frames: Int64 = 0
    try (f = AudioFile.open(src)) {
        let info = f.info()
        let st = f.stream()
        try (out = File(dst, Write)) {
            while (true) {
                match (st.next()) {
                    case Some(buf) =>
                        if (buf.samples.size > 0) {
                            out.write(ddEncodeF32Le(buf.samples))
                            frames += buf.frameCount
                        }
                    case None => break
                }
            }
        }
        // FrameStream 未实现 Resource，只能手动关闭；它关闭的是与 f 共享的 reader，
        // 所以必须在读完所有块之后再做（f 的 try-with-resources 会再关一次，幂等）。
        st.close()
        println(
            "导出 ${src} -> ${dst}：" + "${info.sampleRate} Hz / ${info.channels} ch / 位深标记 ${info.bitDepth} / " +
                "解出 ${frames} 帧（声明 ${info.totalFrames}）")
    }

    frames
}

@Test
class DiagDumpTest {
    /// 按 `testdata/diag/dump.list` 把本库解出的 PCM 导出为 f32le
    ///
    /// 清单不存在 → 打印跳过并返回（常规测试零开销）；
    /// 清单里的源文件不存在 → 逐条打印跳过，**不判失败**（`musics/` 不入库）。
    @TestCase
    func dumpDecodedPcmForDiagnosis() {
        let jobs = ddLoadList(DD_LIST)
        if (jobs.isEmpty()) {
            println("跳过（无 ${DD_LIST} 或无有效条目，未请求诊断导出）：dumpDecodedPcmForDiagnosis")
            return
        }

        var dumped: Int64 = 0
        var missing: Int64 = 0
        for ((src, dst) in jobs) {
            let frames = ddDumpOne(src, dst)
            if (frames < 0) {
                println("跳过（源文件不存在，第三方版权素材不入库）：${src}")
                missing += 1
            } else {
                dumped += 1
            }
        }

        println("诊断导出完成：成功 ${dumped} 条，缺源跳过 ${missing} 条（清单 ${jobs.size} 条）")
    }
}
