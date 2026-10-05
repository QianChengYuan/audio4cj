package audio4cj.test

import audio4cj.facade.AudioFile
import audio4cj.meta.Tag
import audio4cj.meta.parseMp4Tags
import audio4cj.meta.mp4FindMoov
import audio4cj.meta.mp4FindTrailingMoov
import audio4cj.meta.safeSlice
import std.collection.ArrayList

/* ============================================================================
 * MP4 标签读取测试 —— 覆盖 src/meta/mp4_atoms.cj
 *
 * 【为什么自包含构造 + 真实素材两者都要】
 *   真实素材验证"链路通"，但验证不了边界：64 位 largesize、meta 的 FullBox
 *   偏移、0xA9 前缀、畸形 size —— 真实文件里都不会出现（或很难凑齐）。
 *   这里用仓颉手工搭 box 树，把每种结构都钉死。
 *
 * 【本文件钉住的三类"会静默失效"的坑】
 *   1. **meta 是 FullBox**：漏跳 4 字节 version/flags 会直接解析失败，
 *      而且只是读不到标签、不报错。
 *   2. **`©` 前缀是单字节 0xA9**：源码里写字符串 "©nam" 得到 5 字节
 *      （0xC2 0xA9 'n' 'a' 'm'），永远匹配不上 4 字节的类型名。
 *   3. **moov 可能在文件末尾**：只扫文件头会读不到标签（ffmpeg 默认布局即是）。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// MP4 box 构造辅助
// ---------------------------------------------------------------------------

private func mp4AppendU16BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

private func mp4AppendU32BE(out: ArrayList<UInt8>, v: Int64): Unit {
    out.add(UInt8((v >> 24) & 0xFF))
    out.add(UInt8((v >> 16) & 0xFF))
    out.add(UInt8((v >> 8) & 0xFF))
    out.add(UInt8(v & 0xFF))
}

/// 构造 box：size(4, 大端) + type(4, ASCII) + 负载。
private func mp4Box(typeName: String, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    mp4AppendU32BE(out, 8 + payload.size)
    for (b in typeName.toArray()) {
        out.add(b)
    }
    for (b in payload) {
        out.add(b)
    }
    out.toArray()
}

/// 构造**类型名含单字节 0xA9 前缀**的 box（如 ©nam）。
///
/// 注意：这里必须用字节数组给出类型名，写成字符串会得到 UTF-8 的两字节形式。
private func mp4BoxRaw(typeBytes: Array<UInt8>, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    mp4AppendU32BE(out, 8 + payload.size)
    for (b in typeBytes) {
        out.add(b)
    }
    for (b in payload) {
        out.add(b)
    }
    out.toArray()
}

/// 构造使用 **64 位 largesize** 的 box：size=1 + type + largesize(8) + 负载。
private func mp4BoxLarge(typeName: String, payload: Array<UInt8>): Array<UInt8> {
    let out = ArrayList<UInt8>()
    mp4AppendU32BE(out, 1) // size == 1 ⇒ 后跟 64 位长度
    for (b in typeName.toArray()) {
        out.add(b)
    }
    mp4AppendU32BE(out, 0) // largesize 高 32 位
    mp4AppendU32BE(out, 16 + payload.size) // largesize 低 32 位（含 16 字节头）
    for (b in payload) {
        out.add(b)
    }
    out.toArray()
}

/// data box：typeIndicator + locale + 负载。
private func mp4Data(indicator: Int64, payload: Array<UInt8>): Array<UInt8> {
    let body = ArrayList<UInt8>()
    mp4AppendU32BE(body, indicator)
    mp4AppendU32BE(body, 0) // locale
    for (b in payload) {
        body.add(b)
    }
    mp4Box("data", body.toArray())
}

/// 文本型 data box（typeIndicator = 1 表示 UTF-8 文本）。
private func mp4DataText(text: String): Array<UInt8> {
    mp4Data(1, text.toArray())
}

/// trkn / disk 的二进制 data box：
/// 2 字节保留 + 2 字节当前值 + 2 字节总数（大端）。
private func mp4DataNumberPair(current: Int64, total: Int64): Array<UInt8> {
    let body = ArrayList<UInt8>()
    mp4AppendU16BE(body, 0) // 保留
    mp4AppendU16BE(body, current)
    mp4AppendU16BE(body, total)
    mp4Data(0, body.toArray())
}

/// 封面 data box：typeIndicator 13 = JPEG / 14 = PNG。
private func mp4DataCover(indicator: Int64, bytes: Array<UInt8>): Array<UInt8> {
    mp4Data(indicator, bytes)
}

/// meta box —— **注意它是 FullBox**：负载开头有 4 字节 version + flags。
/// `flags` 用于验证实现是"跳过 4 字节"而不是"假定这 4 字节为 0"。
private func mp4Meta(children: Array<UInt8>, flags: Int64): Array<UInt8> {
    let body = ArrayList<UInt8>()
    mp4AppendU32BE(body, flags) // version(1) + flags(3)
    for (b in children) {
        body.add(b)
    }
    mp4Box("meta", body.toArray())
}

/// 组装最小 MP4：`ftyp` + [可选 `mdat`] + `moov/udta/meta/ilst`。
///
/// `mdatBytes` > 0 时插入一个 mdat，并**故意在其中写入 "moov" 字样** ——
/// 用来验证「文件末尾的 moov」是靠长度关系定位的，而不是靠搜字符串
/// （真实 mdat 里是压缩音频，偶然出现 "moov" 四个字节完全可能）。
private func mp4Assemble(ilst: Array<UInt8>, mdatBytes: Int64, metaFlags: Int64): Array<UInt8> {
    let out = ArrayList<UInt8>()

    // ftyp（major brand "M4A "）
    for (b in mp4Box("ftyp", "M4A ".toArray())) {
        out.add(b)
    }

    // 可选的 mdat：填充内容中夹入 "moov" 字样作为干扰
    if (mdatBytes > 0) {
        let filler = ArrayList<UInt8>()
        var i: Int64 = 0
        while (i + 4 <= mdatBytes) {
            for (b in "moov".toArray()) {
                filler.add(b)
            }
            i += 4
        }
        for (b in mp4Box("mdat", filler.toArray())) {
            out.add(b)
        }
    }

    // moov / udta / meta / ilst
    let ilstBox = mp4Box("ilst", ilst)
    let metaBox = mp4Meta(ilstBox, metaFlags)
    let udtaBox = mp4Box("udta", metaBox)
    for (b in mp4Box("moov", udtaBox)) {
        out.add(b)
    }

    out.toArray()
}

/// `©` 前缀类型名的构造辅助（首字节 0xA9 + 三个 ASCII 字符）。
private func mp4CopyrightType(rest: String): Array<UInt8> {
    let out = ArrayList<UInt8>()
    out.add(0xA9u8)
    for (b in rest.toArray()) {
        out.add(b)
    }
    out.toArray()
}

/// 按「头部窗口」的流程解析：先正向定位 `moov`，再解析。
///
/// 注意 `moov` **不在偏移 0**（前面还有 `ftyp`），所以不能直接把 0 当作
/// moovStart 传进去 —— 这里走与 readMp4TagsFromFile 头部路径相同的两步，
/// 既避免测试里手算偏移，也顺带覆盖了 `mp4FindMoov`。
private func mp4ParseHeadWindow(ilst: Array<UInt8>, mdatBytes: Int64, metaFlags: Int64): Tag {
    let data = mp4Assemble(ilst, mdatBytes, metaFlags)
    parseMp4Tags(data, mp4FindMoov(data).getOrThrow())
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

@Test
class Mp4TagsTest {
    /// 文本类原子：`©nam` / `©ART` / `©alb` / `©day` / `©gen` / `©cmt` / `©wrt` / `aART`
    ///
    /// 这条同时守住 **0xA9 前缀**这个坑：若实现里用字符串 "©nam" 去匹配，
    /// 这里就会全部读不出来。
    @TestCase
    func textAtomsAreRead() {
        let ilst = ArrayList<UInt8>()
        let items: Array<(Array<UInt8>, String)> = [
            (mp4CopyrightType("nam"), "标题甲"),
            (mp4CopyrightType("ART"), "艺术家甲"),
            (mp4CopyrightType("alb"), "专辑甲"),
            (mp4CopyrightType("day"), "2026"),
            (mp4CopyrightType("gen"), "Test"),
            (mp4CopyrightType("cmt"), "注释甲"),
            (mp4CopyrightType("wrt"), "作曲甲"),
            ("aART".toArray(), "专辑艺术家甲")
        ]
        for (it in items) {
            let (typeBytes, text) = it
            for (b in mp4BoxRaw(typeBytes, mp4DataText(text))) {
                ilst.add(b)
            }
        }

        let tag = mp4ParseHeadWindow(ilst.toArray(), 0, 0)
        @Assert(tag.title.getOrThrow() == "标题甲")
        @Assert(tag.artist.getOrThrow() == "艺术家甲")
        @Assert(tag.album.getOrThrow() == "专辑甲")
        @Assert(tag.year.getOrThrow() == "2026")
        @Assert(tag.genre.getOrThrow() == "Test")
        @Assert(tag.comment.getOrThrow() == "注释甲")
        @Assert(tag.composer.getOrThrow() == "作曲甲")
        @Assert(tag.albumArtist.getOrThrow() == "专辑艺术家甲")
    }

    /// `meta` 是 FullBox：version/flags 非零时也必须正确跳过 4 字节
    ///
    /// 若实现是"假定这 4 字节为 0"或"干脆不跳"，本用例会失败。
    @TestCase
    func metaFullBoxOffsetIsRespected() {
        let ilst = mp4BoxRaw(mp4CopyrightType("nam"), mp4DataText("标题乙"))

        // version=1、flags=0x000001，都不是 0
        let tag = mp4ParseHeadWindow(ilst, 0, 0x01000001)
        @Assert(tag.title.getOrThrow() == "标题乙")
    }

    /// trkn / disk 是**二进制**而非文本
    @TestCase
    func trackAndDiscAreBinary() {
        let ilst = ArrayList<UInt8>()
        for (b in mp4BoxRaw(mp4CopyrightType("nam"), mp4DataText("标题丙"))) {
            ilst.add(b)
        }
        for (b in mp4Box("trkn", mp4DataNumberPair(3, 12))) {
            ilst.add(b)
        }
        for (b in mp4Box("disk", mp4DataNumberPair(1, 2))) {
            ilst.add(b)
        }

        let tag = mp4ParseHeadWindow(ilst.toArray(), 0, 0)
        @Assert(tag.track.getOrThrow() == 3)
        @Assert(tag.trackTotal.getOrThrow() == 12)
        @Assert(tag.disc.getOrThrow() == 1)
    }

    /// 封面：covr 的 typeIndicator 决定 MIME（13 = JPEG / 14 = PNG）
    @TestCase
    func coverIsExtractedWithMime() {
        // PNG 的魔数前 4 字节
        let png: Array<UInt8> = [0x89u8, 0x50u8, 0x4Eu8, 0x47u8]
        let jpg: Array<UInt8> = [0xFFu8, 0xD8u8, 0xFFu8, 0xE0u8]

        let pngIlst = mp4Box("covr", mp4DataCover(14, png))
        let t1 = mp4ParseHeadWindow(pngIlst, 0, 0)
        @Assert(t1.coverArt.getOrThrow().size == 4)
        @Assert(t1.coverMime.getOrThrow() == "image/png")

        let jpgIlst = mp4Box("covr", mp4DataCover(13, jpg))
        let t2 = mp4ParseHeadWindow(jpgIlst, 0, 0)
        @Assert(t2.coverArt.getOrThrow().size == 4)
        @Assert(t2.coverMime.getOrThrow() == "image/jpeg")
    }

    /// 64 位 largesize 的 box 要能正确跳过
    ///
    /// 把 `udta` 换成 16 字节头部的 largesize 形式 —— 若实现只认 8 字节头部，
    /// 会把 largesize 当成子 box 的长度，随之解析失败。
    @TestCase
    func largeSizeBoxIsHandled() {
        let ilst = mp4Box("ilst", mp4BoxRaw(mp4CopyrightType("nam"), mp4DataText("标题丁")))
        let metaBox = mp4Meta(ilst, 0)

        let out = ArrayList<UInt8>()
        for (b in mp4Box("ftyp", "M4A ".toArray())) {
            out.add(b)
        }
        // udta 使用 largesize，内部照旧是 meta
        let udtaLarge = mp4BoxLarge("udta", metaBox)
        for (b in mp4Box("moov", udtaLarge)) {
            out.add(b)
        }

        // 这里手工拼的树同样先定位 moov（ftyp 在前，moov 不在偏移 0）
        let data = out.toArray()
        let tag = parseMp4Tags(data, mp4FindMoov(data).getOrThrow())
        @Assert(tag.title.getOrThrow() == "标题丁")
    }

    /// 畸形 box 树一律返回空 Tag，不崩溃、不越界
    @TestCase
    func malformedBoxesAreSafe() {
        // (a) 空输入
        @Assert(parseMp4Tags(Array<UInt8>(), 0).hasNoStandardFields())

        // (b) 只有 4 字节（连 box 头都不完整）
        @Assert(parseMp4Tags([0x00u8, 0x00u8, 0x00u8, 0x08u8], 0).hasNoStandardFields())

        // (c) moovStart 越界
        let good = mp4Assemble(mp4Box("ilst", Array<UInt8>()), 0, 0)
        @Assert(parseMp4Tags(good, good.size).hasNoStandardFields())
        @Assert(parseMp4Tags(good, -1).hasNoStandardFields())

        // (d) box 长度小于头部长度（size = 3，连 8 字节头都装不下）
        let bad = ArrayList<UInt8>()
        mp4AppendU32BE(bad, 3)
        for (b in "moov".toArray()) {
            bad.add(b)
        }
        for (i in 0..32) {
            bad.add(0u8)
        }
        @Assert(parseMp4Tags(bad.toArray(), 0).hasNoStandardFields())

        // (e) box 长度远超数据末尾（size = 0xFFFFFFF0）
        let huge = ArrayList<UInt8>()
        mp4AppendU32BE(huge, 0xFFFFFFF0)
        for (b in "moov".toArray()) {
            huge.add(b)
        }
        for (i in 0..64) {
            huge.add(0u8)
        }
        @Assert(parseMp4Tags(huge.toArray(), 0).hasNoStandardFields())

        // (f) 结构完好但没有 udta 层
        let noUdta = ArrayList<UInt8>()
        for (b in mp4Box("ftyp", "M4A ".toArray())) {
            noUdta.add(b)
        }
        for (b in mp4Box("moov", mp4Box("free", Array<UInt8>()))) {
            noUdta.add(b)
        }
        @Assert(parseMp4Tags(noUdta.toArray(), 0).hasNoStandardFields())
    }

    /// **moov 位于文件末尾**时的定位：靠长度关系，而不是搜 "moov" 字符串
    ///
    /// mdat 里被故意填满了 "moov" 字样 —— 若实现是"搜字符串"，会命中 mdat
    /// 里的假位置。本用例模拟读取尾部窗口的流程（先定位、再解析）。
    @TestCase
    func trailingMoovIsLocatedByLengthNotBySearching() {
        let ilst = mp4BoxRaw(mp4CopyrightType("nam"), mp4DataText("标题戊"))
        let data = mp4Assemble(ilst, 4096, 0) // ftyp + mdat(填满 "moov") + moov

        // 模拟尾部窗口：取最后 1024 字节
        let windowLen: Int64 = 1024
        @Assert(data.size > windowLen)
        let tail = safeSlice(data, data.size - windowLen, windowLen)

        // 尾部窗口里 moov 不在开头，正向查找应当找不到
        @Assert(mp4FindMoov(tail).isNone())

        // 尾部对齐查找应当找到，且解析成功
        let m = mp4FindTrailingMoov(tail).getOrThrow()
        @Assert(parseMp4Tags(tail, m).title.getOrThrow() == "标题戊")
    }

    /// 真实素材：两种 moov 布局都能读出标签（这是本轮最容易漏的一条路径）
    @TestCase
    func realFixturesWithBothMoovLayouts() {
        if (gsSkipIfNoFixtures("realFixturesWithBothMoovLayouts")) {
            return
        }

        let root = "testdata/mp4"

        // (a) ffmpeg 默认布局：moov 在**文件末尾**
        let full = AudioFile.readTags("${root}/mp4_tagged_full.m4a")
        @Assert(full.title.getOrThrow() == "MP4 全字段标题")
        @Assert(full.artist.getOrThrow() == "MP4 艺术家")
        @Assert(full.album.getOrThrow() == "MP4 专辑")
        @Assert(full.albumArtist.getOrThrow() == "MP4 专辑艺术家")
        @Assert(full.year.getOrThrow() == "2026")
        @Assert(full.genre.getOrThrow() == "Test")
        @Assert(full.comment.getOrThrow() == "MP4 注释")
        @Assert(full.composer.getOrThrow() == "MP4 作曲")
        @Assert(full.track.getOrThrow() == 3)
        @Assert(full.trackTotal.getOrThrow() == 12)
        @Assert(full.disc.getOrThrow() == 1)

        // (b) faststart 布局：moov 在**文件头部**
        let fast = AudioFile.readTags("${root}/mp4_tagged_faststart.m4a")
        @Assert(fast.title.getOrThrow() == "MP4 faststart 标题")
        @Assert(fast.artist.getOrThrow() == "MP4 艺术家")
        @Assert(fast.album.getOrThrow() == "MP4 专辑")

        // (c) 带封面的素材
        let cover = AudioFile.readTags("${root}/mp4_cover.m4a")
        @Assert(cover.title.getOrThrow() == "MP4 Cover")
        @Assert(cover.coverArt.getOrThrow().size > 0)
        @Assert(cover.coverMime.getOrThrow() == "image/png")

        // (d) 无标签素材：返回空 Tag，而不是异常
        let plain = AudioFile.readTags("${root}/aac_mp4_128k.m4a")
        @Assert(plain.hasNoStandardFields())
    }
}
