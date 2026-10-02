# `audio4cj.meta` API 参考

> 统一标签模型层。把 ID3v1 / ID3v2 / Vorbis comment / WAV LIST/INFO / MP4 `ilst` 等不同标签体系收敛为同一个类型。
>
> ```cangjie
> import audio4cj.meta.Tag
> ```

## 一、`Tag`

统一的音频标签模型。

```cangjie
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

    public var coverArt: ?Array<UInt8> = None
    public var coverMime: ?String = None

    public var extra: HashMap<String, String> = HashMap<String, String>()

    public init()

    public func putExtra(key: String, value: String): Unit
    public func getExtra(key: String): ?String
    public func hasNoStandardFields(): Bool
}
```

### 1.1 字段

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `title` | `?String` | `None` | 标题 |
| `artist` | `?String` | `None` | 艺术家 / 演唱者 |
| `album` | `?String` | `None` | 专辑名 |
| `albumArtist` | `?String` | `None` | 专辑艺术家（合辑场景下与 `artist` 不同） |
| `year` | `?String` | `None` | 年份。**是字符串不是整数** —— 原始标签常含 `"2004-05-12"` 这类完整日期 |
| `genre` | `?String` | `None` | 流派 |
| `track` | `?Int64` | `None` | 音轨号 |
| `trackTotal` | `?Int64` | `None` | 音轨总数（原标签中的 `"3/12"` 会被拆成 `track=3`、`trackTotal=12`） |
| `disc` | `?Int64` | `None` | 碟号 |
| `comment` | `?String` | `None` | 注释 / 备注 |
| `composer` | `?String` | `None` | 作曲者 |
| `coverArt` | `?Array<UInt8>` | `None` | 封面图的**原始字节**（不区分格式，JPEG / PNG 都放这里） |
| `coverMime` | `?String` | `None` | 封面图 MIME 类型，如 `"image/jpeg"` |
| `extra` | `HashMap<String, String>` | 空表 | 各标签体系特有字段的**兜底容器** |

> **`year` 为什么是字符串？** 因为 ID3v2.4 的 `TDRC` 是完整时间戳（`"2004-05-12T10:00"`）、Vorbis 的 `DATE` 也可能是 `"2004-05"`。强行转整数会丢失信息，且解析失败的语义难以定义。需要年份整数时由调用方自行截取。

> **`extra` 的作用**：某些标签体系有大量冷门字段（如 ID3v2 的 `TPE2`、`TXXX:xxx`）。为它们逐个加字段会让接口无限膨胀，因此统一进 `extra`，键为原始帧 ID。

### 1.2 构造

```cangjie
public init()
```

**唯一的构造方式是无参构造**。所有字段都有默认值（`None` / 空表），因此新建的 `Tag` 就是「空标签」。

不存在带参数的便捷构造，字段通过直接赋值填充：

```cangjie
import audio4cj.meta.Tag

main() {
    let tag = Tag()
    tag.title = "示例曲目"
    tag.artist = "示例艺术家"
    tag.track = 3
    tag.trackTotal = 12
    tag.putExtra("TPE2", "专辑艺术家（原始帧）")
}
```

### 1.3 `putExtra`

```cangjie
public func putExtra(key: String, value: String): Unit
```

写入一个兜底字段。同键重复写入时**后者覆盖前者**。

| 参数 | 说明 |
|---|---|
| `key` | 字段键，建议使用原始帧 ID（如 `"TPE2"`、`"TXXX:MOOD"`） |
| `value` | 字段值 |

### 1.4 `getExtra`

```cangjie
public func getExtra(key: String): ?String
```

读取一个兜底字段。**键不存在时返回 `None`**（不抛异常）。

### 1.5 `hasNoStandardFields`

```cangjie
public func hasNoStandardFields(): Bool
```

判断是否所有**标准字段**都为空。用于回答「这个文件到底有没有可用的标签信息」。

**检查范围**：上表中除 `extra` 外的**全部 13 个字段**（含 `coverArt` 与 `coverMime`）。

**注意**：`extra` 的内容**不参与判定**。也就是说，一个只有 `extra` 内容的 `Tag` 会让本方法返回 `true`：

```cangjie
let tag = Tag()
tag.putExtra("TPE2", "abc")
println(tag.hasNoStandardFields())   // true —— extra 不计入标准字段
```

