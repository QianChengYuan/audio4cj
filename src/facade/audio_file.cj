package audio4cj.facade

import audio4cj.core.*
import audio4cj.meta.*
import audio4cj.pcm.AudioBuffer
import audio4cj.stream.FrameStream
import audio4cj.probe.*
import audio4cj.format.*
import audio4cj.codec.*
import std.collection.*

/* ============================================================================
 * AudioFile —— 开发文档 §4.4
 *
 * 对外唯一入口。实现 Resource 接口以支持 try-with-resources 自动释放：
 *
 *     try (f = AudioFile.open("song.wav")) {
 *         let info = f.info()
 *         let s = f.stream()
 *         while (let Some(chunk) <- s.next()) { ... }
 *     }
 *
 * 禁止依赖终结器（~init）兜底释放：
 *   终结器触发时机不确定、可能在任意线程运行、抛异常属未定义行为、
 *   带终结器的类不能是 open，且构造失败的对象的终结器不会执行。
 *
 * 并发约定：本类**非线程安全**（reader 持有可变游标）。
 *   多文件并行处理请为每个文件创建独立实例（§4.7）。
 *
 * 当前可解码范围（与 probe 层的 supported 字段保持一致）：
 *   WAV、**FLAC**、**Ogg 封装的 FLAC**、**MP3** —— 四者均为**纯仓颉实现**。
 *
 * 【MP3 已回到解码范围（纯仓颉内核）】它曾是唯一依赖 C 库的格式，因而被移出
 *   过一版；如今由本库自己的解码内核（format/mp3_decode.cj）承担，
 *   与 WAV / FLAC 一样**不引入任何 C 依赖**。其标签读取一直可用（见 readTags）。
 * ========================================================================== */
public class AudioFile <: Resource {
    private var _closed: Bool = false
    private let _path: String
    private let _reader: ?FormatReader
    private let _decoder: ?Decoder

    /// 探测结果固化下来的格式描述（见 `format()`）。
    private let _format: FormatInfo

    /// 轨道信息**快照**（见 `tracks()`）。
    private let _tracks: Array<Track>

    /// 无后端构造：M1 契约测试使用（数据方法会抛"未绑定解码后端"）。
    protected init(path: String) {
        this._path = path
        this._reader = None
        this._decoder = None
        this._format = FormatInfo("unknown", "", "unknown", "application/octet-stream")
        this._tracks = Array<Track>(0, repeat: Track(0, "", 0, 0))
    }

    /// 绑定后端的构造，由 open() 在探测成功后调用。
    ///
    /// `formatInfo` 由探测结果固化成值类型；`tracks` 在此**快照**一份 ——
    /// reader 一旦关闭就无法再查询，而格式信息在文件关闭后仍应可读。
    protected init(path: String, reader: FormatReader, decoder: Decoder, formatInfo: FormatInfo) {
        this._path = path
        this._reader = reader
        this._decoder = decoder
        this._format = formatInfo
        this._tracks = reader.tracks()
    }

    /// 打开音频文件：魔数探测 → 选择实现 → 绑定后端。
    ///
    /// 错误语义（§4.1）：
    ///   文件不存在 / 无权限 -> std.fs 的 FSException（IOException 子类）
    ///   格式不支持          -> FormatNotSupportedException
    ///   结构损坏            -> CorruptedFileException
    public static func open(path: String): AudioFile {
        let probe = detectFile(path)

        if (!probe.supported) {
            // 【为什么提示里要点出 readTags】部分容器（如 Ogg/Vorbis、MP4）虽然
            // 尚不能解码，但**标签是可读的**（见 readTags）。只回一句"不支持"
            // 会让使用者以为整个文件都用不了。
            throw FormatNotSupportedException(
                "不支持的音频格式：${formatLabel(probe)}（${probe.mimeType}）。" +
                    "当前可解码 WAV / FLAC / MP3，以及 Ogg 封装的 FLAC；" +
                    "其余容器可能仍可用 AudioFile.readTags 读取标签。")
        }

        // 把探测结果固化成值类型，随 AudioFile 一起保留 ——
        // 否则这份判定只用来选实现，使用者永远看不到它。
        let formatInfo = formatInfoOf(probe)

        match (probe.container) {
            case "wav" =>
                let reader = WavFormatReader(path)
                let decoder = WavPcmDecoder(
                    reader.bitsPerSample(),
                    reader.channels(),
                    reader.sampleRate()
                )
                AudioFile(path, reader, decoder, formatInfo)
            case "flac" => openFlac(path, formatInfo, false)
            case "mp3" => openMp3(path, formatInfo)
            case "ogg" =>
                // 目前只有 Ogg 封装的 FLAC 可解码，它在 supported 检查处已通过。
                // 这里再做一次显式判断并非冗余：它把「容器级」与「编码级」两道
                // 关卡分开，将来若 supported 的判定被改动，也不会静默走错读取器。
                if (probe.codec != "flac") {
                    throw FormatNotSupportedException("Ogg 容器内的 ${probe.codec} 编码尚无解码实现（${path}）")
                }
                openFlac(path, formatInfo, true)
            case _ => throw FormatNotSupportedException("容器 ${formatLabel(probe)} 尚无对应实现（${path}）")
        }
    }

