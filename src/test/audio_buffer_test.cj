package audio4cj.test

import audio4cj.pcm.AudioBuffer

/* 契约测试 4：AudioBuffer（开发文档 §4.2 / §7.3） */

@Test
class AudioBufferContractTest {
    /// f32 交错布局：帧数 = 样本总数 / 声道数
    @TestCase
    func frameCountIsSamplesOverChannels() {
        // 3 帧立体声 = 6 个交错样本
        let buf = AudioBuffer(44100, 2, [0.0, 0.1, 0.2, 0.3, 0.4, 0.5])
        @Assert(buf.frameCount == 3)
        @Assert(buf.sampleCount == 6)
        @Assert(buf.sampleRate == 44100)
        @Assert(buf.channels == 2)
    }

    /// 声道数非正时防御性返回 0 帧，不抛异常
    @TestCase
    func zeroChannelsYieldsZeroFrames() {
        let buf = AudioBuffer(44100, 0, [0.0, 0.1])
        @Assert(buf.frameCount == 0)
    }

    @TestCase
    func emptyBufferIsEmpty() {
        let buf = AudioBuffer(44100, 2, Array<Float32>())
        @Assert(buf.isEmpty())
        @Assert(buf.frameCount == 0)
    }

    @TestCase
    func samplesAreReadableAsInterleavedF32() {
        let buf = AudioBuffer(44100, 1, [0.25, -0.5])
        @Assert(buf.samples[0] == 0.25)
        @Assert(buf.samples[1] == -0.5)
    }
}
