package audio4cj.test

import audio4cj.stream.FrameStream
import audio4cj.core.Audio4CjException

/* 契约测试 5：FrameStream（开发文档 §4.5） */

@Test
class FrameStreamContractTest {
    /// cancel() 为协作式：只设置标志位，由解码循环轮询
    @TestCase
    func cancelSetsFlag() {
        let s = FrameStream()
        @Assert(!s.isCancelled())
        s.cancel()
        @Assert(s.isCancelled())
    }

    /// close() 幂等，且隐含取消
    @TestCase
    func closeMarksClosedAndCancelled() {
        let s = FrameStream()
        s.close()
        @Assert(s.isClosed())
        @Assert(s.isCancelled())
    }

    @TestCase
    func closeIsIdempotent() {
        let s = FrameStream()
        s.close()
        s.close()
        @Assert(s.isClosed())
    }

    /// 关闭后调用 next() 必须抛异常而不是返回 None
    /// —— None 严格且仅表示"正常流结束"（§4.1 铁律 1）
    @TestCase
    func nextOnClosedStreamThrowsInsteadOfReturningNone() {
        let s = FrameStream()
        s.close()
        @AssertThrows[Audio4CjException](s.next())
    }
}