这样设计的理由：`extra` 是冷门字段的兜底，不能代表「文件有可用的标签」，否则会给调用方错误的判断依据。

## 二、使用示例

### 2.1 读取并展示标签

```cangjie
import audio4cj.facade.AudioFile

main() {
    try (f = AudioFile.open("./song.wav")) {
        let tag = f.metadata()

        if (tag.hasNoStandardFields()) {
            println("该文件没有标准标签")
        } else {
            // 用 ?? 提供默认值
            let title = tag.title ?? "(未知)"
            let artist = tag.artist ?? "(未知)"
            let album = tag.album ?? "(未知)"
            let year = tag.year ?? "(未知)"

            println("标题  : ${title}")
            println("艺术家: ${artist}")
            println("专辑  : ${album}")
            println("年份  : ${year}")

            // 音轨号与总数分开表示
            let n = tag.track ?? 0
            let total = tag.trackTotal ?? 0
            println("音轨  : ${n}/${total}")

            // 封面
            if (let Some(art) <- tag.coverArt) {
                let mime = tag.coverMime ?? "未知"
                println("封面: ${art.size} 字节，类型 ${mime}")
            }
        }
    }
}
```

### 2.2 Option 的三种处理方式

```cangjie
import audio4cj.meta.Tag

func describe(tag: Tag): Unit {
    // 方式一：?? 提供默认值
    let t1 = tag.title ?? "(无标题)"

    // 方式二：if-let 条件解构
    var t2 = "(无标题)"
    if (let Some(v) <- tag.title) {
        t2 = v
    }

    // 方式三：match 显式分支
    let t3 = match (tag.title) {
        case Some(v) => v
        case None => "(无标题)"
    }

    println("${t1} / ${t2} / ${t3}")
}
```

### 2.3 遍历冷门字段

```cangjie
import audio4cj.meta.Tag

func dumpExtras(tag: Tag): Unit {
    for ((k, v) in tag.extra) {
        println("${k} = ${v}")
    }
}
```

## 三、能力覆盖与限制

| 能力 | 状态 |
|---|---|
| `Tag` 数据模型 | ✅ 已实现 |
| WAV `LIST/INFO` 解析 | ✅ 已实现 |
| ID3v1 解析（MP3 文件尾 128 字节） | ✅ 已实现 |
| ID3v2.2 / 2.3 / 2.4 解析（MP3 文件头） | ✅ 已实现 |
| Vorbis comment 解析（FLAC 元数据块） | ✅ 已实现 |
| **Ogg 页重组**（页头、段表、跨页续传、多逻辑流隔离） | ✅ 已实现 |
| **OGG 标签**（Vorbis / Opus / FLAC-in-Ogg） | ✅ 已实现 |
| **MP4 `ilst` 标签**（含 64 位尺寸与 `meta` 的 FullBox 偏移；`moov` 在文件头或文件尾均可定位） | ✅ 已实现 |
| 多体系合并（ID3v2 优先于 ID3v1） | ✅ 已实现 |
| FLAC `PICTURE` 块（封面） | ⏳ 未覆盖 |
| Speex 注释头 | ⏳ 未覆盖（见下） |
| APE tag 解析 | ⏳ 未排期 |
| 标签**写入** | ⏳ 未排期（本库只读） |

### 3.1 各体系的字段覆盖

| `Tag` 字段 | ID3v2 | ID3v1 | Vorbis comment | WAV INFO | MP4 `ilst` |
|---|---|---|---|---|---|
| `title` | `TIT2` / `TT2` | ✔ | `TITLE` | `INAM` | `©nam` |
| `artist` | `TPE1` / `TP1` | ✔ | `ARTIST` | `IART` | `©ART` |
| `album` | `TALB` / `TAL` | ✔ | `ALBUM` | `IPRD` / `IALB` | `©alb` |
| `albumArtist` | `TPE2` / `TP2` | — | `ALBUMARTIST` | — | `aART` |
| `year` | `TDRC` / `TYER` / `TYE` | ✔ | `DATE` / `YEAR` | `ICRD` | `©day` |
| `genre` | `TCON` / `TCO`（含索引查表） | ✔ | `GENRE` | `IGNR` | `©gen` |
| `track` / `trackTotal` | `TRCK` / `TRK`（`n/m` 自动拆分） | ✔（v1.1） | `TRACKNUMBER` | `ITRK` / `IPRT` | `trkn`（**二进制**） |
| `disc` | `TPOS` / `TPA` | — | `DISCNUMBER` | — | `disk`（**二进制**） |
| `comment` | `COMM` / `COM` | ✔ | `COMMENT` / `DESCRIPTION` | `ICMT` | `©cmt` |
| `composer` | `TCOM` / `TCM` | — | `COMPOSER` | `IMUS` | `©wrt` |
| `coverArt` / `coverMime` | `APIC` / `PIC` | — | ⏳（`METADATA_BLOCK_PICTURE`） | — | `covr`（PNG / JPEG） |
| `extra` | 未映射的 `T***` 帧、`TXXX:<描述>` | — | 其余大写键 | 其余 4 字符 ID | 其余原子（`©` 渲染为 `c`） |

