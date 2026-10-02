package audio4cj.test

import audio4cj.core.*
import audio4cj.facade.AudioFile
import std.fs.*
import std.sync.SyncCounter

/* 契约测试 6：AudioFile 生命周期与并发（开发文档 §4.4 / §4.7） */

@Test
class AudioFileContractTest {
    /// 不存在的文件：open 应抛 IO 层异常（§4.1 契约：文件不存在 -> IO 异常）。
    ///
    /// 沿革：M1 阶段此处期望 FormatNotSupportedException（当时骨架尚未实现探测）；
    /// M2 接入真实魔数探测后，行为变为"先按路径打开文件再探测"，
    /// 故对不存在的路径抛 std.fs 的 FSException，这才是符合契约的顺序。
    @TestCase
    func openNonexistentFileThrowsIoError() {
        @AssertThrows[FSException](AudioFile.open("a4cj_no_such_file.wav"))
    }

    /// close() 幂等
    @TestCase
    func closeIsIdempotent() {
        let f = AudioFile("test.flac")
        @Assert(!f.isClosed())
        f.close()
        f.close()
        @Assert(f.isClosed())
    }

    /// 关闭后所有数据操作抛 ClosedResourceException
    @TestCase
    func operationsAfterCloseThrowClosedResource() {
        let f = AudioFile("test.flac")
        f.close()
        @AssertThrows[ClosedResourceException](f.metadata())
        @AssertThrows[ClosedResourceException](f.info())
        @AssertThrows[ClosedResourceException](f.stream())
        @AssertThrows[ClosedResourceException](f.readFrames(10))
        @AssertThrows[ClosedResourceException](f.seekTo(0))
    }

    /// try-with-resources 自动释放（不依赖终结器）
    @TestCase
    func tryWithResourcesClosesAutomatically() {
        var holder: ?AudioFile = None
        try (res = AudioFile("test.flac")) {
            holder = Some(res)
            @Assert(!res.isClosed())
        }
        @Assert(holder.getOrThrow().isClosed())
    }

    @TestCase
    func pathIsReadable() {
        let f = AudioFile("a/b/c.mp3")
        @Assert(f.path == "a/b/c.mp3")
    }

    /// 契约：多文件并行须各用独立实例，并显式汇合
    /// （主线程退出会杀死未完成线程，详见 §4.7）
    @TestCase
    func independentInstancesAcrossThreads() {
        let n = 4
        let counter = SyncCounter(n)
        for (i in 0..n) {
            spawn {
                =>
                    let f = AudioFile("thread-${i}.flac")
                    f.close()
                    counter.dec()
            }
        }
        counter.waitUntilZero()
        @Assert(true)
    }
}
