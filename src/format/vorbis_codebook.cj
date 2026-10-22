package audio4cj.format

import audio4cj.core.CorruptedFileException
import std.collection.ArrayList

/* ============================================================================
 * Vorbis 码本（codebook）—— setup 头解析 + Huffman 解码 + 量化值展开
 *
 * 【为什么不用 stb_vorbis 的"稀疏码本"优化】
 *   stb 为了省内存，对稀疏码本只保存实际出现的条目，并用 sorted_values
 *   做一次间接映射。本项目优先正确性与可读性：统一展开为 entries 大小，
 *   未出现的条目保留 NO_CODE。行为与 stb 的稀疏路径等价，内存上限由
 *   Vorbis 规范约束（entries 为 24 位，实际素材在几千量级）。
 *
 * 【码字方向】规范把 Huffman 码字写成 MSB-first，但 Vorbis 流是 LSB-first。
 *   本实现沿用 stb 的做法：建表时把规范码字反转一次（vorbisBitReverse32），
 *   解码树按"低位先走"建树。这样每个码字的第 0 位就是流中的下一位。
 *
 * 【量化值展开】lookup_type 1 的索引是"按维度拆成 lookup_values 进制"，
 *   type 2 则直接一一对应。无论哪种，最终都展开成
 *   `multiplicands[symbol * dimensions + k]`，解码时不需要再做除法/取模。
 *   展开公式与 stb 的 `STB_VORBIS_DIVIDES_IN_CODEBOOK` 未定义路径一致。
 * ========================================================================== */

/// Vorbis 码本。
protected class VorbisCodebook {
    /// 每个码字向量的维度。
    protected var dimensions: Int64 = 0

    /// 码字条目数。
    protected var entries: Int64 = 0

    /// 每条目的码长；NO_CODE 表示该条目不存在。
    protected var lengths: Array<Int64> = Array<Int64>(0, repeat: 0)

    /// 反转后的规范码字（LSB-first 语义）；不存在的行为 0。
    protected var codewords: Array<Int64> = Array<Int64>(0, repeat: 0)

    /// 量化值查找类型（0=无量化值，1/2 在展开后统一为 2）。
    protected var lookupType: Int64 = 0

    /// 量化值最小值。
    protected var minimumValue: Float32 = 0.0

    /// 量化值步长。
    protected var deltaValue: Float32 = 0.0

    /// 每个量化值的位宽。
    protected var valueBits: Int64 = 0

    /// 量化值是否按维度累加（sequence_p）。
    protected var sequenceP: Bool = false

    /// lookup_type 1 的进制数；type 2 时为 entries*dimensions。
    protected var lookupValues: Int64 = 0

    /// 展开后的量化值（维度优先，symbol*dimensions + k）。
    protected var multiplicands: Array<Float32> = Array<Float32>(0, repeat: 0.0)

    // ---- 解码树（三数组表示；symbol >= 0 表示叶子）----
    private var _child0: ArrayList<Int64> = ArrayList<Int64>()
    private var _child1: ArrayList<Int64> = ArrayList<Int64>()
    private var _symbol: ArrayList<Int64> = ArrayList<Int64>()

    protected init() {}

