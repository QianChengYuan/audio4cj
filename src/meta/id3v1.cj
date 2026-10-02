package audio4cj.meta

/* ============================================================================
 * ID3v1 / ID3v1.1 解析 —— 开发文档 §10 M3
 *
 * 布局（固定 128 字节，位于文件**末尾**）：
 *
 *   偏移   长度   字段
 *   ----   ----   ------------------------------------------
 *   0      3      "TAG" 标识
 *   3      30     标题
 *   33     30     艺术家
 *   63     30     专辑
 *   93     4      年份（4 个 ASCII 数字）
 *   97     30     注释
 *   127    1      流派索引（0–147，查 GENRES 表）
 *
 * ID3v1.1 的差异：注释字段的第 28 字节（偏移 125）为 0x00，
 *   第 29 字节（偏移 126）被解释为音轨号，注释实际长度缩为 28 字节。
 *
 * 文本编码：**ISO-8859-1**（固定，无编码标识字节）。
 *
 * 设计：本文件**不做任何 I/O**，只接收调用方读入的尾部字节，
 *   使单元测试可用内存构造的数据直接覆盖全部字段解析逻辑。
 * ========================================================================== */

/// ID3v1 标签的固定长度（字节）。
protected let ID3V1_SIZE: Int64 = 128

/// ID3v1 各字段的偏移与长度。
private let ID3V1_OFF_TITLE: Int64 = 3
private let ID3V1_OFF_ARTIST: Int64 = 33
private let ID3V1_OFF_ALBUM: Int64 = 63
private let ID3V1_OFF_YEAR: Int64 = 93
private let ID3V1_OFF_COMMENT: Int64 = 97
private let ID3V1_OFF_GENRE: Int64 = 127
private let ID3V1_LEN_TEXT: Int64 = 30
private let ID3V1_LEN_YEAR: Int64 = 4

/// ID3v1 流派表（0–147），原文名保留（含若干历史上的拼写变体）。
///
/// 可见性为 protected 而非 private：ID3v2 的 `TCON` 帧也可能用索引
/// 表示流派（如 `"(17)"`），需要复用同一张表。
protected let ID3V1_GENRES: Array<String> = [
    "Blues",
    "Classic Rock",
    "Country",
    "Dance",
    "Disco",
    "Funk",
    "Grunge",
    "Hip-Hop",
    "Jazz",
    "Metal",
    "New Age",
    "Oldies",
    "Other",
    "Pop",
    "R&B",
    "Rap",
    "Reggae",
    "Rock",
    "Techno",
    "Industrial",
    "Alternative",
    "Ska",
    "Death Metal",
    "Pranks",
    "Soundtrack",
    "Euro-Techno",
    "Ambient",
    "Trip-Hop",
    "Vocal",
    "Jazz+Funk",
    "Fusion",
    "Trance",
    "Classical",
    "Instrumental",
    "Acid",
    "House",
    "Game",
    "Sound Clip",
    "Gospel",
    "Noise",
    "AlternRock",
    "Bass",
    "Soul",
    "Punk",
    "Space",
    "Meditative",
    "Instrumental Pop",
    "Instrumental Rock",
    "Ethnic",
    "Gothic",
    "Darkwave",
    "Techno-Industrial",
    "Electronic",
    "Pop-Folk",
    "Eurodance",
    "Dream",
    "Southern Rock",
    "Comedy",
    "Cult",
    "Gangsta",
    "Top 40",
    "Christian Rap",
    "Pop/Funk",
    "Jungle",
    "Native American",
    "Cabaret",
    "New Wave",
    "Psychadelic",
    "Rave",
    "Showtunes",
    "Trailer",
    "Lo-Fi",
    "Tribal",
    "Acid Punk",
    "Acid Jazz",
    "Polka",
    "Retro",
    "Musical",
    "Rock & Roll",
    "Hard Rock",
    "Folk",
    "Folk-Rock",
    "National Folk",
    "Swing",
    "Fast Fusion",
    "Bebob",
    "Latin",
    "Revival",
    "Celtic",
    "Bluegrass",
    "Avantgarde",
    "Gothic Rock",
    "Progressive Rock",
    "Psychedelic Rock",
    "Symphonic Rock",
    "Slow Rock",
    "Big Band",
    "Chorus",
    "Easy Listening",
    "Acoustic",
    "Humour",
    "Speech",
    "Chanson",
    "Opera",
    "Chamber Music",
    "Sonata",
    "Symphony",
    "Booty Bass",
    "Primus",
    "Porn Groove",
    "Satire",
    "Slow Jam",
    "Club",
    "Tango",
    "Samba",
    "Folklore",
    "Ballad",
    "Power Ballad",
    "Rhythmic Soul",
    "Freestyle",
    "Duet",
    "Punk Rock",
    "Drum Solo",
    "A capella",
    "Euro-House",
    "Dance Hall",
    "Goa",
    "Drum & Bass",
    "Club-House",
    "Hardcore",
    "Terror",
    "Indie",
    "BritPop",
    "Negerpunk",
    "Polsk Punk",
    "Beat",
    "Christian Gangsta Rap",
    "Heavy Metal",
    "Black Metal",
    "Crossover",
    "Contemporary Christian",
    "Christian Rock",
    "Merengue",
    "Salsa",
    "Thrash Metal",
    "Anime",
    "JPop",
    "Synthpop"
]

