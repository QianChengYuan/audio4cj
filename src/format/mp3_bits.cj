package audio4cj.format

import std.core.*
import std.collection.*

/* ============================================================================
 * MP3 —— 位读取器
 *
 * 【两个层次，别混用】
 *   · `Mp3Bits`：**慢但通用**的读取器 —— 按"位位置"寻址（`pos`/`limit` 可读写），
 *     side info、标度因子、Layer I/II 全用它。需要"回退/复位位位置"的地方
 *     （`l3ReadSideInfo` 校验后复位、`l3Huffman` 结尾对齐到 granule 末尾）
 *     也依赖它的显式位位置。
 *   · `L3BitCache`：**快但不可回退** —— 一次缓存 32 位，只适合 Huffman 那种
 *     "只看不回退"的连续读取。
 *
 * 【为什么位位置是显式的】MP3 的帧内数据是"按声道、按 granule"排列的，每段各有
 *   自己的长度上限；读取器必须能被**硬设到某处**并以 `limit` 为界，
 *   而不是像流式解析那样只管往下走。这是本层与"普通比特流读取"最大的不同。
 * ========================================================================== */

/// 通用位读取器：`buf` 是数据、`pos` 是当前**位**位置、`limit` 是可用的位总数。
///
/// 三个字段都是 `var`：解码过程中会整体换 buf（位池重组）、硬设 pos（对齐到
/// granule 末尾）、按 limit 判定越界 —— 这正是"显式位位置"的用途。
protected class Mp3Bits {
    var buf: Array<UInt8>
    var pos: Int64
    var limit: Int64
    public init() {
        buf = Array<UInt8>(0, repeat: 0)
        pos = 0
        limit = 0
    }
}

/// Layer III 霍夫曼解码用的位缓存。
///
/// 对应原参照实现里的三个 C 宏局部量（bs_cache / bs_sh / next_index）：
/// 它们必须**一起**变更 —— flush 同时改缓存与位移量，check 把整字节回填进缓存。
/// 用类字段承载后即可在方法里原子更新，这是仓颉里替代 C 宏的常规做法，
/// 也避免了为这几行取位逻辑引入一个宏包（独立模块 + 编译顺序依赖）。
protected class L3BitCache {
    var cache: Int64
    var sh: Int64
    var nextIndex: Int64
    let buf: Array<UInt8>

    init(bs: Mp3Bits) {
        this.buf = bs.buf
        let idx = bs.pos / 8
        // 预取 4 字节拼成 32 位缓存，再按帧内位偏移左移对齐
        let c: Int64 = (((Int64(bs.buf[idx]) * 256 + Int64(bs.buf[idx + 1])) * 256 + Int64(bs.buf[idx + 2])) * 256 +
            Int64(bs.buf[idx + 3])) << (bs.pos & 7)
        this.cache = c & 0xFFFFFFFF
        this.sh = (bs.pos & 7) - 8
        this.nextIndex = idx + 4
    }

    /// 窥视高 n 位而不消费。
    func peek(n: Int64): Int64 {
        ((cache & 0xFFFFFFFF) >> (32 - n)) & ((1 << n) - 1)
    }

    /// 消费 n 位（只移动缓存与位移量，字节回填交给 check）。
    func flush(n: Int64): Unit {
        cache = (cache << (n & 31)) & 0xFFFFFFFF
        sh = sh + n
    }

    /// 用缓冲区后续字节回填缓存中被消费掉的整字节。
    func check(): Unit {
        while (sh >= 0) {
            if (nextIndex >= buf.size) {
                break
            }
            cache = (cache | (Int64(buf[nextIndex]) << sh)) & 0xFFFFFFFF
            nextIndex = nextIndex + 1
            sh = sh - 8
        }
    }

    /// 当前已消费的位位置（与 granule 的 part2_3 边界比较用）。
    func pos(): Int64 {
        nextIndex * 8 - 24 + sh
    }
}

protected func bitsInit(bs: Mp3Bits, data: Array<UInt8>, bytes: Int64): Unit {
    bs.buf = data
    bs.pos = 0
    bs.limit = bytes * 8
}

protected func getBits(bs: Mp3Bits, nIn: Int64): Int64 {
    var n = nIn
    var next: Int64 = 0
    var cache: Int64 = 0
    let s = bs.pos & 7
    var shl = n + s

    var p = bs.pos >> 3
    bs.pos = bs.pos + n
    if (bs.pos > bs.limit) {
        return 0
    }

    p = p + 1
    next = Int64(bs.buf[p - 1]) & (255 >> s)
    while (shl > 8) {
        shl = shl - 8
        cache = cache | (next << shl)
        next = Int64(bs.buf[p])
        p = p + 1
    }

    let result = cache | (next >> (8 - shl))
    return result
}