    /// 从 setup 头解析一个码本。结构非法时抛 CorruptedFileException。
    protected static func parse(br: VorbisBitReader): VorbisCodebook {
        let book = VorbisCodebook()

        // 同步字 0x42 0x43 0x56（"BCV"）
        if (br.getBits(8) != 0x42 || br.getBits(8) != 0x43 || br.getBits(8) != 0x56) {
            throw CorruptedFileException("Vorbis 码本同步字不是 0x42 0x43 0x56")
        }

        book.dimensions = br.getBits(8) | (br.getBits(8) << 8)
        book.entries = br.getBits(8) | (br.getBits(8) << 8) | (br.getBits(8) << 16)
        if (book.dimensions == 0 && book.entries != 0) {
            throw CorruptedFileException("Vorbis 码本维度为 0 但条目数非 0")
        }
        if (book.entries <= 0) {
            throw CorruptedFileException("Vorbis 码本条目数非法：${book.entries}")
        }

        let ordered = br.getBits(1) != 0
        let sparse = if (ordered) {
            false
        } else {
            br.getBits(1) != 0
        }

        book.lengths = Array<Int64>(book.entries, repeat: VORBIS_NO_CODE)

        if (ordered) {
            var currentEntry: Int64 = 0
            var currentLength = br.getBits(5) + 1
            while (currentEntry < book.entries) {
                let limit = book.entries - currentEntry
                let n = br.getBits(vorbisIlog(limit))
                if (currentLength >= 32) {
                    throw CorruptedFileException("Vorbis 码本码长达到 32，规范不允许")
                }
                if (n < 0 || currentEntry + n > book.entries) {
                    throw CorruptedFileException("Vorbis 有序码本长度序列非法（entry=${currentEntry}, n=${n}）")
                }
                var j: Int64 = 0
                while (j < n) {
                    book.lengths[currentEntry + j] = currentLength
                    j += 1
                }
                currentEntry += n
                currentLength += 1
            }
        } else {
            var j: Int64 = 0
            while (j < book.entries) {
                let present = if (sparse) {
                    br.getBits(1) != 0
                } else {
                    true
                }
                if (present) {
                    let len = br.getBits(5) + 1
                    if (len == 32) {
                        throw CorruptedFileException("Vorbis 码本码长为 32，规范不允许")
                    }
                    book.lengths[j] = len
                }
                j += 1
            }
        }

        book.codewords = computeVorbisCodewords(book.lengths, book.entries)
        book.buildTree()

        // ---- 量化值 ----
        book.lookupType = br.getBits(4)
        if (book.lookupType > 2) {
            throw CorruptedFileException("Vorbis 码本 lookup_type=${book.lookupType}，规范只允许 0..2")
        }
        if (book.lookupType > 0) {
            book.minimumValue = vorbisUnpackFloat32(br.getBits(32))
            book.deltaValue = vorbisUnpackFloat32(br.getBits(32))
            book.valueBits = br.getBits(4) + 1
            book.sequenceP = br.getBits(1) != 0

            if (book.lookupType == 1) {
                let values = vorbisLookup1Values(book.entries, book.dimensions)
                if (values <= 0) {
                    throw CorruptedFileException(
                        "Vorbis 码本 lookup1_values 计算失败（entries=${book.entries}, dim=${book.dimensions}）")
                }
                book.lookupValues = values
            } else {
                book.lookupValues = book.entries * book.dimensions
            }
            if (book.lookupValues <= 0) {
                throw CorruptedFileException("Vorbis 码本 lookup_values 为 0")
            }

            let mults = Array<Int64>(book.lookupValues, repeat: 0)
            var j: Int64 = 0
            while (j < book.lookupValues) {
                mults[j] = br.getBits(book.valueBits)
                j += 1
            }

            if (book.lookupType == 1) {
                book.multiplicands = Array<Float32>(book.entries * book.dimensions, repeat: 0.0)
                var symbol: Int64 = 0
                while (symbol < book.entries) {
                    var div: Int64 = 1
                    var last: Float32 = 0.0
                    var k: Int64 = 0
                    while (k < book.dimensions) {
                        let off = (symbol / div) % book.lookupValues
                        let val = Float32(mults[off]) * book.deltaValue + book.minimumValue + last
                        book.multiplicands[symbol * book.dimensions + k] = val
                        if (book.sequenceP) {
                            last = val
                        }
                        if (k + 1 < book.dimensions) {
                            if (div > Int64.Max / book.lookupValues) {
                                throw CorruptedFileException("Vorbis 码本 lookup1 进制展开溢出")
                            }
                            div *= book.lookupValues
                        }
                        k += 1
                    }
                    symbol += 1
                }
                // 展开后与 lookup_type 2 的访问方式一致，统一成 2。
                book.lookupType = 2
            } else {
                book.multiplicands = Array<Float32>(book.lookupValues, repeat: 0.0)
                var last: Float32 = 0.0
                var k: Int64 = 0
                while (k < book.lookupValues) {
                    let val = Float32(mults[k]) * book.deltaValue + book.minimumValue + last
                    book.multiplicands[k] = val
                    if (book.sequenceP) {
                        last = val
                    }
                    k += 1
                }
            }
        }

        book
    }

    /// 解码一个标量符号；读到 EOP 或非法码时返回 -1。
    protected func decodeSymbol(br: VorbisBitReader): Int64 {
        if (_symbol.size == 0) {
            return -1
        }
        var node: Int64 = 0
        while (true) {
            let sym = _symbol[node]
            if (sym >= 0) {
                return sym
            }
            let bit = br.getBits(1)
            if (br.isEop()) {
                return -1
            }
            let next = if (bit == 0) {
                _child0[node]
            } else {
                _child1[node]
            }
            if (next < 0) {
                return -1
            }
            node = next
        }
        -1
    }

    /// 解码一个码字向量并**累加**到 output[offset..offset+len)。
    ///
    /// len 可小于 dimensions（残差块尾部），此时只写前 len 个分量。
    protected func decodeVector(br: VorbisBitReader, output: Array<Float32>, offset: Int64, len: Int64): Bool {
        let symbol = decodeSymbol(br)
        if (symbol < 0) {
            return false
        }
        var n = len
        if (n > dimensions) {
            n = dimensions
        }
        if (n <= 0) {
            return true
        }
        let base = symbol * dimensions
        if (sequenceP) {
            var last: Float32 = 0.0
            var i: Int64 = 0
            while (i < n) {
                let val = multiplicands[base + i] + last
                output[offset + i] += val
                last = val + minimumValue
                i += 1
            }
        } else {
            var i: Int64 = 0
            while (i < n) {
                output[offset + i] += multiplicands[base + i]
                i += 1
            }
        }
        true
    }