    /// 以 FLAC 读取器 + 解码器装配 `AudioFile`。
    ///
    /// 原生 FLAC 与 **Ogg 封装的 FLAC 共用这一条装配路径**，内核也是同一个
    /// （纯仓颉）—— 容器差异在更下层，由**字节源**承担（见 flac.cj 的类头说明）。
    /// `oggWrapped` 就是从这里传下去的：它只决定"字节流是不是 Ogg 重建出来的"。
    /// 本函数的两个调用点各自处在 "flac" 与 "ogg" 分支里，容器是已知事实，
    /// 无需让下层的读取器再识别一次。
    private static func openFlac(path: String, formatInfo: FormatInfo, oggWrapped: Bool): AudioFile {
        let reader = FlacFormatReader(path, oggWrapped)
        let decoder = FlacPcmDecoder(
            reader.sampleRate(),
            reader.channels(),
            reader.bitsPerSample(),
            reader.totalFrames()
        )
        AudioFile(path, reader, decoder, formatInfo)
    }

    /// 以 MP3 读取器 + 解码器装配 `AudioFile`。
    ///
    /// 与 FLAC 装配同构：读取器（demuxer）持有纯仓颉解码内核与读取进度，
    /// 解码器只做 f32 字节的视角转换。MP3 的位深恒为 32（表示 float32，
    /// 而非 32 位整数 PCM），由 `Mp3PcmDecoder.codecParams` / `info()` 报告。
    private static func openMp3(path: String, formatInfo: FormatInfo): AudioFile {
        let reader = Mp3FormatReader(path)
        let decoder = Mp3PcmDecoder(
            reader.sampleRate(),
            reader.channels(),
            reader.totalFrames()
        )
        AudioFile(path, reader, decoder, formatInfo)
    }

    /// 把探测结果固化成公开的值类型。
    ///
    /// `codecId` 复用 `formatLabel()` —— 异常信息里用的就是它，
    /// 两处共用同一渲染规则，不会出现"日志里写 ogg/flac、字段里写 flac"这种分叉。
    private static func formatInfoOf(probe: ProbeResult): FormatInfo {
        FormatInfo(probe.container, probe.codec, formatLabel(probe), probe.mimeType)
    }

    /// 把探测结果渲染成便于阅读的格式标签，如 "wav"、"ogg/vorbis"。
    ///
    /// 子编码已知时一并带上，这样「不支持」的信息能精确到编码级 ——
    /// 例如 Ogg 里装的是 Vorbis 还是 Opus，用户的处置完全不同。
    private static func formatLabel(probe: ProbeResult): String {
        if (probe.codec.isEmpty()) {
            probe.container
        } else {
            "${probe.container}/${probe.codec}"
        }
    }

