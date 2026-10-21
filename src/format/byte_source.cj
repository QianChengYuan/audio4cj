package audio4cj.format

import audio4cj.core.CorruptedFileException
import std.fs.*
import std.io.* // SeekPosition 定义于 std.io（Seekable 接口所在包）

/* ============================================================================
 * 字节源抽象 —— "音频字节流从哪里来"（审查改进方向 3.1 的落地）
 *
 * 【为什么需要它】
 *   各容器读取器（FLAC / MP3 / WAV / Ogg-FLAC）真正依赖的只有一件事：
 *   **能按顺序拿到容器约定的字节流**，而与"字节来自裸文件还是内存"无关。
 *   把这件事抽出来之后，`AudioFile.openBytes` 可以把内存字节直接喂给
 *   任何读取器，不再需要"写临时文件再按路径打开"的桥接。
 *
 * 【虚拟偏移：所有源上的偏移口径】
 *   源上的偏移一律是**容器解码流的偏移**：
 *     - 裸文件容器（WAV/MP3/原生 FLAC）：偏移 N == 文件偏移 N
 *     - Ogg 封装：偏移 N == 重建流偏移 N（如何换算成文件偏移由源自理，
 *       见 ogg_flac_source.cj 的"虚拟偏移"说明）
 *   解码器的窗口偏移 / 游标 / 首帧偏移 / SEEKTABLE 定位点全部按此口径记账，
 *   因此"换源"不影响任何记账逻辑。这一点必须守住：记账错位的表现是
 *   **静默的错位音频**，不会报错，只会听起来不对。
 *
 * 【两层接口】
 *   ByteSource           —— 顺序读取 + 回到起点（reopen）。所有容器够用。
 *   SeekableByteSource   —— 额外提供绝对定位（seekTo）与总长（length）。
 *                           WAV（INFO 块回跳）与 MP3（audioStart 定位、
 *                           标签读取）需要；Ogg 重建流给不出有意义的
 *                           绝对定位，故不在此层。
 *
 * 【为什么 skip 是独立方法，而不是"读掉再扔"的循环】
 *   跳过的量可能很大（SEEKTABLE 定位点可达文件后段），"读掉再扔"要为
 *   被跳过的内容分配缓冲。文件源能直接 seek 越过，内存源就是移动游标 ——
 *   接口留出这个方法，实现才有优化的余地。
 * ========================================================================== */
/// 顺序字节源。
protected interface ByteSource {
    /// 精确读取 n 字节；不足即抛异常（不做"读多少算多少"）。
    func readExact(n: Int64): Array<UInt8>

    /// 跳过 n 字节；**不足以跳满时抛异常**（与 readExact 同一口径）。
    ///
    /// 【为什么"跳不足"必须抛，而不是跳到哪算哪】源的读取位置与解码器的
    /// 游标 / 窗口偏移必须始终一致。若跳不足却静默返回，源已停在流末尾而
    /// 调用方仍按原偏移记账 —— 二者错位后取到的数据会"看起来正常但内容
    /// 错位"，属于最难查的一类缺陷。抛异常把它挡在当场。
    func skip(n: Int64): Unit

    /// 尽量填满 `buf`，返回实际读到的字节数；**0 表示数据流正常结束**。
    func readSome(buf: Array<UInt8>): Int64

    /// 回到流起点（0 偏移），并复位源内部状态。
    ///
    /// 【为什么是"回到起点"而不是随机 seek】seek 的目标可能落在当前读取
    /// 位置**之前**，而窗口只前向回填。对文件实现这是"重开文件"（既回避
    /// "能否后退"的问题，也顺带复位页缓存等内部状态）；对内存实现是
    /// 游标归零。
    func reopen(): Unit

    /// 释放底层资源（幂等）。
    func close(): Unit
}

