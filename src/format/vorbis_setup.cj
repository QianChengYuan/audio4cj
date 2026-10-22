package audio4cj.format

import audio4cj.core.CorruptedFileException
import audio4cj.core.FormatNotSupportedException
import std.collection.ArrayList

/* ============================================================================
 * Vorbis 头解析 —— identification / comment / setup
 *
 * 【三个头包的职责】
 *   1. identification：声道数、采样率、两块大小、码率（本实现只用前四项）。
 *   2. comment：Vorbis comment 标签。标签读取由 meta 层负责，本类只做
 *      结构校验（避免把音频包误当注释包）。
 *   3. setup：码本、floor、residue、mapping、mode —— 解码器的"字典"。
 *      这是本文件的主体，字段顺序严格按 Vorbis I 规范 §3.2.1。
 *
 * 【floor 0】本实现与 stb_vorbis 一样暂不支持 floor 0，遇到时抛
 *   FormatNotSupportedException。现有测试素材均为 floor 1；这一限制在
 *   README 的支持矩阵中如实标注，不静默解出错误音频。
 *
 * 【为什么所有索引都做上界校验】
 *   setup 头里的码本/floor/residue 索引是解码期数组下标。损坏文件若给出
 *   越界值，不校验会变成越界访问（仓颉数组越界抛异常，但错误信息会指向
 *   无关位置）。这里在解析期就把"坏头"与"坏音频包"分开报错。
 * ========================================================================== */

/// Vorbis floor 1 配置。
protected class VorbisFloor1 {
    protected var partitions: Int64 = 0
    protected var partitionClasses: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var classDimensions: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var classSubclasses: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var classMasterbooks: Array<Int64> = Array<Int64>(0, repeat: -1)
    protected var subclassBooks: Array<Array<Int64>> = Array<Array<Int64>>(0, repeat: Array<Int64>(0, repeat: -1))
    protected var multiplier: Int64 = 1
    protected var rangeBits: Int64 = 0
    protected var xList: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var values: Int64 = 0
    protected var sortedOrder: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var neighborLow: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var neighborHigh: Array<Int64> = Array<Int64>(0, repeat: 1)
}

/// Vorbis residue 配置（type 0/1/2 共用）。
protected class VorbisResidue {
    protected var residueType: Int64 = 0
    protected var begin: Int64 = 0
    protected var end: Int64 = 0
    protected var partitionSize: Int64 = 1
    protected var classifications: Int64 = 1
    protected var classbookIndex: Int64 = 0
    protected var classwords: Int64 = 0
    /// 每个 classbook 符号对应的分类字序列（classifications 进制）。
    protected var classdata: Array<Array<Int64>> = Array<Array<Int64>>(0, repeat: Array<Int64>(0, repeat: 0))
    /// 每个分类 8 个码本索引；-1 表示该子带没有码本。
    protected var books: Array<Array<Int64>> = Array<Array<Int64>>(0, repeat: Array<Int64>(0, repeat: -1))
}

/// Vorbis mapping 配置。
protected class VorbisMapping {
    protected var submaps: Int64 = 1
    protected var couplingSteps: Int64 = 0
    protected var couplingMag: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var couplingAngle: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var mux: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var submapFloor: Array<Int64> = Array<Int64>(0, repeat: 0)
    protected var submapResidue: Array<Int64> = Array<Int64>(0, repeat: 0)
}

/// Vorbis mode 配置。
protected class VorbisMode {
    protected var blockFlag: Bool = false
    protected var mapping: Int64 = 0
}

/// Vorbis setup 解析结果。
protected class VorbisSetup {
    protected var sampleRate: Int64 = 0
    protected var channels: Int64 = 0
    protected var blocksize0: Int64 = 0
    protected var blocksize1: Int64 = 0
    protected var codebooks: Array<VorbisCodebook> = Array<VorbisCodebook>(0, repeat: VorbisCodebook())
    protected var floors: Array<VorbisFloor1> = Array<VorbisFloor1>(0, repeat: VorbisFloor1())
    protected var residues: Array<VorbisResidue> = Array<VorbisResidue>(0, repeat: VorbisResidue())
    protected var mappings: Array<VorbisMapping> = Array<VorbisMapping>(0, repeat: VorbisMapping())
    protected var modes: Array<VorbisMode> = Array<VorbisMode>(0, repeat: VorbisMode())

