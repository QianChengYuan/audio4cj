package audio4cj.meta

import std.collection.*
import std.convert.*

/* ============================================================================
 * meta 层字节与文本工具 —— 开发文档 §10 M3
 *
 * 为什么单独建文件、而不复用 pcm/convert.cj：
 *   1. pcm 层只提供**小端无符号**读取，且 readInt* 为 private，跨包不可用；
 *   2. ID3v2 需要 **synchsafe 整数**（大端，每字节仅低 7 位有效），pcm 没有；
 *   3. 标签文本有四种编码（ISO-8859-1 / UTF-16LE / UTF-16BE / UTF-8），
 *      仓颉 std 只内置 UTF-8，其余必须手写；
 *   4. meta 是比 pcm 更基础的一层（标签解析与 PCM 无关），
 *      反向依赖 pcm 会造成层次倒置。
 *
 * 可见性：统一 protected（模块内可见，不对外暴露），与 format / codec 惯例一致。
 *
 * 已核实的 std 能力（2026-10-02 技能核对，未核实的写法一律不用）：
 *   - String.fromUtf8(Array<UInt8>): String          带 UTF-8 校验，非法抛 IllegalArgumentException
 *   - String.fromUtf8Unchecked / checkUtf8Encoding   校验与免校验构造
 *   - String(Array<Rune>): String                    由码点数组构造
 *   - Rune(UInt32)                                   整数转码点（Rune 不支持算术运算）
 *   - Int64.tryParse(String): Option<Int64>          安全解析，失败返回 None
 *   - String.split(String): Array<String> / trimAscii()
 *
 * 注意：未在技能中核实的项：无。本文件全部依赖上述已核实 API。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 整型读取
// ---------------------------------------------------------------------------

/// 读取 2 字节**大端**无符号整数。
protected func readUInt16BE(data: Array<UInt8>, offset: Int64): UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

/// 读取 4 字节**大端**无符号整数。
protected func readUInt32BE(data: Array<UInt8>, offset: Int64): UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1])
    let b2 = UInt32(data[offset + 2])
    let b3 = UInt32(data[offset + 3])
    (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

/// 读取 ID3v2 的 **synchsafe** 整数（4 字节大端，每字节仅低 7 位有效）。
///
/// ID3v2 用这种编码避免标签长度字段中出现 0xFF 字节，防止被误判为帧同步。
/// 最大值 (2^7)^4 - 1 = 268435455（约 256 MB）。
protected func readSynchsafe32(data: Array<UInt8>, offset: Int64): Int64 {
    let b0 = Int64(data[offset]) & 0x7F
    let b1 = Int64(data[offset + 1]) & 0x7F
    let b2 = Int64(data[offset + 2]) & 0x7F
    let b3 = Int64(data[offset + 3]) & 0x7F
    (b0 << 21) | (b1 << 14) | (b2 << 7) | b3
}

// ---------------------------------------------------------------------------
// ASCII 比较
// ---------------------------------------------------------------------------

/// 判断 data 的 offset 处是否为给定 ASCII 串（用于识别 "TAG" / "ID3" 等标识）。
protected func matchAsciiAt(data: Array<UInt8>, offset: Int64, text: String): Bool {
    let bytes = text.toArray()
    if (offset < 0 || offset + bytes.size > data.size) {
        return false
    }
    for (i in 0..bytes.size) {
        if (data[offset + i] != bytes[i]) {
            return false
        }
    }
    true
}

// ---------------------------------------------------------------------------
// 数组处理
// ---------------------------------------------------------------------------

/// 安全切片：越界时自动收敛到可用范围，**不抛异常**。
///
/// 标签数据来自不可信输入，长度字段可能与实际数据不符，
/// 因此解析路径上全程使用本函数而非直接切片。
protected func safeSlice(data: Array<UInt8>, start: Int64, length: Int64): Array<UInt8> {
    if (start < 0 || length <= 0 || start >= data.size) {
        return Array<UInt8>()
    }
    var end = start + length
    if (end > data.size) {
        end = data.size
    }
    data[start..end]
}

/// 截断到第一个 0x00（**单字节编码**的字符串终止符）。
///
/// 注意：不可用于 UTF-16 —— UTF-16 的 ASCII 字符高字节即为 0x00，
/// 逐字节截断会错误地把 "AB" 截成 "A"。
protected func truncateAtNulByte(data: Array<UInt8>): Array<UInt8> {
    for (i in 0..data.size) {
        if (data[i] == 0u8) {
            return data[0..i]
        }
    }
    data
}

/// 去除尾部的 ASCII 空格与 NUL 填充（ID3v1 的定长字段需要）。
protected func trimTrailingPadding(data: Array<UInt8>): Array<UInt8> {
    var end = data.size
    while (end > 0) {
        let b = data[end - 1]
        if (b == 0u8 || b == 0x20u8) {
            end -= 1
        } else {
            break
        }
    }
    data[0..end]
}

// ---------------------------------------------------------------------------
// 文本解码（ID3v2 的四种编码）
// ---------------------------------------------------------------------------

/// ISO-8859-1（Latin-1）解码：每个字节 0x00–0xFF 直接映射到码点 U+0000–U+00FF。
///
/// 注意：仓颉 std **无** Latin-1 转换能力（已核实），故手写。
/// Rune 不支持算术运算，必须先转 UInt32 再构造 Rune。
protected func decodeLatin1(data: Array<UInt8>): String {
    let runes = Array<Rune>(data.size, {i => Rune(UInt32(data[i]))})
    String(runes)
}

/// UTF-8 解码（**容错版**）。
///
/// 先校验合法性；非法时退回 Latin-1 而非抛异常 ——
/// 标签属不可信输入，单帧编码损坏不应导致整个标签读取失败。
protected func decodeUtf8Safe(data: Array<UInt8>): String {
    if (String.checkUtf8Encoding(data)) {
        String.fromUtf8(data)
    } else {
        decodeLatin1(data)
    }
}

/// UTF-16 解码。
///
/// - 有 BOM（FF FE / FE FF）时以 BOM 为准，BOM 自身不进入结果；
/// - 无 BOM 时按 `defaultBigEndian` 指定的字节序解释
///   （ID3v2 编码 2 = UTF-16BE 无 BOM → true；编码 1 无 BOM 时按惯例用 LE → false）；
/// - 支持**代理对**合成增补平面码点（否则 emoji 等字符会解坏）；
/// - 遇到码元 0x0000 视为终止符；
/// - 结尾多余的单字节（data.size 为奇数）被忽略。
///
/// 注意：仓颉 std 无 UTF-16 解码能力（已核实），故手写。
protected func decodeUtf16(data: Array<UInt8>, defaultBigEndian: Bool): String {
    var big = defaultBigEndian
    var offset: Int64 = 0

    if (data.size >= 2) {
        let b0 = data[0]
        let b1 = data[1]
        if (b0 == 0xFFu8 && b1 == 0xFEu8) {
            big = false
            offset = 2
        } else if (b0 == 0xFEu8 && b1 == 0xFFu8) {
            big = true
            offset = 2
        }
    }

    let runes = ArrayList<Rune>()
    var i = offset
    while (i + 1 < data.size) {
        let unit = if (big) {
            (UInt32(data[i]) << 8) | UInt32(data[i + 1])
        } else {
            (UInt32(data[i + 1]) << 8) | UInt32(data[i])
        }

        if (unit == 0u32) {
            break
        }

        // 代理对：高代理 D800–DBFF + 低代理 DC00–DFFF
        if (unit >= 0xD800u32 && unit <= 0xDBFFu32 && i + 3 < data.size) {
            let lo = if (big) {
                (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
            } else {
                (UInt32(data[i + 3]) << 8) | UInt32(data[i + 2])
            }
            if (lo >= 0xDC00u32 && lo <= 0xDFFFu32) {
                let cp = 0x10000u32 + ((unit - 0xD800u32) << 10) + (lo - 0xDC00u32)
                runes.add(Rune(cp))
                i += 4
                continue
            }
        }

        runes.add(Rune(unit))
        i += 2
    }

    String(runes.toArray())
}

/// 按 ID3v2 的**文本编码标识字节**解码帧体。
///
/// 编码标识（ID3v2.2/2.3/2.4 一致）：
///   0x00 = ISO-8859-1
///   0x01 = UTF-16（带 BOM）
///   0x02 = UTF-16BE（无 BOM）
///   0x03 = UTF-8（仅 ID3v2.4）
///
/// 未知编码按 Latin-1 兜底，绝不抛异常。
protected func decodeText(data: Array<UInt8>, encoding: UInt8): String {
    match (encoding) {
        case 0 => decodeLatin1(truncateAtNulByte(data))
        case 1 => decodeUtf16(data, false)
        case 2 => decodeUtf16(data, true)
        case 3 => decodeUtf8Safe(truncateAtNulByte(data))
        case _ => decodeLatin1(truncateAtNulByte(data))
    }
}

// ---------------------------------------------------------------------------
// 字段值解析
// ---------------------------------------------------------------------------

/// 把字符串解析为非负 Int64；解析失败或为负数时返回 None。
///
/// 标签数据不可信（可能是 "0x3"、"-1"、"" 等），
/// 一律用 tryParse 而非 parse，避免抛异常中断整个标签读取。
protected func tryParseNonNegativeInt(value: String): ?Int64 {
    match (Int64.tryParse(value.trimAscii())) {
        case Some(v) =>
            if (v >= 0) {
                return Some(v)
            }
            return None
        case None => return None
    }
}

/// 解析形如 `"3"` 或 `"3/12"` 的数字对，返回 `(当前值, 总值)`。
///
/// 用于 ID3v2 的 `TRCK`（音轨）/ `TPOS`（碟号）、Vorbis 的 `TRACKNUMBER` 等字段。
/// 任一部分缺失或非法即为 None（**不抛异常**）。
protected func parseNumberPair(value: String): (Option<Int64>, Option<Int64>) {
    let parts = value.trimAscii().split("/")

    // 注意：这里不用 `let x = if (...) { ... } else { None }` 形式 ——
    // 仓颉要求 `None` 必须能从上下文推断出类型参数，而 if 分支内部不提供该上下文。
    var first: ?Int64 = None
    if (parts.size >= 1) {
        first = tryParseNonNegativeInt(parts[0])
    }

    var second: ?Int64 = None
    if (parts.size >= 2) {
        second = tryParseNonNegativeInt(parts[1])
    }

    (first, second)
}
