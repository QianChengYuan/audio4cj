package audio4cj.format

import audio4cj.core.CorruptedFileException
import std.fs.*

/* ============================================================================
 * FLAC 字节源抽象 —— "FLAC 字节流从哪里来"
 *
 * 【为什么需要它】
 *   flac_bitstream.cj 的解码逻辑（元数据链、窗口回填、帧边界推进、
 *   SEEKTABLE 定位）只依赖一件事：**能按顺序拿到 FLAC 字节流**，
 *   而与"这些字节来自裸文件还是别处"无关。把这件事抽出来之后：
 *     FileByteSource    —— 原生 FLAC：字节就是文件本身
 *     OggFlacByteSource —— Ogg 封装：字节是各页页体拼起来的重建流
 *   解码器一行不改即可同时服务两种容器 —— 这正是本次（Tier 2）的目的。
 *
 * 【虚拟偏移：本抽象的核心约定】
 *   源上的偏移一律是**FLAC 字节流的偏移**，0 即 "fLaC" 标记的第一个字节：
 *     - 原生 FLAC：偏移 N == 文件偏移 N
 *     - Ogg 封装 ：偏移 N == 重建流偏移 N（如何换算成文件偏移由源自理）
 *   解码器的 _windowFileOffset / _cursor / 首帧偏移 / SEEKTABLE 定位点
 *   全部按此口径记账，因此"换源"不影响任何记账逻辑。
 *   这一点必须守住：记账错位的表现是**静默的错位音频**，
 *   不会报错，只会听起来不对（本文件所在模块的其它地方踩过同类坑）。
 *
 * 【为什么 skip 是独立方法，而不是"读掉再扔"的循环】
 *   跳过的量可能很大（SEEKTABLE 定位点可达文件后段），"读掉再扔"要为
 *   被跳过的内容分配缓冲。Ogg 源能直接按段表算出页体长度并越过，
 *   不需要把字节搬进内存 —— 接口留出这个方法，实现才有优化的余地。
 * ========================================================================== */

/// 顺序字节源。
protected interface FlacByteSource {
    /// 精确读取 n 字节；不足即抛异常（不做"读多少算多少"）。
    func readExact(n: Int64): Array<UInt8>

    /// 跳过 n 字节；**不足以跳满时抛异常**（与 readExact 同一口径）。
    ///
    /// 【为什么"跳不足"必须抛，而不是跳到哪算哪】源的读取位置与解码器的
    /// `_cursor` / `_windowFileOffset` 必须始终一致。若跳不足却静默返回，
    /// 源已停在流末尾而解码器仍按原偏移记账 —— 二者错位后取到的数据会
    /// "看起来正常但内容错位"，属于最难查的一类缺陷。抛异常把它挡在当场。
    func skip(n: Int64): Unit

    /// 尽量填满 `buf`，返回实际读到的字节数；**0 表示数据流正常结束**
    /// （与 FlacDecodeKernel.readF32Into 的"0 = 正常结束"约定同构）。
    func readSome(buf: Array<UInt8>): Int64

    /// 重开底层文件并回到流起点。
    ///
    /// 【为什么是重开而不是移动文件位置】seek 的目标可能落在当前读取位置
    /// **之前**，而窗口只前向回填、文件流也不支持后退（见 flac_bitstream 的
    /// rewind / repositionTo 说明）。重开既回避了"文件是否可随机访问"的
    /// 问题，也顺带把源内部状态（页缓存、选定流）一并复位。
    func reopen(): Unit

    /// 释放底层文件句柄（幂等）。
    func close(): Unit
}

/// 裸文件字节源：源偏移与文件偏移一一对应（原生 FLAC 用）。
protected class FileByteSource <: FlacByteSource {
    private let _path: String
    private var _file: File
    private var _closed: Bool = false

    protected init(path: String) {
        this._path = path
        this._file = File(path, Read)
    }

    /// 精确读取 n 字节；不足则抛异常。
    ///
    /// 注意 `File.read` 只能从数组**起始处**写入，因此分次读取时须经临时缓冲
    /// 拼接 —— 不能靠切片（仓颉的切片是拷贝，写进去不会回到原数组）。
    public func readExact(n: Int64): Array<UInt8> {
        let buf = Array<UInt8>(n, repeat: 0)
        var got: Int64 = 0
        while (got < n) {
            let scratch = Array<UInt8>(n - got, repeat: 0)
            let r = _file.read(scratch)
            if (r <= 0) {
                throw CorruptedFileException("FLAC 字节流提前结束（需 ${n} 字节，已得 ${got}）")
            }
            var i: Int64 = 0
            while (i < r) {
                buf[got + i] = scratch[i]
                i += 1
            }
            got += r
        }
        buf
    }

    /// 跳过 n 字节（分块读掉，避免为巨大的元数据块分配内存）。
    public func skip(n: Int64): Unit {
        var left = n
        let chunkSize: Int64 = 65536
        while (left > 0) {
            let take = if (left > chunkSize) {
                chunkSize
            } else {
                left
            }
            let scratch = Array<UInt8>(take, repeat: 0)
            let r = _file.read(scratch)
            if (r <= 0) {
                throw CorruptedFileException("FLAC 字节流提前结束：需跳过 ${n} 字节，还有 ${left} 字节未能跳过")
            }
            left -= r
        }
    }

    public func readSome(buf: Array<UInt8>): Int64 {
        _file.read(buf)
    }

    public func reopen(): Unit {
        _file.close()
        _file = File(_path, Read)
    }

    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _file.close()
        }
    }
}
