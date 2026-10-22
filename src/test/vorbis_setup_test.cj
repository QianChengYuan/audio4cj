package audio4cj.test

import audio4cj.format.VorbisSetup
import std.collection.ArrayList
import std.fs.*

/* ============================================================================
 * Vorbis setup 头解析测试
 *
 * 这一层先把"头解析对不对"从"音频解码对不对"里分离出来：
 *   - 码本数量/维度错 → 后面所有 residue 都会错；
 *   - floor 的 Xlist/邻接点错 → 解码不报错但输出静音或爆音；
 *   - mode/mapping 错 → 声道错位。
 * 因此先用真实素材钉死 setup 的关键字段，再进入 PCM 解码。
 *
 * 测试素材来自 testdata/ogg/，由 scripts/gen_testdata.* 生成；
 * 缺少 testdata 目录时直接跳过，不把"素材缺失"伪装成通过。
 * ========================================================================== */
@Test
class VorbisSetupTest {
    @TestCase
    func parsesQ4StereoSetup() {
        let setup = loadSetup("testdata/ogg/ogg_vorbis_q4.ogg")
        @Expect(setup.sampleRate, 44100)
        @Expect(setup.channels, 2)
        @Expect(setup.blocksize0, 256)
        @Expect(setup.blocksize1, 2048)
        @Expect(setup.codebooks.size, 42)
        @Expect(setup.floors.size, 2)
        @Expect(setup.residues.size, 2)
        @Expect(setup.mappings.size, 2)
        @Expect(setup.modes.size, 2)
    }

    @TestCase
    func parsesQ0Setup() {
        let setup = loadSetup("testdata/ogg/ogg_vorbis_q0.ogg")
        @Expect(setup.sampleRate, 44100)
        @Expect(setup.channels, 2)
        @Expect(setup.codebooks.size, 34)
        @Expect(setup.floors.size, 2)
        @Expect(setup.residues.size, 2)
        // q0 的 low quality 预设把 residue 全部选成 type 2（交织），
        // 这条同时守住"type 2 不是罕见分支"这一事实。
        var ri: Int64 = 0
        while (ri < setup.residues.size) {
            @Expect(setup.residues[ri].residueType, 2)
            ri += 1
        }
    }

    /// q8 的码本包含有序码本中"长度为 0 的游程"（number=0）。
    ///
    /// 这是一个真实踩过的解析缺陷：早期实现把 number=0 当成非法，
    /// 导致 q8 在 setup 阶段就抛"有序码本长度序列非法"。规范明确允许
    /// 某档码长一个条目都不分配，因此这里用真实素材钉住。
    @TestCase
    func parsesQ8SetupWithOrderedCodebookZeroRuns() {
        let setup = loadSetup("testdata/ogg/ogg_vorbis_q8.ogg")
        @Expect(setup.sampleRate, 44100)
        @Expect(setup.channels, 2)
        @Expect(setup.codebooks.size > 0, true)
        @Expect(setup.modes.size, 2)
    }

    @TestCase
    func parsesMonoSetup() {
        let setup = loadSetup("testdata/ogg/ogg_vorbis_q4_mono.ogg")
        @Expect(setup.sampleRate, 16000)
        @Expect(setup.channels, 1)
        @Expect(setup.blocksize0, 512)
        @Expect(setup.blocksize1, 1024)
        @Expect(setup.codebooks.size > 0, true)
        @Expect(setup.mappings.size, 2)
        @Expect(setup.mappings[0].mux.size, 1)
    }

    @TestCase
    func parsesTaggedAndSilence() {
        let tagged = loadSetup("testdata/ogg/ogg_vorbis_tagged.ogg")
        @Expect(tagged.channels, 2)
        let silence = loadSetup("testdata/ogg/ogg_vorbis_silence.ogg")
        @Expect(silence.channels, 2)
        @Expect(silence.sampleRate, 44100)
    }

    /// 读取 Ogg 文件的前三个 packet 并解析 identification/setup。
    private func loadSetup(path: String): VorbisSetup {
        if (!exists(Path(path))) {
            throw Exception("测试素材缺失：${path}（请先运行 scripts/gen_testdata）")
        }
        let data = readAllBytes(path)
        let packets = extractPackets(data, 3)
        if (packets.size < 3) {
            throw Exception("Vorbis 测试素材的头部 packet 不足：${packets.size}")
        }
        VorbisSetup.parse(packets[0], packets[2])
    }

    private func readAllBytes(path: String): Array<UInt8> {
        var result = Array<UInt8>(0, repeat: 0)
        try (f = File(path, Read)) {
            let size = f.length
            let buf = Array<UInt8>(size, repeat: 0)
            var read: Int64 = 0
            while (read < size) {
                let n = f.read(buf[read..size])
                if (n <= 0) {
                    break
                }
                read += n
            }
            result = buf
        }
        result
    }

    /// 按 Ogg 页的 lacing 值重组完整 packet（只取指定逻辑流）。
    private func extractPackets(data: Array<UInt8>, maxPackets: Int64): ArrayList<Array<UInt8>> {
        let packets = ArrayList<Array<UInt8>>()
        var pending = ArrayList<UInt8>()
        var offset: Int64 = 0
        var serial: Int64 = -1
        while (offset + 27 <= data.size && packets.size < maxPackets) {
            if (data[offset] != UInt8(0x4F) || data[offset + 1] != UInt8(0x67) || data[offset + 2] != UInt8(0x67) ||
                data[offset + 3] != UInt8(0x53)) {
                throw Exception("Ogg 页魔数不是 OggS（offset=${offset}）")
            }
            let headerType = data[offset + 5]
            let pageSerial = readUInt32LE(data, offset + 14)
            let segmentCount = Int64(data[offset + 26])
            let tableStart = offset + 27
            var bodyLength: Int64 = 0
            var i: Int64 = 0
            while (i < segmentCount) {
                bodyLength += Int64(data[tableStart + i])
                i += 1
            }
            let bodyStart = tableStart + segmentCount
            if (bodyStart + bodyLength > data.size) {
                throw Exception("Ogg 页体被截断")
            }
            if (serial < 0) {
                if ((headerType & 0x02) == 0) {
                    throw Exception("Ogg 首个页面不是 BOS")
                }
                serial = pageSerial
            }
            if (pageSerial == serial) {
                var p: Int64 = 0
                i = 0
                while (i < segmentCount) {
                    let lace = Int64(data[tableStart + i])
                    var k: Int64 = 0
                    while (k < lace) {
                        pending.add(data[bodyStart + p + k])
                        k += 1
                    }
                    p += lace
                    if (lace < 255) {
                        packets.add(pending.toArray())
                        pending = ArrayList<UInt8>()
                        if (packets.size >= maxPackets) {
                            break
                        }
                    }
                    i += 1
                }
            }
            offset = bodyStart + bodyLength
        }
        packets
    }

    private func readUInt32LE(data: Array<UInt8>, offset: Int64): Int64 {
        Int64(data[offset]) | (Int64(data[offset + 1]) << 8) | (Int64(data[offset + 2]) << 16) | (Int64(data[offset + 3]) <<
            24)
    }
}