/// 可随机定位的字节源（在顺序能力之上追加绝对定位、位置查询与总长）。
protected interface SeekableByteSource <: ByteSource {
    /// 绝对定位到流内偏移 `offset`（0 = 流起点）。
    ///
    /// 越界（offset < 0 或 > length）抛 `CorruptedFileException`；
    /// 定位到 length（流末尾）合法，此后 readSome 返回 0。
    func seekTo(offset: Int64): Unit

    /// 当前读取位置（流内偏移；0 = 流起点）。
    func pos(): Int64

    /// 流总字节数。
    func length(): Int64
}

/// 裸文件字节源：源偏移与文件偏移一一对应。
protected class FileByteSource <: SeekableByteSource {
    private let _path: String
    private var _file: File
    private var _pos: Int64 = 0
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
                throw CorruptedFileException("字节流提前结束（需 ${n} 字节，已得 ${got}）：${_path}")
            }
            var i: Int64 = 0
            while (i < r) {
                buf[got + i] = scratch[i]
                i += 1
            }
            got += r
        }
        _pos += n
        buf
    }

    /// 跳过 n 字节：文件源直接定位越过（无需为被跳过的内容分配缓冲）。
    public func skip(n: Int64): Unit {
        seekTo(_pos + n)
    }

    public func readSome(buf: Array<UInt8>): Int64 {
        let r = _file.read(buf)
        if (r > 0) {
            _pos += r
        }
        r
    }

    public func seekTo(offset: Int64): Unit {
        if (offset < 0 || offset > _file.length) {
            throw CorruptedFileException("seek 越界（${offset}，文件长 ${_file.length}）：${_path}")
        }
        _file.seek(SeekPosition.Begin(offset))
        _pos = offset
    }

    public func pos(): Int64 {
        _pos
    }

    public func length(): Int64 {
        _file.length
    }

    public func reopen(): Unit {
        _file.close()
        _file = File(_path, Read)
        _pos = 0
    }

    public func close(): Unit {
        if (!_closed) {
            _closed = true
            _file.close()
        }
    }
}

/// 内存字节源：字节全部驻留在数组里（`openBytes` 的直通载体）。
///
/// reopen = 游标归零；seekTo = 游标赋值。无任何系统资源，close 为空操作。
protected class MemoryByteSource <: SeekableByteSource {
    private let _data: Array<UInt8>
    private var _pos: Int64 = 0

    /// 持有调用方传入的数组（不拷贝）：读取器的窗口/游标都不会修改它，
    /// 共享是安全的；拷贝一份反而让 openBytes 的内存占用翻倍。
    protected init(data: Array<UInt8>) {
        this._data = data
    }

    public func readExact(n: Int64): Array<UInt8> {
        if (_pos + n > _data.size) {
            throw CorruptedFileException("字节流提前结束（需 ${n} 字节，已得 ${_data.size - _pos}）")
        }
        let out = _data[_pos.._pos + n]
        _pos += n
        out
    }

    public func skip(n: Int64): Unit {
        if (n < 0 || _pos + n > _data.size) {
            throw CorruptedFileException("skip 越界（需跳 ${n} 字节，仅剩 ${_data.size - _pos}）")
        }
        _pos += n
    }

    public func readSome(buf: Array<UInt8>): Int64 {
        let remaining = _data.size - _pos
        if (remaining <= 0) {
            return 0
        }
        let take = if (buf.size < remaining) {
            buf.size
        } else {
            remaining
        }
        var i: Int64 = 0
        while (i < take) {
            buf[i] = _data[_pos + i]
            i += 1
        }
        _pos += take
        take
    }

    public func seekTo(offset: Int64): Unit {
        if (offset < 0 || offset > _data.size) {
            throw CorruptedFileException("seek 越界（${offset}，流长 ${_data.size}）")
        }
        _pos = offset
    }

    public func pos(): Int64 {
        _pos
    }

    public func length(): Int64 {
        _data.size
    }

    public func reopen(): Unit {
        _pos = 0
    }

    public func close(): Unit {
        // 内存源无系统资源；保持幂等空操作以对齐接口契约
    }
}