/// 解析 ID3v1 / ID3v1.1 标签。
///
/// - `tail`：文件**末尾 128 字节**（调用方负责读取；本函数不做 I/O）
/// - 返回：解析出的 `Tag`；若 `tail` 长度不足或不含 "TAG" 标识，返回**空 Tag**
///   （`None` 语义契约：无标签不是错误，见 §4.1 铁律 1）
///
/// 全部字段从 ISO-8859-1 解码，并去除末尾的 NUL / 空格填充。
protected func parseId3v1(tail: Array<UInt8>): Tag {
    let tag = Tag()

    if (tail.size < ID3V1_SIZE) {
        return tag
    }
    if (!matchAsciiAt(tail, 0, "TAG")) {
        return tag
    }

    let title = decodeLatin1(trimTrailingPadding(safeSlice(tail, ID3V1_OFF_TITLE, ID3V1_LEN_TEXT)))
    let artist = decodeLatin1(trimTrailingPadding(safeSlice(tail, ID3V1_OFF_ARTIST, ID3V1_LEN_TEXT)))
    let album = decodeLatin1(trimTrailingPadding(safeSlice(tail, ID3V1_OFF_ALBUM, ID3V1_LEN_TEXT)))
    let year = decodeLatin1(trimTrailingPadding(safeSlice(tail, ID3V1_OFF_YEAR, ID3V1_LEN_YEAR)))

    // ---- 注释与音轨：区分 ID3v1 与 ID3v1.1 ----
    //
    // v1.1 判定：注释字段第 28 字节（偏移 125）为 0x00，
    //            且第 29 字节（偏移 126）非 0（非 0 才是一个有意义的音轨号）。
    let v11Marker = ID3V1_OFF_COMMENT + 28 // 125
    let trackByte = ID3V1_OFF_COMMENT + 29 // 126

    var commentLen = ID3V1_LEN_TEXT // 30
    var track: ?Int64 = None

    if (tail[v11Marker] == 0u8 && tail[trackByte] != 0u8) {
        commentLen = 28
        track = Int64(tail[trackByte])
    }

    let comment = decodeLatin1(trimTrailingPadding(safeSlice(tail, ID3V1_OFF_COMMENT, commentLen)))

    // ---- 流派（索引查表）----
    let genreIndex = Int64(tail[ID3V1_OFF_GENRE])
    var genre: ?String = None
    if (genreIndex >= 0 && genreIndex < ID3V1_GENRES.size) {
        genre = ID3V1_GENRES[genreIndex]
    }

    // ---- 填充（空字符串视为「该字段不存在」）----
    if (!title.isEmpty()) {
        tag.title = title
    }
    if (!artist.isEmpty()) {
        tag.artist = artist
    }
    if (!album.isEmpty()) {
        tag.album = album
    }
    if (!year.isEmpty()) {
        tag.year = year
    }
    if (!comment.isEmpty()) {
        tag.comment = comment
    }
    if (let Some(v) <- track) {
        tag.track = v
    }
    if (let Some(v) <- genre) {
        tag.genre = v
    }

    tag
}
