package audio4cj.test

import audio4cj.core.*

/* 契约测试 2：泛型注册表（开发文档 §3.2 / §5 扩展机制） */

@Test
class RegistryContractTest {
    @TestCase
    func registerAndLookup() {
        let reg = Registry<String>()
        reg.register("wav", "wav-reader")
        @Assert(reg.contains("wav"))
        @Assert(reg.get("wav").getOrThrow() == "wav-reader")
        @Assert(reg.size == 1)
    }

    /// 未注册的键必须返回 None（表示"无值"，不是错误 —— §4.1 铁律 1）
    @TestCase
    func missingKeyReturnsNoneInsteadOfThrowing() {
        let reg = Registry<String>()
        @Assert(!reg.contains("flac"))
        match (reg.get("flac")) {
            case None => @Assert(true)
            case Some(_) => @Fail("未注册的键应返回 None")
        }
    }

    @TestCase
    func duplicateRegisterOverwrites() {
        let reg = Registry<String>()
        reg.register("mp3", "old")
        reg.register("mp3", "new")
        @Assert(reg.size == 1)
        @Assert(reg.get("mp3").getOrThrow() == "new")
    }

    @TestCase
    func keysAndClear() {
        let reg = Registry<String>()
        reg.register("a", "1")
        reg.register("b", "2")
        @Assert(reg.keys().size == 2)
        reg.clear()
        @Assert(reg.size == 0)
        @Assert(!reg.contains("a"))
    }
}
