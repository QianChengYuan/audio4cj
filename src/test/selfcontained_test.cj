package audio4cj.test

import audio4cj.core.CorruptedFileException
import audio4cj.core.FormatNotSupportedException
import audio4cj.facade.AudioFile
import audio4cj.probe.detectFile
import std.collection.ArrayList
import std.fs.*

/* ============================================================================
 * 包内自足测试套件 —— 制品包内的功能验证
 *
 * 【为什么单独有这一组】
 *   仓库侧的测试分两类：
 *     · 依赖 testdata/ 语料与外部基准的用例（golden 比对、probe_matrix、
 *       各格式的真实文件用例）—— 它们验证"链路通"与"与外部实现逐样本一致"；
 *     · 自足用例 —— 在仓颉里现场构造输入，不依赖任何外部素材。
 *   而 cjpm 官方规则明确"**所有二进制文件**默认不打包"，因此第一类在制品包内
 *   没有意义（包内没有 testdata/）。制品包内的功能验证由本文件承担：
 *   所有输入都在运行时构造，解包后 `cjpm test` 即可完整跑通 ——
 *   不需要任何外部工具、不需要任何素材、不需要联网。
 *
 * 【构造原则：能造的都造，且期望值由构造式给出】
 *   WAV  —— RIFF 头 + PCM 样本，直接写。
 *   FLAC —— 规范定义了 **verbatim 子帧**（类型 0b000001），可内联原始样本，
 *           因此"合法且可解码"的 FLAC 流能在内存里拼出来；CRC-8（帧头）与
 *           CRC-16（整帧）都按规范算。于是"期望 PCM"就是构造时写入的样本本身
 *           —— 判据是构造式给出的恒等式，不是抄来的数字。
 *   Ogg  —— 本库的 Ogg/FLAC 源有一条实测钉死的等式（见
 *           src/format/ogg_flac_source.cj）：原生 FLAC 字节流 = 选定逻辑流
 *           各页页体按序拼接、再丢掉首包 9 字节映射头。故把 FLAC 字节流
 *           加 9 字节映射头、拆成两页、各配正确的页 CRC-32，即得一个可解码的
 *           .oga —— 顺带把"跨页续传"与"页 CRC 校验"一起钉住。
 *   MP4  —— box 树手搭（size + type + 负载）。
 *   标签 —— ID3v2 / ID3v1 / Vorbis comment 按各自字段编码写出。
 *
 * 【刻意的负向用例】
 *   改坏一个字节之后**必须报错**（FLAC 帧 CRC、Ogg 页 CRC）。它们与正向用例
 *   同等重要：只断言"能解出正确结果"的测试，对"损坏被静默接受"是完全盲的。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

private func scAscii(out: ArrayList<UInt8>, s: String): Unit {
    for (b in s.toArray()) {
        out.add(b)
    }
}

private func scU16LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
}

private func scU32LE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8(v & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 24) & 0xFF))
}

private func scU16BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func scU32BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 24) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func scU24BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

/// 写出临时文件并返回路径。
private func scWrite(name: String, bytes: Array<UInt8>): String {
    let path = testTmpPath(name)
    File.writeTo(path, bytes)
    path
}

/// 追加 `n` 个零字节（定长字段填充用）。
private func scZeros(out: ArrayList<UInt8>, n: Int64): Unit {
    var k: Int64 = 0
    while (k < n) {
        out.add(0u8)
        k += 1
    }
}

/// 复制一份字节并翻转其中第 `index` 个字节 —— 用于负向用例。
private func scFlip(bytes: Array<UInt8>, index: Int64): Array<UInt8> {
    let copy = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < bytes.size) {
        if (i == index) {
            copy.add(bytes[i] ^ 0xFFu8)
        } else {
            copy.add(bytes[i])
        }
        i += 1
    }
    copy.toArray()
}

// ---------------------------------------------------------------------------
// WAV 构造
// ---------------------------------------------------------------------------

/// 最小 PCM WAV：RIFF + fmt + data，样本按小端写出。
private func scWavBytes(
    sampleRate: Int64,
    channels: Int64,
    bitsPerSample: Int64,
    samples: Array<Int32>
): Array<UInt8> {
    let bytesPerSample = (bitsPerSample + 7) / 8
    let dataSize = samples.size * bytesPerSample
    let fmtSize: Int64 = 16
    let riffSize = 4 + 8 + fmtSize + 8 + dataSize

    let out = ArrayList<UInt8>()
    scAscii(out, "RIFF")
    scU32LE(out, riffSize)
    scAscii(out, "WAVE")
    scAscii(out, "fmt ")
    scU32LE(out, fmtSize)
    scU16LE(out, 1) // PCM
    scU16LE(out, channels)
    scU32LE(out, sampleRate)
    scU32LE(out, sampleRate * channels * bytesPerSample)
    scU16LE(out, channels * bytesPerSample)
    scU16LE(out, bitsPerSample)
    scAscii(out, "data")
    scU32LE(out, dataSize)

    for (s in samples) {
        out.add(UInt8(s & 0xFF))
        out.add(UInt8((s >> 8) & 0xFF))
        if (bitsPerSample >= 24) {
            out.add(UInt8((s >> 16) & 0xFF))
        }
        if (bitsPerSample >= 32) {
            out.add(UInt8((s >> 24) & 0xFF))
        }
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// FLAC 构造（位写入器 + 两个规范 CRC + verbatim 帧）
// ---------------------------------------------------------------------------

/// 按位写入的缓冲器（FLAC 的帧头与子帧都是非字节对齐的位流）。
private class ScBitWriter {
    private var _bytes = ArrayList<UInt8>()
    private var _cur: Int64 = 0
    private var _bits: Int64 = 0

    func writeBits(value: Int64, count: Int64): Unit {
        var i = count - 1
        while (i >= 0) {
            let bit = (value >> i) & 1
            _cur = (_cur << 1) | bit
            _bits += 1
            if (_bits == 8) {
                _bytes.add(UInt8(_cur & 0xFF))
                _cur = 0
                _bits = 0
            }
            i -= 1
        }
    }

    func writeSigned(value: Int32, count: Int64): Unit {
        let mask: Int64 = if (count >= 32) {
            0xFFFFFFFF
        } else {
            (1 << count) - 1
        }
        writeBits(Int64(value) & mask, count)
    }

    func alignToByte(): Unit {
        while (_bits != 0) {
            writeBits(0, 1)
        }
    }

    func bytes(): Array<UInt8> {
        _bytes.toArray()
    }

    func toArrayBytes(): Array<UInt8> {
        alignToByte()
        _bytes.toArray()
    }
}

/// CRC-8，多项式 0x07，初值 0 —— 帧头校验。
private func scCrc8(data: Array<UInt8>): UInt8 {
    var crc: UInt32 = 0
    for (b in data) {
        crc = (crc ^ UInt32(b)) & 0xFFu32
        for (i in 0..8) {
            if ((crc & 0x80u32) != 0u32) {
                crc = ((crc << 1) ^ 0x07u32) & 0xFFu32
            } else {
                crc = (crc << 1) & 0xFFu32
            }
        }
    }
    UInt8(crc)
}

/// CRC-16，多项式 0x8005，初值 0 —— 整帧校验。
private func scCrc16(data: Array<UInt8>): UInt16 {
    var crc: UInt32 = 0
    for (b in data) {
        crc = (crc ^ (UInt32(b) << 8)) & 0xFFFFu32
        for (i in 0..8) {
            if ((crc & 0x8000u32) != 0u32) {
                crc = ((crc << 1) ^ 0x8005u32) & 0xFFFFu32
            } else {
                crc = (crc << 1) & 0xFFFFu32
            }
        }
    }
    UInt16(crc)
}

/// STREAMINFO 块体（34 字节）。
private func scStreamInfo(
    sampleRate: Int64,
    channels: Int64,
    bitsPerSample: Int64,
    totalSamples: Int64,
    blockSize: Int64
): Array<UInt8> {
    let w = ScBitWriter()
    w.writeBits(blockSize, 16)
    w.writeBits(blockSize, 16)
    w.writeBits(0, 24)
    w.writeBits(0, 24)
    w.writeBits(sampleRate, 20)
    w.writeBits(channels - 1, 3)
    w.writeBits(bitsPerSample - 1, 5)
    w.writeBits(totalSamples, 36)
    // MD5（128 位，此处全零：verbatim 流不校验它，但对齐与长度必须正确）。
    // 必须写成 4×32 位：仓颉对"移位宽度 ≥ 64"会抛 Overshift，一次写 128 位会直接炸。
    w.writeBits(0, 32)
    w.writeBits(0, 32)
    w.writeBits(0, 32)
    w.writeBits(0, 32)
    w.toArrayBytes()
}

/// 一个固定块大小的 verbatim 帧（单声道）。
private func scVerbatimFrame(
    samples: Array<Int32>,
    bitsPerSample: Int64,
    blockSize: Int64,
    frameNumber: Int64
): Array<UInt8> {
    let w = ScBitWriter()
    w.writeBits(0x3FFE, 14) // 同步码
    w.writeBits(0, 1) // reserved
    w.writeBits(0, 1) // 固定块大小
    w.writeBits(6, 4) // 块大小码 6 → 头部末尾跟 8 位 (blocksize-1)
    w.writeBits(9, 4) // 采样率码 9 = 44.1 kHz
    w.writeBits(0, 4) // 声道分配 0 = 单声道
    w.writeBits(4, 3) // 样本宽度码 4 = 16 位
    w.writeBits(0, 1) // reserved
    w.writeBits(frameNumber, 8)
    w.writeBits(blockSize - 1, 8)
    w.alignToByte()

    let headerBytes = w.bytes()
    w.writeBits(Int64(scCrc8(headerBytes)), 8)

    w.writeBits(0, 1) // 子帧填充位
    w.writeBits(1, 6) // 类型 000001 = verbatim
    w.writeBits(0, 1) // 无效位标志
    for (s in samples) {
        w.writeSigned(s, bitsPerSample)
    }
    w.alignToByte()

    let frameSoFar = w.bytes()
    w.writeBits(Int64(scCrc16(frameSoFar)), 16)
    w.toArrayBytes()
}

/// Vorbis comment 块体：vendor + "KEY=VALUE" 条目（各字段均为 4 字节小端长度前缀）。
private func scVorbisCommentBody(vendor: String, entries: Array<String>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    let vb = vendor.toArray()
    scU32LE(out, vb.size)
    for (b in vb) {
        out.add(b)
    }
    scU32LE(out, entries.size)
    for (e in entries) {
        let eb = e.toArray()
        scU32LE(out, eb.size)
        for (b in eb) {
            out.add(b)
        }
    }
    out.toArray()
}

/// 组装 FLAC 流：`fLaC` + STREAMINFO + [可选 VORBIS_COMMENT] + 音频帧。
private func scFlacStream(
    frames: Array<Array<UInt8>>,
    sampleRate: Int64,
    bitsPerSample: Int64,
    totalSamples: Int64,
    blockSize: Int64,
    comment: ?Array<UInt8>
): Array<UInt8> {
    let out = ArrayList<UInt8>()
    scAscii(out, "fLaC")

    let si = scStreamInfo(sampleRate, 1, bitsPerSample, totalSamples, blockSize)
    // 块头：最高位 = 是否最后一块。有注释块时 STREAMINFO 不是最后一块。
    if (comment.isSome()) {
        out.add(0x00u8)
    } else {
        out.add(0x80u8)
    }
    scU24BE(out, si.size)
    for (b in si) {
        out.add(b)
    }

    if (let Some(c) <- comment) {
        out.add(0x84u8) // 最后一块（0x80）| 类型 4 = VORBIS_COMMENT
        scU24BE(out, c.size)
        for (b in c) {
            out.add(b)
        }
    }

    for (f in frames) {
        for (b in f) {
            out.add(b)
        }
    }
    out.toArray()
}

/// 单帧 FLAC（16 个样本，16 位，44.1 kHz，单声道）。
private func scSimpleFlac(samples: Array<Int32>): Array<UInt8> {
    let frame = scVerbatimFrame(samples, 16, Int64(samples.size), 0)
    scFlacStream([frame], 44100, 16, Int64(samples.size), Int64(samples.size), None)
}

// ---------------------------------------------------------------------------
// Ogg 构造（页 + 页 CRC-32 + FLAC-in-Ogg 映射）
// ---------------------------------------------------------------------------

/// Ogg 页 CRC-32：多项式 0x04C11DB7、初值 0、输入输出均不反转，
/// 覆盖整页且**先把 CRC 字段自身置零**。与 src/format/ogg_crc.cj 的参数一致。
private func scOggCrc32(page: Array<UInt8>): Int64 {
    var crc: Int64 = 0
    for (b in page) {
        crc = crc ^ (Int64(b) << 24)
        var i: Int64 = 0
        while (i < 8) {
            if ((crc & 0x80000000) != 0) {
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            } else {
                crc = (crc << 1) & 0xFFFFFFFF
            }
            i += 1
        }
    }
    crc
}

/// 段表：除最后一段外全为 255（表示 packet 未完），最后一段 < 255（packet 结束）。
private func scLacing(bodyLen: Int64): Array<Int64> {
    let out = ArrayList<Int64>()
    var left = bodyLen
    while (left >= 255) {
        out.add(255)
        left -= 255
    }
    out.add(left)
    out.toArray()
}

/// 构造一个带正确 CRC-32 的 Ogg 页。
private func scOggPage(
    serial: Int64,
    seq: Int64,
    headerType: Int64,
    granule: Int64,
    body: Array<UInt8>
): Array<UInt8> {
    let lacing = scLacing(body.size)
    let out = ArrayList<UInt8>()

    scAscii(out, "OggS")
    out.add(0u8) // 结构版本
    out.add(UInt8(headerType))
    var g = granule
    var i: Int64 = 0
    while (i < 8) {
        out.add(UInt8(g & 0xFF))
        g = g >> 8
        i += 1
    }
    scU32LE(out, serial)
    scU32LE(out, seq)
    for (j in 0..4) {
        out.add(0u8) // CRC 占位（置零后计算）
    }
    out.add(UInt8(lacing.size))
    for (v in lacing) {
        out.add(UInt8(v))
    }
    for (b in body) {
        out.add(b)
    }

    var page = out.toArray()
    let crc = scOggCrc32(page)
    page[22] = UInt8(crc & 0xFF)
    page[23] = UInt8((crc >> 8) & 0xFF)
    page[24] = UInt8((crc >> 16) & 0xFF)
    page[25] = UInt8((crc >> 24) & 0xFF)
    page
}

/// FLAC-in-Ogg 映射头（9 字节）：0x7F "FLAC" + 主版本 + 次版本 + 头包数（大端）。
private func scFlacOggMappingHeader(headerPackets: Int64): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(0x7Fu8)
    scAscii(out, "FLAC")
    out.add(0x01u8)
    out.add(0x00u8)
    scU16BE(out, headerPackets)
    out.toArray()
}

/// 把 FLAC 字节流封装成 Ogg：映射头 + FLAC 流，拆成两页。
///
/// 拆两页是刻意的：第二页即"跨页续传"，构造出的字节流在本库的 Ogg/FLAC 源里
/// 必须被拼回与原生 FLAC 逐字节相同的流。
private func scOggFlacBytes(flac: Array<UInt8>, serial: Int64): Array<UInt8> {
    let stream = ArrayList<UInt8>()
    for (b in scFlacOggMappingHeader(1)) {
        stream.add(b)
    }
    for (b in flac) {
        stream.add(b)
    }
    let all = stream.toArray()
    let half = all.size / 2

    let out = ArrayList<UInt8>()
    for (b in scOggPage(serial, 0, 0x02, 0, all[0..half])) {
        out.add(b) // 首页（BOS）
    }
    for (b in scOggPage(serial, 1, 0x04, 0, all[half..all.size])) {
        out.add(b) // 次页（EOS，跨页续传）
    }
    out.toArray()
}

/// 合成一个 Ogg/Vorbis 流：识别头页 + 注释头页。
///
/// 本库不支持 Vorbis 解码，故它只用于验证"**识别得出、但不支持**"这条契约：
/// 容器与子编码都要报得出来，不能退化成 unknown。
private func scOggVorbisBytes(serial: Int64): Array<UInt8> {
    let ident = ArrayList<UInt8>()
    ident.add(0x01u8)
    scAscii(ident, "vorbis")
    scZeros(ident, 23) // 识别头总长 30 字节，与真实文件一致

    let comment = ArrayList<UInt8>()
    comment.add(0x03u8)
    scAscii(comment, "vorbis")
    for (b in scVorbisCommentBody("audio4cj-test", ["TITLE=合成的 Vorbis"])) {
        comment.add(b)
    }

    let out = ArrayList<UInt8>()
    for (b in scOggPage(serial, 0, 0x02, 0, ident.toArray())) {
        out.add(b)
    }
    for (b in scOggPage(serial, 1, 0x04, 0, comment.toArray())) {
        out.add(b)
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// MP4 box 构造
// ---------------------------------------------------------------------------

private func scMp4Box(typeName: String, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    scU32BE(out, 8 + payload.size)
    scAscii(out, typeName)
    for (b in payload) {
        out.add(b)
    }
    out.toArray()
}

/// 类型名含单字节 0xA9 前缀的 box（如 ©nam）—— 必须用字节给类型名，
/// 写成字符串会得到 UTF-8 的两字节形式（0xC2 0xA9），永远匹配不上。
private func scMp4BoxRaw(typeBytes: Array<UInt8>, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    scU32BE(out, 8 + payload.size)
    for (b in typeBytes) {
        out.add(b)
    }
    for (b in payload) {
        out.add(b)
    }
    out.toArray()
}

private func scMp4Data(indicator: Int64, payload: Array<UInt8>): Array<UInt8> {
    let body = ArrayList<UInt8>()
    scU32BE(body, indicator)
    scU32BE(body, 0) // locale
    for (b in payload) {
        body.add(b)
    }
    scMp4Box("data", body.toArray())
}

private func scMp4CopyrightType(rest: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(0xA9u8)
    scAscii(out, rest)
    out.toArray()
}

/// 文本型原子（©nam / ©ART / …）：data box 的 typeIndicator = 1 表示 UTF-8 文本。
private func scMp4TextItem(rest: String, text: String): Array<UInt8> {
    scMp4BoxRaw(scMp4CopyrightType(rest), scMp4Data(1, text.toArray()))
}

/// meta 是 FullBox：负载开头有 4 字节 version + flags。
private func scMp4Meta(children: Array<UInt8>, flags: Int64): Array<UInt8> {
    let body = ArrayList<UInt8>()
    scU32BE(body, flags)
    for (b in children) {
        body.add(b)
    }
    scMp4Box("meta", body.toArray())
}

/// 组装最小 MP4：ftyp + [可选 mdat] + moov/udta/meta/ilst。
///
/// `mdatBytes` > 0 时在 mdat 里**故意夹入 "moov" 字样** —— 用来验证"文件末尾的
/// moov"靠长度关系定位，而不是靠搜字符串（真实 mdat 里是压缩音频，
/// 偶然出现 "moov" 四个字节完全可能）。
private func scMp4Bytes(ilst: Array<UInt8>, mdatBytes: Int64, metaFlags: Int64): Array<UInt8> {
    let out = ArrayList<UInt8>()

    for (b in scMp4Box("ftyp", "M4A ".toArray())) {
        out.add(b)
    }

    if (mdatBytes > 0) {
        let filler = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i + 4 <= mdatBytes) {
            scAscii(filler, "moov")
            i += 4
        }
        for (b in scMp4Box("mdat", filler.toArray())) {
            out.add(b)
        }
    }

    let ilstBox = scMp4Box("ilst", ilst)
    let metaBox = scMp4Meta(ilstBox, metaFlags)
    let udtaBox = scMp4Box("udta", metaBox)
    for (b in scMp4Box("moov", udtaBox)) {
        out.add(b)
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// 伪 MP3 构造（ID3v2 + 帧同步字 + ID3v1）
// ---------------------------------------------------------------------------

private func scSynchsafe(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 21) & 0x7F))
    out.add(UInt8((v >> 14) & 0x7F))
    out.add(UInt8((v >> 7) & 0x7F))
    out.add(UInt8(v & 0x7F))
}

/// ID3v2.3 标签（仅 TIT2，**Latin-1** 编码：标题必须是 ASCII，
/// 否则写出的是 UTF-8 字节而解析方按 Latin-1 解读，取值必然对不上）。
private func scId3v2Title(title: String): Array<UInt8> {
    let frameBody = ArrayList<UInt8>()
    frameBody.add(0u8) // 编码 = Latin-1
    scAscii(frameBody, title)
    let frameData = frameBody.toArray()

    let body = ArrayList<UInt8>()
    scAscii(body, "TIT2")
    scU32BE(body, frameData.size)
    body.add(0u8)
    body.add(0u8)
    for (b in frameData) {
        body.add(b)
    }
    let bodyBytes = body.toArray()

    let out = ArrayList<UInt8>()
    scAscii(out, "ID3")
    out.add(3u8)
    out.add(0u8)
    out.add(0u8)
    scSynchsafe(out, bodyBytes.size)
    for (b in bodyBytes) {
        out.add(b)
    }
    out.toArray()
}

/// ID3v1 标签（仅标题）。
private func scId3v1Title(title: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    scAscii(out, "TAG")
    let tb = title.toArray()
    var i: Int64 = 0
    while (i < 30) {
        if (i < tb.size) {
            out.add(tb[i])
        } else {
            out.add(0u8)
        }
        i += 1
    }
    scZeros(out, 30) // 艺术家
    scZeros(out, 30) // 专辑
    scZeros(out, 4) // 年份
    scZeros(out, 30) // 注释
    out.add(17u8) // 流派索引 17 = Rock
    out.toArray()
}

/// 伪 MP3：ID3v2 + MPEG 帧同步字 + ID3v1。
private func scFakeMp3(v2: Array<UInt8>, v1: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    for (b in v2) {
        out.add(b)
    }
    out.add(0xFFu8)
    out.add(0xFBu8)
    out.add(0x90u8)
    out.add(0x00u8)
    for (b in v1) {
        out.add(b)
    }
    out.toArray()
}

// ---------------------------------------------------------------------------
// 用例：门面契约与探测
// ---------------------------------------------------------------------------

@Test
class SelfContainedFormatTest {
    /// WAV：容器、编码、MIME 与轨道信息（公开路径）
    @TestCase
    func wavFormatAndTracks() {
        let samples: Array<Int32> = [1000, -1000, 2000, -2000]
        let path = scWrite("a4cj_sc_fmt.wav", scWavBytes(44100, 2, 16, samples))

        try (f = AudioFile.open(path)) {
            let info = f.format()
            @Expect(info.container, "wav")
            @Expect(info.codec, "")
            @Expect(info.codecId, "wav")
            @Assert(info.mimeType.size > 0)

            let tracks = f.tracks()
            @Expect(tracks.size, 1)
            @Expect(tracks[0].index, 0)
            @Expect(tracks[0].sampleRate, 44100)
            @Expect(tracks[0].channels, 2)
        }
        remove(path)
    }

    /// FLAC：容器与编码分开可读，轨道信息与 STREAMINFO 一致
    @TestCase
    func flacFormatAndTracks() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let path = scWrite("a4cj_sc_fmt.flac", scSimpleFlac(samples))

        try (f = AudioFile.open(path)) {
            let info = f.format()
            @Expect(info.container, "flac")
            @Expect(info.codec, "")
            @Expect(info.codecId, "flac")

            let tracks = f.tracks()
            @Expect(tracks.size, 1)
            @Expect(tracks[0].codecId, "flac")
            @Expect(tracks[0].sampleRate, 44100)
            @Expect(tracks[0].channels, 1)
        }
        remove(path)
    }

    /// 契约：format()/tracks() 是 open 时的快照，关闭后仍可读；
    /// 而**数据方法**关闭后必须失效 —— "关闭后仍可读"是有边界的。
    @TestCase
    func formatSnapshotSurvivesCloseButDataDoesNot() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let path = scWrite("a4cj_sc_close.flac", scSimpleFlac(samples))

        let f = AudioFile.open(path)
        let before = f.format().codecId
        f.close()
        @Expect(f.isClosed(), true)
        @Expect(f.format().codecId, before)
        @Expect(f.format().container, "flac")
        @Expect(f.tracks().size, 1)

        var message = ""
        try {
            f.info()
            @Fail("关闭后调用 info() 应当抛出异常")
        } catch (e: Exception) {
            message = e.message
        }
        @Expect(message.contains("关闭"), true)
        remove(path)
    }

    /// 探测矩阵：三种受支持容器的容器与子编码都要报得出来
    @TestCase
    func probeMatrixOnSynthesizedFiles() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let wav = scWrite("a4cj_sc_probe.wav", scWavBytes(44100, 1, 16, samples))
        let flac = scWrite("a4cj_sc_probe.flac", scSimpleFlac(samples))
        let oga = scWrite("a4cj_sc_probe.oga", scOggFlacBytes(scSimpleFlac(samples), 11))

        let pw = detectFile(wav)
        @Expect(pw.container, "wav")
        @Expect(pw.codec, "")
        @Expect(pw.supported, true)

        let pf = detectFile(flac)
        @Expect(pf.container, "flac")
        @Expect(pf.codec, "")
        @Expect(pf.supported, true)

        let po = detectFile(oga)
        @Expect(po.container, "ogg")
        @Expect(po.codec, "flac")
        @Expect(po.supported, true)

        remove(wav)
        remove(flac)
        remove(oga)
    }

    /// Ogg/Vorbis：**识别得出、但不支持**（不可解码 ≠ 认不出来）
    @TestCase
    func vorbisIsIdentifiedButUnsupported() {
        let path = scWrite("a4cj_sc_vorbis.ogg", scOggVorbisBytes(21))

        let probe = detectFile(path)
        @Expect(probe.container, "ogg")
        @Expect(probe.codec, "vorbis")
        @Expect(probe.supported, false)

        var message = ""
        try {
            let f = AudioFile.open(path)
            f.close()
            @Fail("Ogg/Vorbis 尚无解码实现，open 应当抛异常")
        } catch (e: Exception) {
            message = e.toString()
        }
        @Expect(message.contains("vorbis"), true)
        remove(path)
    }

    /// MP3：能识别、可解码（MP3 已回到解码范围），且**伪流必须被拒绝**
    ///
    /// 这条一语双关：
    ///   · 能力面 —— MP3 现在 supported=true，走的是纯仓颉解码内核；
    ///   · 健壮面 —— 本用例构造的"伪 MP3"只有一个合法帧头、其后是 ID3v1，
    ///     **不含任何真正的帧数据**。解码器不得把它当成一段短音频解出来，
    ///     必须在打开阶段就明确拒绝（CorruptedFileException）。
    ///     这正是"帧同步 + 连续帧校验"存在的意义：单个同步字不足为凭。
    @TestCase
    func mp3IsIdentifiedAndFakeStreamIsRejected() {
        let path = scWrite(
            "a4cj_sc_id3v2.mp3",
            scFakeMp3(scId3v2Title("Self Test Title"), scId3v1Title("legacy"))
        )

        let probe = detectFile(path)
        @Expect(probe.container, "mp3")
        @Expect(probe.codec, "")
        @Expect(probe.supported, true)

        // 伪流：有同步字但没有合法帧 → 打开即被拒绝
        @AssertThrows[CorruptedFileException](AudioFile.open(path))

        // 标签读取完全不受影响：ID3v2 优先于 ID3v1
        let tag = AudioFile.readTags(path)
        @Expect(tag.hasNoStandardFields(), false)
        @Expect(tag.title.getOrThrow(), "Self Test Title")
        remove(path)
    }
}

// ---------------------------------------------------------------------------
// 用例：FLAC 元数据块、多帧流式与定位、损坏拒绝
// ---------------------------------------------------------------------------

@Test
class SelfContainedFlacTest {
    /// VORBIS_COMMENT 块随 FLAC 一起被读出（标签不依赖任何外部素材）
    @TestCase
    func commentBlockIsExposedAsTag() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let comment = scVorbisCommentBody(
            "audio4cj-selftest",
            ["TITLE=合成标题", "ARTIST=合成艺术家", "ALBUM=合成专辑"]
        )
        let frame = scVerbatimFrame(samples, 16, 16, 0)
        let path = scWrite(
            "a4cj_sc_comment.flac",
            scFlacStream([frame], 44100, 16, 16, 16, Some(comment))
        )

        try (f = AudioFile.open(path)) {
            let tag = f.metadata()
            @Expect(tag.hasNoStandardFields(), false)
            @Expect(tag.title.getOrThrow(), "合成标题")
            @Expect(tag.artist.getOrThrow(), "合成艺术家")
            @Expect(tag.album.getOrThrow(), "合成专辑")
        }
        remove(path)
    }

    /// 多帧：流式读取不丢帧，且与 readAll 逐样本一致；seek 后从正确位置继续
    @TestCase
    func multiFrameStreamingAndSeekAgree() {
        let first: Array<Int32> = [
            0,
            100,
            -100,
            200,
            -200,
            300,
            -300,
            400,
            -400,
            500,
            -500,
            600,
            -600,
            700,
            -700,
            800
        ]
        let second: Array<Int32> = [
            900,
            -900,
            1000,
            -1000,
            1100,
            -1100,
            1200,
            -1200,
            1300,
            -1300,
            1400,
            -1400,
            1500,
            -1500,
            1600,
            -1600
        ]
        let frames = [
            scVerbatimFrame(first, 16, 16, 0),
            scVerbatimFrame(second, 16, 16, 1)
        ]
        let path = scWrite("a4cj_sc_multi.flac", scFlacStream(frames, 44100, 16, 32, 16, None))

        // 流式累计帧数
        try (f = AudioFile.open(path)) {
            var frames32: Int64 = 0
            while (let Some(chunk) <- f.stream().next()) {
                frames32 += chunk.frameCount
            }
            @Expect(frames32, 32)
        }

        // readAll：首尾样本必须与构造时写入的一致
        try (f2 = AudioFile.open(path)) {
            let all = f2.readAll()
            @Expect(all.frameCount, 32)
            @Expect(all.channels, 1)
            @Expect(all.sampleRate, 44100)
            @Expect(all.samples[0], 0.0)
            @Expect(all.samples[15], Float32(800) / 32768.0)
            @Expect(all.samples[16], Float32(900) / 32768.0)
        }

        // seek 到 0 ms 应回到开头
        try (f3 = AudioFile.open(path)) {
            @Expect(f3.seekTo(0), 0)
            let buf = f3.readFrames(1)
            @Expect(buf.frameCount, 1)
            @Expect(buf.samples[0], 0.0)
        }
        remove(path)
    }

    /// 负向：改坏帧体一个字节后，CRC-16 必须让解码失败（而不是静默给出错误 PCM）
    @TestCase
    func corruptedFrameIsRejected() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let good = scSimpleFlac(samples)
        // 倒数第 3 字节位于帧体样本区（最后 2 字节是 CRC-16）
        let broken = scFlip(good, good.size - 3)
        let path = scWrite("a4cj_sc_broken.flac", broken)

        var rejected = false
        try {
            try (f = AudioFile.open(path)) {
                let buf = f.readAll()
                // 若实现容忍了损坏，这里会读到被篡改的样本 —— 那正是本用例要抓的缺陷
                @Assert(buf.sampleCount > 0)
            }
        } catch (e: CorruptedFileException) {
            rejected = true
        }
        @Expect(rejected, true)
        remove(path)
    }
}

// ---------------------------------------------------------------------------
// 用例：Ogg 封装的 FLAC
// ---------------------------------------------------------------------------

@Test
class SelfContainedOggFlacTest {
    /// 容器与子编码分开可读：ogg + flac
    @TestCase
    func oggFormatReportsContainerAndSubCodec() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let path = scWrite("a4cj_sc_oggfmt.oga", scOggFlacBytes(scSimpleFlac(samples), 31))

        try (f = AudioFile.open(path)) {
            let info = f.format()
            @Expect(info.container, "ogg")
            @Expect(info.codec, "flac")
            @Expect(info.codecId, "ogg/flac")
            @Expect(f.tracks().size, 1)
        }
        remove(path)
    }

    /// **无损互证**：同一段样本的原生 FLAC 与 Ogg 封装解码结果必须逐位相同。
    ///
    /// 这条同时覆盖"页重组"与"跨页续传"：构造时把流拆成两页，若实现漏掉续传
    /// 或不按序拼接，解码结果会立刻不等。
    @TestCase
    func oggWrappedFlacDecodesIdenticalToNative() {
        let samples: Array<Int32> = [
            0,
            1,
            -1,
            2,
            -2,
            3,
            -3,
            4,
            -4,
            5,
            -5,
            6,
            -6,
            7,
            -7,
            8,
            16384,
            -16384,
            32767,
            -32768,
            100,
            -100,
            1000,
            -1000,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
        ]
        let frames = [
            scVerbatimFrame(samples[0..16], 16, 16, 0),
            scVerbatimFrame(samples[16..32], 16, 16, 1)
        ]
        let flac = scFlacStream(frames, 44100, 16, 32, 16, None)

        let nativePath = scWrite("a4cj_sc_native.flac", flac)
        let oggPath = scWrite("a4cj_sc_wrapped.oga", scOggFlacBytes(flac, 42))

        var native = Array<Float32>(0, repeat: 0.0)
        try (f = AudioFile.open(nativePath)) {
            native = f.readAll().samples
        }

        var wrapped = Array<Float32>(0, repeat: 0.0)
        try (f2 = AudioFile.open(oggPath)) {
            wrapped = f2.readAll().samples
        }

        @Expect(wrapped.size, native.size)
        @Expect(native.size, 32)
        var i: Int64 = 0
        while (i < native.size) {
            @Expect(wrapped[i], native[i])
            i += 1
        }
        remove(nativePath)
        remove(oggPath)
    }

    /// FLAC-in-Ogg 的标签：头部元数据块链复原后交给 FLAC 的标签解析
    @TestCase
    func oggFlacCommentIsReadAsTag() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let comment = scVorbisCommentBody("audio4cj-selftest", ["TITLE=Ogg 里的标题"])
        let frame = scVerbatimFrame(samples, 16, 16, 0)
        let flac = scFlacStream([frame], 44100, 16, 16, 16, Some(comment))
        let path = scWrite("a4cj_sc_oggtag.oga", scOggFlacBytes(flac, 55))

        let tag = AudioFile.readTags(path)
        @Expect(tag.hasNoStandardFields(), false)
        @Expect(tag.title.getOrThrow(), "Ogg 里的标题")
        remove(path)
    }

    /// 负向：页 CRC-32 被改坏后必须报错。
    ///
    /// 本库的 Ogg/FLAC 源**每页都校验 CRC**（含被跳过的页），故篡改页体一定暴露。
    @TestCase
    func corruptedPageCrcIsRejected() {
        let samples: Array<Int32> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let good = scOggFlacBytes(scSimpleFlac(samples), 66)
        // 第二页的页体在后半段 —— 改其中一字节，页 CRC 必然失配
        let broken = scFlip(good, good.size - 10)
        let path = scWrite("a4cj_sc_badcrc.oga", broken)

        var rejected = false
        try {
            try (f = AudioFile.open(path)) {
                let buf = f.readAll()
                @Assert(buf.sampleCount > 0)
            }
        } catch (e: CorruptedFileException) {
            rejected = true
        }
        @Expect(rejected, true)
        remove(path)
    }
}

// ---------------------------------------------------------------------------
// 用例：MP4 标签（box 树手搭）
// ---------------------------------------------------------------------------

@Test
class SelfContainedMp4Test {
    /// 文本类原子：©nam / ©ART / ©alb / ©day
    @TestCase
    func textAtomsAreRead() {
        let ilst = ArrayList<UInt8>()
        for (b in scMp4TextItem("nam", "MP4 标题")) {
            ilst.add(b)
        }
        for (b in scMp4TextItem("ART", "MP4 艺术家")) {
            ilst.add(b)
        }
        for (b in scMp4TextItem("alb", "MP4 专辑")) {
            ilst.add(b)
        }
        for (b in scMp4TextItem("day", "2026")) {
            ilst.add(b)
        }

        let path = scWrite("a4cj_sc_tags.m4a", scMp4Bytes(ilst.toArray(), 0, 0))
        let tag = AudioFile.readTags(path)
        @Expect(tag.hasNoStandardFields(), false)
        @Expect(tag.title.getOrThrow(), "MP4 标题")
        @Expect(tag.artist.getOrThrow(), "MP4 艺术家")
        @Expect(tag.album.getOrThrow(), "MP4 专辑")
        @Expect(tag.year.getOrThrow(), "2026")
        remove(path)
    }

    /// moov 在文件末尾（主流封装工具的默认布局）：mdat 里夹入 "moov" 干扰字样，
    /// 验证定位靠长度关系而不是搜字符串。
    @TestCase
    func trailingMoovIsFound() {
        let ilst = ArrayList<UInt8>()
        for (b in scMp4TextItem("nam", "尾部 moov 的标题")) {
            ilst.add(b)
        }
        // 512 字节的 mdat，其中全是 "moov" 干扰
        let path = scWrite("a4cj_sc_tail.m4a", scMp4Bytes(ilst.toArray(), 512, 0))

        let tag = AudioFile.readTags(path)
        @Expect(tag.title.getOrThrow(), "尾部 moov 的标题")
        remove(path)
    }

    /// meta 是 FullBox：version/flags 非零时也必须正确跳过 4 字节。
    /// 若实现"假定这 4 字节为 0"或"干脆不跳"，本用例会失败。
    @TestCase
    func metaFullBoxFlagsAreRespected() {
        let ilst = ArrayList<UInt8>()
        for (b in scMp4TextItem("nam", "带 flags 的 meta")) {
            ilst.add(b)
        }
        let path = scWrite("a4cj_sc_flags.m4a", scMp4Bytes(ilst.toArray(), 0, 0x01000000))

        let tag = AudioFile.readTags(path)
        @Expect(tag.title.getOrThrow(), "带 flags 的 meta")
        remove(path)
    }
}