    /// 解析 identification 与 setup 两个包。comment 包由调用方校验后跳过。
    protected static func parse(identification: Array<UInt8>, setup: Array<UInt8>): VorbisSetup {
        let result = VorbisSetup()

        if (identification.size < 30) {
            throw CorruptedFileException("Vorbis identification 头长度不足：${identification.size}")
        }
        if (identification[0] != 0x01) {
            throw CorruptedFileException("Vorbis identification 包类型不是 1")
        }
        checkVorbisMagic(identification, "identification")

        let idBits = VorbisBitReader(identification[7..identification.size])
        if (idBits.getBits(32) != 0) {
            throw CorruptedFileException("Vorbis 版本号不是 0")
        }
        result.channels = idBits.getBits(8)
        if (result.channels <= 0 || result.channels > 255) {
            throw CorruptedFileException("Vorbis 声道数非法：${result.channels}")
        }
        result.sampleRate = idBits.getBits(32)
        if (result.sampleRate <= 0) {
            throw CorruptedFileException("Vorbis 采样率非法：${result.sampleRate}")
        }
        idBits.getBits(32) // bitrate_maximum
        idBits.getBits(32) // bitrate_nominal
        idBits.getBits(32) // bitrate_minimum
        let blockByte = idBits.getBits(8)
        let log0 = blockByte & 15
        let log1 = (blockByte >> 4) & 15
        if (log0 < 6 || log0 > 13 || log1 < 6 || log1 > 13 || log0 > log1) {
            throw CorruptedFileException("Vorbis 块大小非法：log0=${log0}, log1=${log1}")
        }
        result.blocksize0 = Int64(1) << log0
        result.blocksize1 = Int64(1) << log1
        if (idBits.getBits(1) != 1) {
            throw CorruptedFileException("Vorbis identification 头 framing 位不是 1")
        }

        if (setup.size < 7) {
            throw CorruptedFileException("Vorbis setup 头长度不足：${setup.size}")
        }
        if (setup[0] != 0x05) {
            throw CorruptedFileException("Vorbis setup 包类型不是 5")
        }
        checkVorbisMagic(setup, "setup")

        let br = VorbisBitReader(setup[7..setup.size])

        // ---- 码本 ----
        let codebookCount = br.getBits(8) + 1
        let parsedCodebooks = ArrayList<VorbisCodebook>()
        var i: Int64 = 0
        while (i < codebookCount) {
            parsedCodebooks.add(VorbisCodebook.parse(br))
            i += 1
        }
        result.codebooks = parsedCodebooks.toArray()

        // ---- time domain（规范保留，必须为 0）----
        let timeCount = br.getBits(6) + 1
        i = 0
        while (i < timeCount) {
            if (br.getBits(16) != 0) {
                throw CorruptedFileException("Vorbis time domain 变换类型不是 0")
            }
            i += 1
        }

        // ---- floor ----
        let floorCount = br.getBits(6) + 1
        let parsedFloors = ArrayList<VorbisFloor1>()
        i = 0
        while (i < floorCount) {
            let floorType = br.getBits(16)
            if (floorType == 0) {
                throw FormatNotSupportedException("Vorbis floor 0 暂不支持（本库当前实现 floor 1）")
            }
            if (floorType != 1) {
                throw CorruptedFileException("Vorbis floor 类型非法：${floorType}")
            }
            parsedFloors.add(parseFloor1(br, codebookCount))
            i += 1
        }
        result.floors = parsedFloors.toArray()

        // ---- residue ----
        let residueCount = br.getBits(6) + 1
        let parsedResidues = ArrayList<VorbisResidue>()
        i = 0
        while (i < residueCount) {
            parsedResidues.add(parseResidue(br, result.codebooks))
            i += 1
        }
        result.residues = parsedResidues.toArray()

        // ---- mapping ----
        let mappingCount = br.getBits(6) + 1
        let parsedMappings = ArrayList<VorbisMapping>()
        i = 0
        while (i < mappingCount) {
            parsedMappings.add(parseMapping(br, result.channels, floorCount, residueCount))
            i += 1
        }
        result.mappings = parsedMappings.toArray()

        // ---- mode ----
        let modeCount = br.getBits(6) + 1
        let parsedModes = ArrayList<VorbisMode>()
        i = 0
        while (i < modeCount) {
            let mode = VorbisMode()
            mode.blockFlag = br.getBits(1) != 0
            if (br.getBits(16) != 0) {
                throw CorruptedFileException("Vorbis mode window type 不是 0")
            }
            if (br.getBits(16) != 0) {
                throw CorruptedFileException("Vorbis mode transform type 不是 0")
            }
            mode.mapping = br.getBits(8)
            if (mode.mapping >= mappingCount) {
                throw CorruptedFileException("Vorbis mode mapping 索引越界：${mode.mapping}")
            }
            parsedModes.add(mode)
            i += 1
        }
        result.modes = parsedModes.toArray()

        if (br.getBits(1) != 1) {
            throw CorruptedFileException("Vorbis setup 头 framing 位不是 1")
        }
        if (br.isEop()) {
            throw CorruptedFileException("Vorbis setup 头在 framing 位之前结束")
        }

        result
    }

