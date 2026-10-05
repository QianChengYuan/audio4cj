package audio4cj.probe

import std.fs.*

/* ============================================================================
 * 魔数探测层 —— 开发文档 §2.1 / §4.1
 *
 * 设计原则：
 *   - **魔数优先，扩展名兜底**（扩展名可被篡改，不可信）
 *   - 只读文件头部一小段即可判定音频容器，毫秒级（窗口大小见 PROBE_HEAD_SIZE）
 *   - 自研而非复用第三方（§2.3）：本项目只需识别音频分类的十余种格式，
 *     自研表约 100 行且完全可控，避免为几条魔数引入仓库依赖
 *
 * 容器族说明：
 *   某些魔数是**容器族**而非具体格式，需要多读几个字节才能区分：
 *   - "RIFF" + "WAVE" = WAV；"RIFF" + "AVI " = AVI
 *   - "FORM" + "AIFF"/"AIFC" = AIFF 系
 *   - "ftyp" 位于偏移 4（前置 4 字节为 box 长度）
 *   - "OggS" 还需读**首个页面的 payload** 才能分辨 Vorbis / Opus / FLAC / Speex
 *
 * 本层只负责**识别**，不负责解码。「是否可解码」由 supported 字段如实标注：
 * 目前 WAV / FLAC / **Ogg 封装的 FLAC** 为 true（三者都是本库的纯仓颉实现）；
 * **MP3 自本版本起为 false**（它能被识别、标签也能读，但解码曾依赖第三方 C 库，
 * 已移出范围 —— 取舍记录见 docs/codec-expansion-assessment.md）；
 * 其余容器（Ogg/Vorbis、Ogg/Opus、MP4、APE、WMA 等）同样会被准确
 * 识别、同样给出子编码，只是 supported 为 false。这样做的目的是让
 * FormatNotSupportedException 的信息能精确到编码级，而非笼统的"不支持"。
 * ========================================================================== */

/// 探测结果。
protected class ProbeResult {
    /// 容器标识（小写），如 "wav" / "flac" / "mp3" / "ogg" / "unknown"。
    public let container: String

    /// 对应的 MIME 类型（识别失败时为 application/octet-stream）。
    public let mimeType: String

    /// 该「容器 + 子编码」组合当前是否可解码。
    ///
    /// 注意这不是「容器是否认识」：认识但不支持的容器很多（Ogg/Vorbis、MP4、
    /// APE 等），它们同样被准确识别，只是此处为 false。
    public let supported: Bool

    /// 容器内的**子编码**标识，用于把「不支持」的信息精确到编码级。
    ///
    ///   Ogg  -> "vorbis" / "opus" / "flac" / "speex"；判定不出时为空串
    ///   其余 -> 空串（这些容器本身即编码，无子编码可分）
    ///
    /// 用**命名参数 + 默认值**承载：绝大多数构造点没有子编码，这样它们一行都不用改。
    public let codec: String

    public init(
        container: String,
        mimeType: String,
        supported: Bool,
        codec!: String = ""
    ) {
        this.container = container
        this.mimeType = mimeType
        this.supported = supported
        this.codec = codec
    }
}

/// 用于探测的头部字节数。
///
/// 绝大多数容器 16 字节足矣（魔数都在起始处），但 **Ogg 的子编码判定必须读到
/// 首个页面的 payload**：页头固定 27 字节，其后是 segment table（段数由第 26
/// 字节给出，上限 255），再往后才是 payload 起点。加上最长 8 字节的子编码标识，
/// 理论最坏需要 27 + 255 + 8 = 290 字节。
///
/// 取 512（向上取整到好记的值）以覆盖任何合法页，不值得为此再分档读取 ——
/// 每文件多读几百字节，相对后续的解码开销可以忽略。
///
/// 历史教训：本常量原为 16，那时**连 Ogg 的 payload 起点（第 28 字节）都到不了**，
/// 子编码判定必然全部落空 —— 这也是"不支持"信息一直笼统到容器级的原因。
protected let PROBE_HEAD_SIZE: Int64 = 512

/// 从文件路径探测容器格式。
/// 文件不存在或无权限时由 std.fs 抛出 FSException，由门面层转译为库异常。
protected func detectFile(path: String): ProbeResult {
    detectBytes(readHead(path, PROBE_HEAD_SIZE))
}