    /// 读取标签，**不要求容器可解码**（M3 新增）。
    ///
    /// 与 `open()` 的关键区别：本方法**不校验容器的解码支持状态**，
    /// 因此 MP3、FLAC 等尚无解码实现的格式也能读出标签。
    ///
    /// 支持情况（M3）：
    ///
    ///   | 容器 | 标签来源 |
    ///   |------|----------|
    ///   | mp3  | ID3v2（文件头，优先）+ ID3v1（文件尾 128 字节），逐字段合并 |
    ///   | flac | `VORBIS_COMMENT` 元数据块 |
    ///   | wav  | `LIST/INFO` 子块 |
    ///   | ogg  | 页重组后取注释头：Vorbis / Opus 走 Vorbis comment，FLAC-in-Ogg 走元数据块链 |
    ///   | mp4  | `moov/udta/meta/ilst` 原子（`moov` 在文件头或文件尾都能定位） |
    ///
    /// 无标签时返回**空 Tag**（各字段为 None），**绝不返回 None**（§4.1 铁律 1）。
    ///
    /// 抛出：
    ///   - 文件不存在 / 无权限 → `std.fs` 的 `FSException`
    ///   - 无法识别的格式，或该容器的标签读取尚未实现 → `FormatNotSupportedException`
    ///   - 文件结构损坏（如 WAV 缺少 fmt/data chunk）→ `CorruptedFileException`
    public static func readTags(path: String): Tag {
        let probe = detectFile(path)

        match (probe.container) {
            case "mp3" => readMp3TagsFromFile(path)
            case "flac" => readFlacTagsFromFile(path)
            case "wav" => readWavTags(path)
            case "ogg" => readOggTagsFromFile(path)
            case "mp4" => readMp4TagsFromFile(path)
            case "unknown" => throw FormatNotSupportedException("无法识别的文件格式，无法读取标签：${path}")
            case other => throw FormatNotSupportedException("容器 ${other} 的标签读取尚未实现：${path}")
        }
    }

    /// 文件路径。
    public prop path: String {
        get() {
            _path
        }
    }

    /// 读取标签。无标签时返回各字段为 None 的**空 Tag**，绝不返回 None。
    public func metadata(): Tag {
        checkOpen()
        reader().metadata()
    }

    /// 读取音频基本信息。
    public func info(): AudioInfo {
        checkOpen()
        reader().info()
    }

    /// 容器与编码描述（探测结果）。
    ///
    /// **不要求后端仍打开**：探测结果在 `open()` 时已固化成值类型，因此文件
    /// 关闭后依然可读。这是有意的 —— 媒体库扫盘这类场景通常是"先看是什么格式，
    /// 再决定要不要解码"，不该为了问一句格式而保持文件打开。
    public func format(): FormatInfo {
        _format
    }

    /// 轨道信息（`open()` 时**快照**，同样在关闭后仍可读）。
    ///
    /// 当前所有受支持的容器都是单轨，故数组长度为 1；保留数组形态是为了
    /// 将来接入多轨容器时不必改动签名。
    public func tracks(): Array<Track> {
        _tracks
    }

    /// 获取流式读取器（主 API）。多次调用共享同一底层游标。
    public func stream(): FrameStream {
        checkOpen()
        FrameStream(reader(), decoder())
    }

    /// 全量解码（便捷 API，非主推）。
    /// 注意内存：f32 交错下 44.1kHz 立体声 1 小时约 1.27 GB，
    /// maxFrames 为安全上限，避免大文件把内存吃满。**优先使用 stream()**。
    public func readAll(maxFrames!: Int64 = 10_000_000): AudioBuffer {
        checkOpen()
        drain(maxFrames)
    }

    /// 读取指定帧数（最多 count 帧）。
    public func readFrames(count: Int64): AudioBuffer {
        checkOpen()
        drain(count)
    }

    /// 按毫秒寻址，返回**实际落点毫秒**。
    public func seekTo(timestampMs: Int64): Int64 {
        checkOpen()
        reader().seekTo(timestampMs)
    }

    // ------------------------------------------------------------------
    // Resource
    // ------------------------------------------------------------------

    public func isClosed(): Bool {
        _closed
    }

