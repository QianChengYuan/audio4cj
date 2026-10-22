package audio4cj.format

import audio4cj.core.CorruptedFileException
import std.math.pow

/* ============================================================================
 * Vorbis 比特流读取与基础数值工具（纯仓颉）
 *
 * 【位序】Vorbis 的比特流是 **LSB-first**：一个字节的第 0 位先被读出，
 *   而不是像 FLAC 那样从最高位开始。这一点与项目已有的 BitReader（MSB-first）
 *   相反，因此不能复用，必须单独实现 —— 位序错了不会报错，只会解出静音或噪声，
 *   是最难定位的一类缺陷。
 *
 * 【越界语义】读越界不抛异常，而是置 `_eop` 并返回 0。理由是 Vorbis 的
 *   码本/floor 解码在包尾本来就会"读到 EOP"，调用方需要区分「正常包结束」
 *   与「结构错误」。调用方在关键位置检查 `isEop()` 后决定抛
 *   CorruptedFileException 还是把该声道当作静音。
 *
 * 本文件还承载三个按规范逐位复刻的数值函数：
 *   - ilog：Vorbis 规格的 log2，ilog(0)=0、ilog(1)=1、ilog(2)=2、ilog(3)=2...
 *   - bitReverse32：码本的规范码字是 MSB-first 定义的，而流是 LSB-first，
 *     故建表时统一反转一次。
 *   - float32Unpack：setup 头里的 32 位浮点（1 位符号 + 10 位指数 + 21 位尾数），
 *     指数偏置 788。
 * ========================================================================== */

/// Vorbis setup 头中「无码字」的哨兵值（与规范/stb_vorbis 的 NO_CODE 一致）。
protected let VORBIS_NO_CODE: Int64 = 255

/// Vorbis 码本/定长读取的上限（4 字节足够覆盖 32 位浮点与 24 位残差参数）。
protected let VORBIS_MAX_BITS: Int64 = 32

/// LSB-first 比特流读取器。
protected class VorbisBitReader {
    private let _data: Array<UInt8>
    private var _pos: Int64 = 0
    private var _eop: Bool = false

    protected init(data: Array<UInt8>) {
        this._data = data
    }

    /// 读 n 位（0 <= n <= 32），按 LSB-first 组装为整数。
    ///
    /// 越界时置 EOP 并返回 0。返回 0 与"真的读到 0"在正常路径上无歧义：
    /// 调用方在需要区分时必须先查 `isEop()`。
    protected func getBits(n: Int64): Int64 {
        if (n < 0 || n > VORBIS_MAX_BITS) {
            throw CorruptedFileException("Vorbis 比特宽度非法：${n}")
        }
        var value: Int64 = 0
        var i: Int64 = 0
        while (i < n) {
            if (_pos >= _data.size * 8) {
                _eop = true
                return 0
            }
            let byte = Int64(_data[_pos >> 3])
            let bit = (byte >> (_pos & 7)) & 1
            value |= bit << i
            _pos += 1
            i += 1
        }
        value
    }

    /// 读 1 位并返回 Bool。
    protected func getBool(): Bool {
        getBits(1) != 0
    }

    /// 当前是否已经读到包尾（或越过包尾）。
    protected func isEop(): Bool {
        _eop
    }

    /// 当前位偏移（调试用）。
    protected func bitPosition(): Int64 {
        _pos
    }

    /// 剩余位数（可能为负，表示已越界）。
    protected func remainingBits(): Int64 {
        _data.size * 8 - _pos
    }

    /// 跳过 n 位；不足时置 EOP。
    protected func skipBits(n: Int64): Unit {
        if (n < 0) {
            throw CorruptedFileException("Vorbis 跳过位数非法：${n}")
        }
        if (_pos + n > _data.size * 8) {
            _pos = _data.size * 8
            _eop = true
        } else {
            _pos += n
        }
    }
}

/// Vorbis 规格的 ilog：正整数 n 返回 floor(log2(n)) + 1，0/负数返回 0。
///
/// 例：ilog(0)=0、ilog(1)=1、ilog(2)=2、ilog(3)=2、ilog(4)=3。
protected func vorbisIlog(n: Int64): Int64 {
    if (n <= 0) {
        return 0
    }
    var value = n
    var bits: Int64 = 0
    while (value > 0) {
        bits += 1
        value >>= 1
    }
    bits
}

/// 32 位按位反转（只保留低 32 位）。
protected func vorbisBitReverse32(n: Int64): Int64 {
    var x = n & 0xFFFFFFFF
    x = ((x & 0xAAAAAAAA) >> 1) | ((x & 0x55555555) << 1)
    x = ((x & 0xCCCCCCCC) >> 2) | ((x & 0x33333333) << 2)
    x = ((x & 0xF0F0F0F0) >> 4) | ((x & 0x0F0F0F0F) << 4)
    x = ((x & 0xFF00FF00) >> 8) | ((x & 0x00FF00FF) << 8)
    ((x >> 16) | (x << 16)) & 0xFFFFFFFF
}

/// Vorbis setup 头里的 32 位浮点解包。
///
/// 布局（规范 §3.2.1）：1 位符号 + 10 位指数 + 21 位尾数，指数偏置 788。
/// 例：0x3F800000 附近的编码值会解出 1.0 量级的 `delta`。
protected func vorbisUnpackFloat32(raw: Int64): Float32 {
    let mantissa = raw & 0x1FFFFF
    let sign = (raw & 0x80000000) != 0
    let exponent = (raw & 0x7FE00000) >> 21
    var result = Float32(mantissa)
    if (sign) {
        result = -result
    }
    result * pow(Float32(2.0), Float32(exponent - 788))
}