### 3.2 已知限制

- **Speex 注释头未覆盖**：Speex 的注释机制与 Vorbis comment 的两种 magic（`\x03"vorbis"` / `"OpusTags"`）都不同，因此对 Speex 返回**空 `Tag`**（不报错）；
- **FLAC 的 `PICTURE` 块未覆盖**（原生 FLAC 与 Ogg-FLAC 均如此）。注意 **MP4 的 `covr` 与 ID3v2 的 `APIC` 已支持封面**；
- **Vorbis comment 的 `METADATA_BLOCK_PICTURE` 被显式跳过**：解析它需要 base64 解码，尚未实现。跳过而不是放进 `extra`，是为了避免把数十至数百 KB 的 base64 文本灌进 `Tag`；
- **MP4 的 `moov` 只覆盖文件头与文件尾两种布局**：先查头部窗口（faststart），未命中再查尾部窗口（ffmpeg 默认）。理论上 `moov` 只在这两端，若遇到中间布局的文件则读不到标签；
- **OGG 只取首个逻辑流的注释头**：Ogg 允许一个文件内复用多条逻辑流（音视频复用即为典型），本实现只解析**首个带 BOS 标志**的流，不把不同 serial 的包混拼；
- **不解析 ID3v2 的扩展头内容**：仅跳过，不影响标签字段；
- **同一字段多次出现时后者覆盖前者**：标签中出现重复帧属异常，取最后一个作为确定行为；
- **标签数据全程按不可信输入处理**：页数、packet 长度、box 数量、条目数与嵌套范围均有上限，长度字段越界即安全退出；UTF-8 非法时退回 Latin-1，绝不因单个字段损坏而中断整个标签读取；
- **读不出标签时静默返回空 `Tag`**：这是契约行为（见 README 契约 1）——「没有标签」不是错误，只有**容器无法识别**或**结构损坏到无法继续**才抛异常。

## 四、标签读取入口

读取标签有两条路径，取决于文件能否被打开：

| 入口 | 前置条件 | 适用场景 |
|---|---|---|
| `AudioFile.open(path).metadata()` | 容器**可解码**（当前仅 WAV） | 已打开文件，顺便读标签 |
| **`AudioFile.readTags(path)`** | **无要求** | MP3 / FLAC 等尚无解码实现的格式，只读标签 |

```cangjie
import audio4cj.facade.AudioFile

main() {
    // MP3 当前不能解码，但标签可以读
    let tag = AudioFile.readTags("./song.mp3")
    let title = tag.title ?? "(无标题)"
    let artist = tag.artist ?? "(无艺术家)"
    println("标题: ${title}")
    println("艺术家: ${artist}")

    // 冷门信息在 extra 中（键为原始帧 ID / 评论键名）
    for ((k, v) in tag.extra) {
        println("  ${k} = ${v}")
    }
}
```

**支持情况**：

| 容器 | 标签来源 | 合并策略 |
|---|---|---|
| mp3 | ID3v2（文件头）+ ID3v1（文件尾 128 字节） | ID3v2 优先，为空字段由 ID3v1 回填 |
| flac | `VORBIS_COMMENT` 元数据块 | — |
| wav | `LIST/INFO` 子块 | — |

**抛出**：无法识别的格式、或已识别但标签读取尚未实现的容器（如 OGG）会抛 `FormatNotSupportedException`；文件不存在抛 `std.fs` 的 `FSException`。

> 无标签的文件返回**空 `Tag`**（既不是异常也不是 `None`），用 `hasNoStandardFields()` 判断即可。