    /// 校验 comment 包的基本结构（标签内容由 meta 层解析）。
    protected static func validateComment(comment: Array<UInt8>): Unit {
        if (comment.size < 7 || comment[0] != 0x03) {
            throw CorruptedFileException("Vorbis comment 包头非法")
        }
        checkVorbisMagic(comment, "comment")
        let br = VorbisBitReader(comment[7..comment.size])
        let vendorLength = br.getBits(32)
        if (vendorLength < 0 || vendorLength > comment.size) {
            throw CorruptedFileException("Vorbis comment vendor 长度非法：${vendorLength}")
        }
        br.skipBits(vendorLength * 8)
        let commentCount = br.getBits(32)
        if (commentCount < 0 || commentCount > 1000000) {
            throw CorruptedFileException("Vorbis comment 条目数非法：${commentCount}")
        }
        var i: Int64 = 0
        while (i < commentCount) {
            let length = br.getBits(32)
            if (length < 0) {
                throw CorruptedFileException("Vorbis comment 条目长度非法")
            }
            br.skipBits(length * 8)
            i += 1
        }
        if (br.isEop()) {
            throw CorruptedFileException("Vorbis comment 包被截断")
        }
    }
}

/// 校验包头的 "vorbis" 魔数（位于偏移 1..6）。
private func checkVorbisMagic(bytes: Array<UInt8>, what: String): Unit {
    if (bytes.size < 7) {
        throw CorruptedFileException("Vorbis ${what} 头长度不足")
    }
    let magic = [UInt8(0x76), UInt8(0x6F), UInt8(0x72), UInt8(0x62), UInt8(0x69), UInt8(0x73)]
    var i: Int64 = 0
    while (i < 6) {
        if (bytes[1 + i] != magic[i]) {
            throw CorruptedFileException("Vorbis ${what} 头魔数不是 \"vorbis\"")
        }
        i += 1
    }
}

