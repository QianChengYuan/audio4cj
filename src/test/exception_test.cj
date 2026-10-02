package audio4cj.test

import audio4cj.core.*

/* 契约测试 1：异常层次（开发文档 §4.1）
 *
 * 注意：所有测试文件同属 audio4cj.test 包，顶层函数名会全局冲突，
 * 因此统一用 @Test class 分组，方法名只需类内唯一。
 */

/// 辅助：判断给定异常能否被 Audio4CjException 捕获
private func catchableAsRoot(e: Audio4CjException): Bool {
    try {
        throw e
    } catch (_: Audio4CjException) {
        return true
    }
    return false
}

@Test
class ExceptionContractTest {
    /// 所有具体异常都是 Audio4CjException 的子类，可被单个 catch 兜住
    @TestCase
    func allConcreteExceptionsShareRootType() {
        @Assert(catchableAsRoot(FormatNotSupportedException("a")))
        @Assert(catchableAsRoot(CorruptedFileException("b")))
        @Assert(catchableAsRoot(DecodeException("c")))
        @Assert(catchableAsRoot(SeekNotSupportedException("d")))
        @Assert(catchableAsRoot(ClosedResourceException("e")))
    }

    @TestCase
    func exceptionsCarryMessage() {
        let e = FormatNotSupportedException("不支持的容器：wma")
        @Assert(e.message == "不支持的容器：wma")
    }

    @TestCase
    func toStringHasLibraryPrefix() {
        let e = DecodeException("坏帧")
        @Assert(e.toString() == "audio4cj: 坏帧")
    }
}
