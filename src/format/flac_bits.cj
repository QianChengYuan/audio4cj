package audio4cj.format

import audio4cj.core.CorruptedFileException

/* ============================================================================
 * FLAC 比特读取器
 *
 * 【为什么单独一个文件、并单独测试】
 *   FLAC 是**逐位**编码的格式：子帧类型占 6 位、Rice 参数占 4 或 5 位、
 *   wasted bits 用一元码、帧/样本号用变长 UTF-8 式编码。解码器需要大量
 *   细粒度的位读取。
 *
 *   位读取一旦有错，症状会表现为"整段样本值全错"——从上层完全看不出是位序
 *   错了还是预测算错了。所以把它独立出来先做对、先测透，是后面几百行算法
 *   代码可调试的前提。
 *
 * 【位序：最容易搞错的地方】
 *   FLAC 规定比特从每个字节的**最高位**开始读取（MSB-first）。
 *   注意这与"字节序"是两件事：多字节整数仍有大小端之分，而**位序固定**
 *   为 MSB-first。本实现只负责位序，字节序由调用方按字段语义处理。
 *
 * 【溢出语义：本文件刻意全部用 Int64/UInt64 加宽】
 *   pcm/convert.cj 里记着一处实测教训：仓颉的数值类型转换**默认带溢出检查**，
 *   `Int16(raw)` 在 raw > 32767 时会抛 OverflowException。FLAC 的解码路径
 *   全是符号整数运算，若按位宽就地转换会频繁抛异常。因此本文件统一先读成
 *   UInt64，再用 Int64 做符号扩展 —— Int64 的余量足够容纳 FLAC 的全部字段
 *   （最大 36 位的 UTF-8 式编码 + 32 位样本），从而**在构造上避免溢出**。
 * ========================================================================== */

/// 以 **MSB-first** 位序从字节数组读取定长与变长字段的游标。
///
/// 越界一律抛 `CorruptedFileException`：截断的文件必须在解析阶段被明确拒绝，
/// 而不是让后续算法拿到 0 继续算出垃圾样本（§4.1 铁律：不用返回值表达错误）。
///
/// 非线程安全（与库内其它读取器一致）。
protected class BitReader {
    private let _data: Array<UInt8>

    /// 有效位长上限（可以小于数组长度）。
    ///
    /// 【为什么需要它】流式解码会**复用同一个数组反复回填**（见
    /// flac_bitstream.cj 的窗口读取），数组尾部保留的是上一轮的残留字节。
    /// 若不显式限定"到哪一位为止是本次有效数据"，一个被截断的文件会被
    /// 静默读成上一轮的残留内容，而不是抛异常 —— 这是极难发现的错误来源。
    private var _bitLimit: Int64

    /// 当前读取位置，单位是**位**，从 0 开始。
    private var _pos: Int64 = 0

    protected init(data: Array<UInt8>) {
        this._data = data
        this._bitLimit = data.size * 8
    }

    /// 限定有效位长（流式窗口每次回填后调用）。
    protected func limitTo(validBytes: Int64): Unit {
        if (validBytes < 0 || validBytes > _data.size) {
            throw CorruptedFileException("窗口有效长度 ${validBytes} 超出缓冲区容量 ${_data.size}")
        }
        _bitLimit = validBytes * 8
        if (_pos > _bitLimit) {
            _pos = _bitLimit
        }
    }

    // ------------------------------------------------------------------
    // 位置与状态
    // ------------------------------------------------------------------

    /// 总位数。
    protected func bitLength(): Int64 {
        _data.size * 8
    }

    /// 当前位偏移（调试与帧边界记录用）。
    protected func bitPosition(): Int64 {
        _pos
    }

    /// 把读取位置移到指定**位**偏移（供解码器回退到帧起点重试）。
    protected func seekToBit(position: Int64): Unit {
        if (position < 0 || position > bitLength()) {
            throw CorruptedFileException("位偏移越界：${position}（总长 ${bitLength()} 位）")
        }
        _pos = position
    }

    /// 剩余可读位数。
    protected func remainingBits(): Int64 {
        let left = bitLength() - _pos
        if (left < 0) {
            0
        } else {
            left
        }
    }

    protected func isExhausted(): Bool {
        _pos >= bitLength()
    }

    /// 跳过剩余位直到下个字节边界。
    protected func alignToByte(): Unit {
        let rem = _pos % 8
        if (rem != 0) {
            _pos += 8 - rem
        }
    }