/// 解析一个 floor 1 配置。
private func parseFloor1(br: VorbisBitReader, codebookCount: Int64): VorbisFloor1 {
    let floor = VorbisFloor1()
    floor.partitions = br.getBits(5)

    let partitionClasses = Array<Int64>(floor.partitions, repeat: 0)
    var maxClass: Int64 = -1
    var i: Int64 = 0
    while (i < floor.partitions) {
        let cls = br.getBits(4)
        partitionClasses[i] = cls
        if (cls > maxClass) {
            maxClass = cls
        }
        i += 1
    }
    floor.partitionClasses = partitionClasses

    floor.classDimensions = Array<Int64>(maxClass + 1, repeat: 0)
    floor.classSubclasses = Array<Int64>(maxClass + 1, repeat: 0)
    floor.classMasterbooks = Array<Int64>(maxClass + 1, repeat: -1)
    let subclassBooks = ArrayList<Array<Int64>>()
    i = 0
    while (i <= maxClass) {
        floor.classDimensions[i] = br.getBits(3) + 1
        let subclasses = br.getBits(2)
        floor.classSubclasses[i] = subclasses
        if (subclasses > 0) {
            let master = br.getBits(8)
            if (master >= codebookCount) {
                throw CorruptedFileException("Vorbis floor1 masterbook 越界：${master}")
            }
            floor.classMasterbooks[i] = master
        }
        let books = Array<Int64>(Int64(1) << subclasses, repeat: -1)
        var k: Int64 = 0
        while (k < books.size) {
            let book = br.getBits(8) - 1
            if (book >= codebookCount) {
                throw CorruptedFileException("Vorbis floor1 subclass book 越界：${book}")
            }
            books[k] = book
            k += 1
        }
        subclassBooks.add(books)
        i += 1
    }
    floor.subclassBooks = subclassBooks.toArray()

    floor.multiplier = br.getBits(2) + 1
    floor.rangeBits = br.getBits(4)

    let xList = ArrayList<Int64>()
    xList.add(0)
    xList.add(Int64(1) << floor.rangeBits)
    i = 0
    while (i < floor.partitions) {
        let cls = floor.partitionClasses[i]
        let dim = floor.classDimensions[cls]
        var k: Int64 = 0
        while (k < dim) {
            xList.add(br.getBits(floor.rangeBits))
            k += 1
        }
        i += 1
    }
    floor.xList = xList.toArray()
    floor.values = floor.xList.size
    if (floor.values > 31 * 8 + 2) {
        throw CorruptedFileException("Vorbis floor1 Xlist 条目过多：${floor.values}")
    }

    // 按 X 升序排序；重复 X 视为损坏（与 stb 一致）。
    let order = Array<Int64>(floor.values, repeat: 0)
    i = 0
    while (i < floor.values) {
        order[i] = i
        i += 1
    }
    i = 1
    while (i < floor.values) {
        let key = order[i]
        let keyX = floor.xList[key]
        var j = i - 1
        while (j >= 0) {
            let prevX = floor.xList[order[j]]
            if (prevX <= keyX) {
                break
            }
            order[j + 1] = order[j]
            j -= 1
        }
        order[j + 1] = key
        i += 1
    }
    i = 0
    while (i + 1 < floor.values) {
        if (floor.xList[order[i]] == floor.xList[order[i + 1]]) {
            throw CorruptedFileException("Vorbis floor1 Xlist 存在重复 X 值")
        }
        i += 1
    }
    floor.sortedOrder = order

    floor.neighborLow = Array<Int64>(floor.values, repeat: 0)
    floor.neighborHigh = Array<Int64>(floor.values, repeat: 1)
    i = 2
    while (i < floor.values) {
        var low: Int64 = -1
        var high: Int64 = 65536
        var lowIndex: Int64 = 0
        var highIndex: Int64 = 0
        var j: Int64 = 0
        while (j < i) {
            let x = floor.xList[j]
            if (x > low && x < floor.xList[i]) {
                low = x
                lowIndex = j
            }
            if (x < high && x > floor.xList[i]) {
                high = x
                highIndex = j
            }
            j += 1
        }
        floor.neighborLow[i] = lowIndex
        floor.neighborHigh[i] = highIndex
        i += 1
    }

    floor
}

