package audio4cj.test

import audio4cj.meta.Tag

/* 契约测试 3：Tag 模型的 Option 语义（开发文档 §4.3 / §4.1 铁律 1） */

/// 辅助：判断 Option 是否为 None（避免依赖 Option 的相等实现）
private func isNone<T>(v: ?T): Bool {
    match (v) {
        case None => true
        case _ => false
    }
}

@Test
class TagContractTest {
    /// 新建 Tag 的所有标准字段均为 None —— 表示"字段不存在"而非错误
    @TestCase
    func emptyTagHasAllFieldsNone() {
        let tag = Tag()
        @Assert(isNone(tag.title))
        @Assert(isNone(tag.artist))
        @Assert(isNone(tag.album))
        @Assert(isNone(tag.albumArtist))
        @Assert(isNone(tag.year))
        @Assert(isNone(tag.genre))
        @Assert(isNone(tag.track))
        @Assert(isNone(tag.trackTotal))
        @Assert(isNone(tag.disc))
        @Assert(isNone(tag.comment))
        @Assert(isNone(tag.composer))
        @Assert(isNone(tag.coverArt))
        @Assert(isNone(tag.coverMime))
        @Assert(tag.hasNoStandardFields())
        @Assert(tag.extra.size == 0)
    }

    @TestCase
    func settingAFieldMakesTagNonEmpty() {
        let tag = Tag()
        tag.title = "示例曲目"
        @Assert(!tag.hasNoStandardFields())
        @Assert(tag.title.getOrThrow() == "示例曲目")
    }

    @TestCase
    func extraMapIsReadWrite() {
        let tag = Tag()
        tag.putExtra("TPE2", "某乐队")
        @Assert(tag.getExtra("TPE2").getOrThrow() == "某乐队")
        @Assert(isNone(tag.getExtra("不存在")))
        // extra 不影响标准字段判定
        @Assert(tag.hasNoStandardFields())
    }

    @TestCase
    func coverArtIsByteArray() {
        let tag = Tag()
        let jpegHeader: Array<UInt8> = [255, 216, 255]
        tag.coverArt = jpegHeader
        tag.coverMime = "image/jpeg"
        @Assert(tag.coverArt.getOrThrow().size == 3)
        @Assert(tag.coverMime.getOrThrow() == "image/jpeg")
    }
}