    // ------------------------------------------------------------------
    // 定长读取
    // ------------------------------------------------------------------

    /// 读 1 位，返回 Bool（`true` 表示该位为 1）。
    protected func readBit(): Bool {
        readBits(1) == UInt64(1)
    }

    /// 读 `count` 位（0 < count <= 64），返回**无符号**值（高位补 0）。
    ///
    /// 实现按"每个字节能提供多少位"成块拼接，而不是逐位循环 ——
    /// 后者在几百 MB 的音频上会成为主要开销。
    protected func readBits(count: Int64): UInt64 {
        if (count < 0 || count > 64) {
            throw CorruptedFileException("非法位宽：${count}")
        }
        if (count == 0) {
            return 0
        }
        if (remainingBits() < count) {
            throw CorruptedFileException("FLAC 比特流截断（需 ${count} 位，仅剩 ${remainingBits()} 位）")
        }

        var value: UInt64 = 0
        var left = count
        while (left > 0) {
            let byteIndex = _pos / 8
            let bitOffset = _pos % 8 // 0 表示该字节的最高位
            let available = 8 - bitOffset // 该字节还能提供几位
            let take = if (available < left) {
                available
            } else {
                left
            }

            // 取出该字节从 bitOffset 开始、长度为 take 的位段（仍保持 MSB-first 语义）
            let shift = 8 - bitOffset - take
            let mask = (UInt64(1) << UInt64(take)) - 1
            let chunk = (UInt64(_data[byteIndex]) >> UInt64(shift)) & mask

            value = (value << UInt64(take)) | chunk
            _pos += take
            left -= take
        }
        value
    }

    /// 读 `count` 位并按**二进制补码**做符号扩展，返回 Int64。
    ///
    /// 符号扩展用 `Int64(raw) - 2^count` 完成：因 raw 与 2^count 都远小于
    /// Int64 上限（count <= 36），这一步在构造上不可能溢出。
    protected func readSignedBits(count: Int64): Int64 {
        if (count <= 0) {
            return 0
        }
        let raw = readBits(count)
        let signBit = UInt64(1) << UInt64(count - 1)
        if ((raw & signBit) != UInt64(0)) {
            Int64(raw) - (Int64(1) << count)
        } else {
            Int64(raw)
        }
    }

    // ------------------------------------------------------------------
    // 变长读取（FLAC 特有的两种编码）
    // ------------------------------------------------------------------

    /// 读一元码：计数**连续的 0**，直到读到一个 1 为止（该 1 被消费），返回 0 的个数。
    ///
    /// 不会死循环：位耗尽时会由 `readBit` 抛异常终止。
    protected func readUnary(): Int64 {
        var count: Int64 = 0
        while (!readBit()) {
            count += 1
        }
        count
    }

    /// 读 FLAC 的「UTF-8 式」变长整数（帧号与样本号使用），最长 7 字节 / 36 位。
    ///
    /// 编码规则（首字节前导 1 的个数 N 决定续字节数）：
    ///   N = 0         -> 1 字节，值占 7 位
    ///   N = 2..7      -> N 字节，续字节均以 0b10 开头，各贡献 6 位
    ///                   值位数 = (7 - N) + 6 * (N - 1)
    ///   N = 1 或 N > 7 -> 非法（0x80..0xBF 是续字节，不能作首字节）
    protected func readUtf8Number(): UInt64 {
        // 统计首字节前导 1 的个数
        var leadingOnes: Int64 = 0
        while (leadingOnes < 8 && readBit()) {
            leadingOnes += 1
        }

        if (leadingOnes == 0) {
            // 单字节形式：首字节剩余 7 位即全部数值位
            return readBits(7)
        }
        if (leadingOnes == 1 || leadingOnes > 7) {
            throw CorruptedFileException("FLAC 的 UTF-8 式整数首字节非法（前导 1 个数 ${leadingOnes}）")
        }

        // 首字节中剩余的数值位
        let firstBits = 7 - leadingOnes
        var value: UInt64 = readBits(firstBits)

        // 逐个续字节：须以 0b10 开头，随后 6 位为数值
        var i: Int64 = 1
        while (i < leadingOnes) {
            if (readBits(2) != UInt64(0b10)) {
                throw CorruptedFileException("FLAC 的 UTF-8 式整数续字节非法（第 ${i} 个）")
            }
            value = (value << 6) | readBits(6)
            i += 1
        }
        value
    }
}