    /// 释放资源（幂等）。会一并关闭底层 reader。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            match (_reader) {
                case Some(r) => r.close()
                case None => ()
            }
        }
    }

    // ------------------------------------------------------------------
    // 标签读取（readTags 的内部分派）
    //
    // MP3 与 FLAC 的**文件级**读取已下沉到 meta 层的 file_tags.cj，
    // 避免同一套「读文件中的标签」逻辑在多处分叉。
    // （MP3 侧不再被 Mp3FormatReader 复用 —— 该读取器已随解码能力一并移除；
    //   但这条下沉路径仍由本层的 readMp3TagsFromFile 使用。）
    //
    // WAV 的标签读取需要复用 WavFormatReader 的 RIFF 扫描结果，故留在本层。
    // ------------------------------------------------------------------

    /// WAV：复用 `WavFormatReader` 的 RIFF 扫描结果（其中已收集 `LIST/INFO`）。
    private static func readWavTags(path: String): Tag {
        var result = Tag()
        try (r = WavFormatReader(path)) {
            result = r.metadata()
        }
        result
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    private func checkOpen(): Unit {
        if (_closed) {
            throw ClosedResourceException("对已关闭的 AudioFile 执行操作（${_path}）")
        }
    }

    private func reader(): FormatReader {
        match (_reader) {
            case Some(r) => r
            case None => throw Audio4CjException("该 AudioFile 未绑定解码后端（${_path}）")
        }
    }

    private func decoder(): Decoder {
        match (_decoder) {
            case Some(d) => d
            case None => throw Audio4CjException("该 AudioFile 未绑定解码后端（${_path}）")
        }
    }

    /// 从流中累积至多 limitFrames 帧并合并为单个 AudioBuffer。
    private func drain(limitFrames: Int64): AudioBuffer {
        if (limitFrames <= 0) {
            return AudioBuffer(0, 0, Array<Float32>())
        }

        let s = stream()
        let chunks = ArrayList<AudioBuffer>()
        var totalFrames: Int64 = 0
        var sampleRate: Int64 = 0
        var channels: Int64 = 0

        while (totalFrames < limitFrames) {
            match (s.next()) {
                case Some(buf) =>
                    if (sampleRate == 0) {
                        sampleRate = buf.sampleRate
                        channels = buf.channels
                    }
                    chunks.add(buf)
                    totalFrames += buf.frameCount
                case None => break
            }
        }
        s.close()
        // stream() 返回的流与 AudioFile 共享底层 reader，s.close() 已经把关掉的
        // reader 释放了：此后 info()/metadata()/stream() 都会抛
        // ClosedResourceException。故这里必须同步置位关闭状态，否则
        // isClosed() 返回 false 而几乎每个成员方法都抛异常，同一对象的状态
        // 自相矛盾（历史缺陷）。readAll/readFrames 是一次性便捷 API，
        // 消费完即视为资源已释放；需要继续分块读取请自行持有 stream()。
        _closed = true

        mergeChunks(chunks, sampleRate, channels, limitFrames)
    }

    /// 合并分块并按 limitFrames 截断。
    private func mergeChunks(
        chunks: ArrayList<AudioBuffer>,
        sampleRate: Int64,
        channels: Int64,
        limitFrames: Int64
    ): AudioBuffer {
        if (chunks.size == 0) {
            return AudioBuffer(sampleRate, channels, Array<Float32>())
        }

        var total: Int64 = 0
        for (c in chunks) {
            total += c.sampleCount
        }

        let maxSamples = if (channels > 0) {
            limitFrames * channels
        } else {
            0
        }
        var take = total
        if (maxSamples > 0 && take > maxSamples) {
            take = maxSamples
        }

        let out = Array<Float32>(take, repeat: 0.0)
        var written: Int64 = 0
        for (c in chunks) {
            if (written >= take) {
                break
            }
            let n = c.sampleCount
            if (written + n <= take) {
                // 整块搬入：走 copyInto，避免 `samples` 再整块复制一次
                // （AudioBuffer.samples 现在返回副本，属于热路径开销）
                written += c.copyInto(out, written)
            } else {
                // 最后一块只需一部分：逐样本拷以保留「按 limitFrames 截断」语义
                let src = c.samples
                var i: Int64 = 0
                while (i < src.size && written < take) {
                    out[written] = src[i]
                    written += 1
                    i += 1
                }
            }
        }

        AudioBuffer(sampleRate, channels, out)
    }
}