    /// 解码一个码字向量并按固定步长累加到 output（residue type 0 用）。
    protected func decodeStep(
        br: VorbisBitReader,
        output: Array<Float32>,
        offset: Int64,
        len: Int64,
        step: Int64
    ): Bool {
        let symbol = decodeSymbol(br)
        if (symbol < 0) {
            return false
        }
        var n = len
        if (n > dimensions) {
            n = dimensions
        }
        if (n <= 0) {
            return true
        }
        let base = symbol * dimensions
        var last: Float32 = 0.0
        var i: Int64 = 0
        while (i < n) {
            let val = multiplicands[base + i] + last
            output[offset + i * step] += val
            if (sequenceP) {
                last = val
            }
            i += 1
        }
        true
    }

    // ------------------------------------------------------------------
    // 建树
    // ------------------------------------------------------------------

    private func buildTree(): Unit {
        _child0 = ArrayList<Int64>()
        _child1 = ArrayList<Int64>()
        _symbol = ArrayList<Int64>()
        let root = newNode(-1)

        var i: Int64 = 0
        while (i < entries) {
            let len = lengths[i]
            if (len != VORBIS_NO_CODE) {
                if (len <= 0 || len >= 32) {
                    throw CorruptedFileException("Vorbis 码本码长非法：${len}（条目 ${i}）")
                }
                var node = root
                var d: Int64 = 0
                while (d < len) {
                    let bit = (codewords[i] >> d) & 1
                    if (d == len - 1) {
                        if (_symbol[node] >= 0) {
                            throw CorruptedFileException("Vorbis 码本是某个既有码字的前缀（条目 ${i}）")
                        }
                        let leaf = newNode(i)
                        if (bit == 0) {
                            if (_child0[node] >= 0) {
                                throw CorruptedFileException("Vorbis 码本存在码字冲突（条目 ${i}）")
                            }
                            _child0[node] = leaf
                        } else {
                            if (_child1[node] >= 0) {
                                throw CorruptedFileException("Vorbis 码本存在码字冲突（条目 ${i}）")
                            }
                            _child1[node] = leaf
                        }
                    } else {
                        if (_symbol[node] >= 0) {
                            throw CorruptedFileException("Vorbis 码本是某个既有码字的前缀（条目 ${i}）")
                        }
                        var next = if (bit == 0) {
                            _child0[node]
                        } else {
                            _child1[node]
                        }
                        if (next < 0) {
                            next = newNode(-1)
                            if (bit == 0) {
                                _child0[node] = next
                            } else {
                                _child1[node] = next
                            }
                        }
                        node = next
                    }
                    d += 1
                }
            }
            i += 1
        }
    }

    private func newNode(symbol: Int64): Int64 {
        let index = _symbol.size
        _symbol.add(symbol)
        _child0.add(-1)
        _child1.add(-1)
        index
    }
}

/// 计算规范 Huffman 码字（与 stb_vorbis 的 compute_codewords 非稀疏路径一致）。
///
/// 算法要点：从第一个有效条目开始，按码长从短到长分配"最低可用叶子"，
/// 再把该叶子的可用性向更深层传播。返回的码字已做 32 位反转，供 LSB-first 解码。
private func computeVorbisCodewords(lengths: Array<Int64>, entries: Int64): Array<Int64> {
    let codewords = Array<Int64>(entries, repeat: 0)
    let available = Array<Int64>(33, repeat: 0)

    var first: Int64 = 0
    while (first < entries && lengths[first] == VORBIS_NO_CODE) {
        first += 1
    }
    if (first == entries) {
        return codewords
    }
    let firstLen = lengths[first]
    if (firstLen <= 0 || firstLen >= 32) {
        throw CorruptedFileException("Vorbis 码本首个有效码长非法：${firstLen}")
    }
    codewords[first] = 0
    var i: Int64 = 1
    while (i <= firstLen) {
        available[i] = Int64(1) << (32 - i)
        i += 1
    }

    var index = first + 1
    while (index < entries) {
        let len = lengths[index]
        if (len != VORBIS_NO_CODE) {
            var z = len
            while (z > 0 && available[z] == 0) {
                z -= 1
            }
            if (z == 0) {
                throw CorruptedFileException("Vorbis 码本无法分配码字（条目 ${index}）")
            }
            let res = available[z]
            available[z] = 0
            codewords[index] = vorbisBitReverse32(res)
            if (z != len) {
                var y = len
                while (y > z) {
                    available[y] = res + (Int64(1) << (32 - y))
                    y -= 1
                }
            }
        }
        index += 1
    }

    codewords
}

/// 计算 lookup_type 1 的进制数：最大的 r 使 r^dimensions <= entries。
private func vorbisLookup1Values(entries: Int64, dimensions: Int64): Int64 {
    if (entries <= 0 || dimensions <= 0) {
        return -1
    }
    var r: Int64 = 1
    while (vorbisPowInt(r + 1, dimensions) <= entries) {
        r += 1
    }
    if (vorbisPowInt(r, dimensions) > entries) {
        return -1
    }
    r
}

/// 整数幂；溢出时返回 Int64.Max（只用于 lookup1_values 的单调比较）。
private func vorbisPowInt(base: Int64, exponent: Int64): Int64 {
    var result: Int64 = 1
    var i: Int64 = 0
    while (i < exponent) {
        if (base != 0 && result > Int64.Max / base) {
            return Int64.Max
        }
        result *= base
        i += 1
    }
    result
}
