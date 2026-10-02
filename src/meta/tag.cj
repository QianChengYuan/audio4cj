package audio4cj.meta

import std.collection.*

/* ============================================================================
 * 统一标签模型 —— 开发文档 §4.3
 *
 * 这是本项目**最核心的差异化价值**：把 ID3v1 / ID3v2 / Vorbis comment /
 * MP4 atoms / APE 五种标签体系收敛为同一个 Tag。
 *
 * Option 语义（§4.1 铁律 1）：`None` 仅表示「该字段不存在」，
 * 绝不用来表示错误。因此 metadata() 在文件无标签时应返回一个
 * 各字段均为 None 的**空 Tag**，而不是 None。
 *
 * extra 字段用于承载各标签体系的冷门字段，
 * 避免为个别字段反复改动接口。
 * ========================================================================== */

/// 统一的音频标签模型。
public class Tag {
    public var title: ?String = None
    public var artist: ?String = None
    public var album: ?String = None
    public var albumArtist: ?String = None
    public var year: ?String = None
    public var genre: ?String = None
    public var track: ?Int64 = None
    public var trackTotal: ?Int64 = None
    public var disc: ?Int64 = None
    public var comment: ?String = None
    public var composer: ?String = None

    /// 封面图原始字节（APIC / PICTURE / covr 统一为此形式）
    public var coverArt: ?Array<UInt8> = None

    /// 封面图的 MIME 类型，如 "image/jpeg"
    public var coverMime: ?String = None

    /// 各标签体系特有字段的兜底容器（如 "TPE2" / "TXXX:xxx" / 自定义 atom）
    public var extra: HashMap<String, String> = HashMap<String, String>()

    public init() {}

    /// 写一个兜底字段（链式便利方法）。
    public func putExtra(key: String, value: String): Unit {
        extra[key] = value
    }

    /// 读一个兜底字段。
    public func getExtra(key: String): ?String {
        extra.get(key)
    }

    /// 是否所有**标准字段**都为空（不含 extra）。
    /// 用于判断"该文件没有可用标签"。
    public func hasNoStandardFields(): Bool {
        if (let Some(_) <- title) {
            return false
        }
        if (let Some(_) <- artist) {
            return false
        }
        if (let Some(_) <- album) {
            return false
        }
        if (let Some(_) <- albumArtist) {
            return false
        }
        if (let Some(_) <- year) {
            return false
        }
        if (let Some(_) <- genre) {
            return false
        }
        if (let Some(_) <- track) {
            return false
        }
        if (let Some(_) <- trackTotal) {
            return false
        }
        if (let Some(_) <- disc) {
            return false
        }
        if (let Some(_) <- comment) {
            return false
        }
        if (let Some(_) <- composer) {
            return false
        }
        if (let Some(_) <- coverArt) {
            return false
        }
        if (let Some(_) <- coverMime) {
            return false
        }
        true
    }
}