/// 解析一个 residue 配置。
private func parseResidue(br: VorbisBitReader, codebooks: Array<VorbisCodebook>): VorbisResidue {
    let residue = VorbisResidue()
    residue.residueType = br.getBits(16)
    if (residue.residueType < 0 || residue.residueType > 2) {
        throw CorruptedFileException("Vorbis residue 类型非法：${residue.residueType}")
    }
    residue.begin = br.getBits(24)
    residue.end = br.getBits(24)
    if (residue.end < residue.begin) {
        throw CorruptedFileException("Vorbis residue end < begin")
    }
    residue.partitionSize = br.getBits(24) + 1
    residue.classifications = br.getBits(6) + 1
    residue.classbookIndex = br.getBits(8)
    if (residue.classbookIndex >= codebooks.size) {
        throw CorruptedFileException("Vorbis residue classbook 越界：${residue.classbookIndex}")
    }

    let cascades = Array<Int64>(residue.classifications, repeat: 0)
    var i: Int64 = 0
    while (i < residue.classifications) {
        let low = br.getBits(3)
        var high: Int64 = 0
        if (br.getBits(1) != 0) {
            high = br.getBits(5)
        }
        cascades[i] = high * 8 + low
        i += 1
    }

    let books = ArrayList<Array<Int64>>()
    i = 0
    while (i < residue.classifications) {
        let row = Array<Int64>(8, repeat: -1)
        var k: Int64 = 0
        while (k < 8) {
            if ((cascades[i] & (Int64(1) << k)) != 0) {
                let book = br.getBits(8)
                if (book >= codebooks.size) {
                    throw CorruptedFileException("Vorbis residue book 越界：${book}")
                }
                row[k] = book
            }
            k += 1
        }
        books.add(row)
        i += 1
    }
    residue.books = books.toArray()

    let classbook = codebooks[residue.classbookIndex]
    residue.classwords = classbook.dimensions
    if (residue.classwords <= 0) {
        throw CorruptedFileException("Vorbis residue classbook 维度为 0")
    }
    let classdata = ArrayList<Array<Int64>>()
    var j: Int64 = 0
    while (j < classbook.entries) {
        let row = Array<Int64>(residue.classwords, repeat: 0)
        var temp = j
        var k = residue.classwords - 1
        while (k >= 0) {
            row[k] = temp % residue.classifications
            temp /= residue.classifications
            k -= 1
        }
        classdata.add(row)
        j += 1
    }
    residue.classdata = classdata.toArray()

    residue
}

/// 解析一个 mapping 配置。
private func parseMapping(
    br: VorbisBitReader,
    channels: Int64,
    floorCount: Int64,
    residueCount: Int64
): VorbisMapping {
    let mapping = VorbisMapping()
    if (br.getBits(16) != 0) {
        throw CorruptedFileException("Vorbis mapping type 不是 0")
    }
    if (br.getBits(1) != 0) {
        mapping.submaps = br.getBits(4) + 1
    } else {
        mapping.submaps = 1
    }
    if (mapping.submaps <= 0 || mapping.submaps > 16) {
        throw CorruptedFileException("Vorbis submaps 数量非法：${mapping.submaps}")
    }

    if (br.getBits(1) != 0) {
        mapping.couplingSteps = br.getBits(8) + 1
        if (mapping.couplingSteps > channels) {
            throw CorruptedFileException("Vorbis coupling steps 超过声道数")
        }
        mapping.couplingMag = Array<Int64>(mapping.couplingSteps, repeat: 0)
        mapping.couplingAngle = Array<Int64>(mapping.couplingSteps, repeat: 0)
        let bits = vorbisIlog(channels - 1)
        var i: Int64 = 0
        while (i < mapping.couplingSteps) {
            let mag = br.getBits(bits)
            let angle = br.getBits(bits)
            if (mag >= channels || angle >= channels || mag == angle) {
                throw CorruptedFileException("Vorbis coupling 声道索引非法")
            }
            mapping.couplingMag[i] = mag
            mapping.couplingAngle[i] = angle
            i += 1
        }
    }

    if (br.getBits(2) != 0) {
        throw CorruptedFileException("Vorbis mapping 保留位不是 0")
    }

    mapping.mux = Array<Int64>(channels, repeat: 0)
    if (mapping.submaps > 1) {
        var i: Int64 = 0
        while (i < channels) {
            let mux = br.getBits(4)
            if (mux >= mapping.submaps) {
                throw CorruptedFileException("Vorbis mapping mux 越界：${mux}")
            }
            mapping.mux[i] = mux
            i += 1
        }
    }

    mapping.submapFloor = Array<Int64>(mapping.submaps, repeat: 0)
    mapping.submapResidue = Array<Int64>(mapping.submaps, repeat: 0)
    var i: Int64 = 0
    while (i < mapping.submaps) {
        br.getBits(8) // reserved
        let floor = br.getBits(8)
        let residue = br.getBits(8)
        if (floor >= floorCount) {
            throw CorruptedFileException("Vorbis submap floor 越界：${floor}")
        }
        if (residue >= residueCount) {
            throw CorruptedFileException("Vorbis submap residue 越界：${residue}")
        }
        mapping.submapFloor[i] = floor
        mapping.submapResidue[i] = residue
        i += 1
    }

    mapping
}