/// 从头部字节探测容器格式。
protected func detectBytes(head: Array<UInt8>): ProbeResult {
    // ---- RIFF 容器族（需读偏移 8 的子类型）----
    if (matchAt(head, 0, ascii("RIFF"))) {
        if (matchAt(head, 8, ascii("WAVE"))) {
            return ProbeResult("wav", "audio/wav", true)
        }
        if (matchAt(head, 8, ascii("AVI "))) {
            return ProbeResult("avi", "video/x-msvideo", false)
        }
        return ProbeResult("riff", "application/riff", false)
    }

    // ---- FORM 容器族（AIFF / AIFC）----
    if (matchAt(head, 0, ascii("FORM"))) {
        if (matchAt(head, 8, ascii("AIFF"))) {
            return ProbeResult("aiff", "audio/aiff", false)
        }
        if (matchAt(head, 8, ascii("AIFC"))) {
            return ProbeResult("aifc", "audio/aiff", false)
        }
        return ProbeResult("form", "application/form", false)
    }

    // ---- 单标识容器 ----
    if (matchAt(head, 0, ascii("fLaC"))) {
        return ProbeResult("flac", "audio/flac", true)
    }
    // ---- Ogg 容器族（必须读首个页面的 payload 才能分辨子编码）----
    if (matchAt(head, 0, ascii("OggS"))) {
        let codec = detectOggCodec(head)
        // Ogg 封装的 FLAC 是**可解码的**：本库有它自己的纯仓颉实现 —— 先把各页
        // 页体重建成一条与原生 FLAC 逐字节等同的流，再走同一套解码逻辑
        // （见 format/ogg_flac_source.cj）。这一点起初是借第三方实现对 Ogg 的
        // transparent 支持接出来的，现已不依赖任何 C 实现。
        // 其余 Ogg 子编码（Vorbis / Opus / Speex）当前没有可用解码器。
        return ProbeResult("ogg", "audio/ogg", codec == "flac", codec: codec)
    }
    if (matchAt(head, 0, ascii("wvpk"))) {
        return ProbeResult("wavpack", "audio/wavpack", false)
    }
    if (matchAt(head, 0, ascii("MAC "))) {
        return ProbeResult("ape", "audio/x-ape", false)
    }
    if (matchAt(head, 0, ascii("MThd"))) {
        return ProbeResult("midi", "audio/midi", false)
    }
    if (matchAt(head, 0, ascii(".snd"))) {
        return ProbeResult("au", "audio/basic", false)
    }
    if (matchAt(head, 0, ascii("#!AMR"))) {
        return ProbeResult("amr", "audio/amr", false)
    }

    // ---- MP4 系（"ftyp" 在偏移 4，前 4 字节为 box 长度）----
    if (matchAt(head, 4, ascii("ftyp"))) {
        return ProbeResult("mp4", "audio/mp4", false)
    }

    // ---- ID3v2 标记的 MP3 ----
    // 【supported = false 的确切含义】容器识别照旧（仍返回 container="mp3"），
    // 但**解码不受支持** —— MP3 解码曾依赖第三方 C 库，已移出本版本范围。
    // 标签读取不受影响：readTags 走的是与 supported 无关的另一条分派。
    if (matchAt(head, 0, ascii("ID3"))) {
        return ProbeResult("mp3", "audio/mpeg", false)
    }

    // ---- ASF / WMA：GUID 首 4 字节 30 26 B2 75 ----
    if (matchAt(head, 0, [0x30, 0x26, 0xB2, 0x75])) {
        return ProbeResult("asf", "audio/x-ms-wma", false)
    }

    // ---- ADTS 封装的 AAC：0xFFF，layer=00，且 layer 位为 0 ----
    if (isAdtsAac(head)) {
        return ProbeResult("aac", "audio/aac", false)
    }

    // ---- 裸 MPEG 音频帧同步（0xFF 后高 3 位全 1）----
    // 这是 MP3 的**第二个识别入口**（无 ID3 标记的裸流）：supported 同样为 false，
    // 理由见上。两个入口都要改 —— 只改一个会让"裸流 MP3"仍被当作可解码。
    if (isMpegSync(head)) {
        return ProbeResult("mp3", "audio/mpeg", false)
    }

    ProbeResult("unknown", "application/octet-stream", false)
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------

/// 读取文件头部 n 字节；文件较短时尾部以 0 填充（匹配时会因越界而失败）。
private func readHead(path: String, n: Int64): Array<UInt8> {
    let buf = Array<UInt8>(n, repeat: 0)
    try (f = File(path, Read)) {
        let _ = f.read(buf)
    }
    buf
}

/// 判断 head[offset..] 是否以 magic 开头；越界返回 false。
private func matchAt(head: Array<UInt8>, offset: Int64, magic: Array<UInt8>): Bool {
    if (offset < 0 || offset + magic.size > head.size) {
        return false
    }
    for (i in 0..magic.size) {
        if (head[offset + i] != magic[i]) {
            return false
        }
    }
    true
}

/// ASCII 字符串转字节数组（仅用于魔数常量，不涉及多字节字符）。
private func ascii(s: String): Array<UInt8> {
    s.toArray()
}

/// 裸 MPEG 帧同步：第 1 字节 0xFF，第 2 字节高 3 位全 1。
private func isMpegSync(head: Array<UInt8>): Bool {
    if (head.size < 2) {
        return false
    }
    let mask = UInt8(0xE0)
    (head[0] == UInt8(0xFF)) && ((head[1] & mask) == mask)
}

/// ADTS 封装 AAC：0xFFF 同步字 + layer 字段为 00。
/// 第 2 字节高 4 位为 1111，第 5-6 位（layer）为 00。
private func isAdtsAac(head: Array<UInt8>): Bool {
    if (head.size < 2) {
        return false
    }
    if (head[0] != UInt8(0xFF)) {
        return false
    }
    let high4 = UInt8(0xF0)
    let layerBits = UInt8(0x06)
    ((head[1] & high4) == high4) && ((head[1] & layerBits) == UInt8(0))
}

/// Ogg payload 中以**非 ASCII 字节开头**的两个子编码标识。
///
///   OGG_MAGIC_FLAC   = 0x7F + "FLAC"     （0x7F 是 FLAC 映射头的固定首字节）
///   OGG_MAGIC_VORBIS = 0x01 + "vorbis"   （0x01 是 identification header 的 packet 类型）
///
/// 刻意写成字节数组而不是字符串常量：这两个标识不是可打印文本，
/// 若写成字符串很容易被误读成普通 ASCII 魔数（"FLAC"、"vorbis"）。
private let OGG_MAGIC_FLAC: Array<UInt8> = [0x7F, 0x46, 0x4C, 0x41, 0x43]
private let OGG_MAGIC_VORBIS: Array<UInt8> = [0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]

/// 判定 Ogg 容器的子编码，返回 "opus" / "flac" / "vorbis" / "speex"；
/// 无法判定时返回**空串**（表示"有 Ogg 容器但认不出子编码"，不是错误）。
///
/// 【为什么 payload 起点不能写死】
///   Ogg 页头固定 27 字节，其后是 segment table（lacing 值），段数由第 26 字节
///   `head[26]` 给出，因此 payload 起点 = 27 + head[26]。**写死第 28 字节会在
///   多段页上错位**；而 `head[26]` 直接来自文件内容、可能取任意值（畸形文件
///   甚至写 255），所以必须先做越界防护再判定。
///
///   实测印证：本脚本生成的 Ogg 首页面段数为 1，payload 落在第 28 字节；
///   但"段数为 1"只是常见情形，不是规范保证。
///
/// 【四种标识都在 payload 起始处，但长度不同】
///   以最长的 8 字节（OpusHead / "Speex   "）为准做统一防护。
private func detectOggCodec(head: Array<UInt8>): String {
    // 连页头的第 26 字节都读不到，无从判定
    if (head.size <= 26) {
        return ""
    }

    let start = 27 + Int64(head[26])

    // 刻意**不做统一的"至少 8 字节"预检**：四种标识长度并不相同 ——
    // FLAC 为 5 字节（0x7F"FLAC"）、Vorbis 为 7 字节（0x01"vorbis"）、
    // Opus 与 Speex 为 8 字节。若按最长者统一预检，一个 payload 恰好只有
    // 7 字节的 Vorbis 会被误判成"判不出"（本用例初版即踩此坑：合成页正好
    // 35 字节，越界预检把正确的匹配挡在了外面）。
    //
    // 越界安全不依赖这个预检，而由 matchAt 逐条保证 ——
    // 它在 offset + magic.size 越界时直接返回 false。
    if (matchAt(head, start, ascii("OpusHead"))) {
        return "opus"
    }
    if (matchAt(head, start, OGG_MAGIC_FLAC)) {
        return "flac"
    }
    if (matchAt(head, start, OGG_MAGIC_VORBIS)) {
        return "vorbis"
    }
    if (matchAt(head, start, ascii("Speex   "))) {
        return "speex"
    }
    ""
}
