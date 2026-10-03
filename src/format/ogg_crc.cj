package audio4cj.format

import audio4cj.core.CorruptedFileException

/* ============================================================================
 * Ogg 页 CRC-32（纯仓颉）
 *
 * 【规范参数】与 flac_crc.cj 的两个 CRC 一样是 MSB-first、输入输出均不反转，
 * 但四项参数都不一样：
 *   多项式    0x04C11DB7（x^32+x^26+x^23+x^22+x^16+x^12+x^11+x^10+x^8
 *                          +x^7+x^5+x^4+x^2+x+1）
 *   初值      0     ← **不是** 0xFFFFFFFF
 *   最终异或  无    ← **不是** 0xFFFFFFFF
 *   覆盖范围  整页（页头 + 段表 + 页体），但**先把 CRC 字段自身置零**再算
 *
 * 【为什么必须逐条钉住这四个参数，而不是"用常见 CRC-32 就行"】
 *   "CRC-32" 这个名字下至少有三套互不兼容的参数：以太网/ZIP/PNG 版（反转
 *   输入输出）、MPEG-2 版（初值 0xFFFFFFFF）、以及 Ogg 这一版。用错的后果
 *   **不是报错而是全部判损** —— 算出来的值与文件里存的永远对不上，表现为
 *   "每个页面都 CRC 不匹配"，看着像文件坏了，其实是校验器错了。
 *   故参数写在代码上方，并由 ogg_crc_test.cj 用**真实素材**反证：
 *   8 个素材、30 个页面的存储值与重算值全部一致；标准串 "123456789"
 *   算得 0x89A1897F（与真实素材互证，不是抄来的数字）。
 *
 * 【为什么累加器用 UInt64 而不是 UInt32】
 *   CRC-32 的中途值天生占满 32 位，左移必然"移出"高位。用 UInt32 承载就得
 *   依赖"移位不抛溢出"这一条语义；用 UInt64 承载则连这个问题都不存在
 *   （32 位值左移 8 位后仍远小于 2^64），收尾时一次掩码即可。
 *   这与 flac_crc.cj "内部用宽类型承载、返回处收窄" 的做法同源 ——
 *   那边用 UInt32 承载 16 位 CRC，理由是同一个。
 * ========================================================================== */

/// 多项式（MSB-first 口径）。
private let OGG_CRC32_POLY: UInt64 = 0x04C11DB7

/// CRC-32 查表（多项式 0x04C11DB7，初值 0）。
private let OGG_CRC32_TABLE: Array<UInt32> = buildOggCrc32Table()

/// 按多项式生成查表 —— 与 flac_crc.cj 同样的理由：多项式就写在代码里，
/// 不存在"改了多项式忘了改那张 256 项的数字墙"的可能。
private func buildOggCrc32Table(): Array<UInt32> {
    let table = Array<UInt32>(256, repeat: 0)
    for (i in 0..256) {
        var crc: UInt64 = UInt64(i) << 24
        var bit: Int64 = 0
        while (bit < 8) {
            if ((crc & 0x80000000) != 0) {
                crc = ((crc << 1) ^ OGG_CRC32_POLY) & 0xFFFFFFFF
            } else {
                crc = (crc << 1) & 0xFFFFFFFF
            }
            bit += 1
        }
        table[i] = UInt32(crc)
    }
    table
}

/// 计算 `[from, until)` 区间字节的 Ogg 页 CRC-32。区间语义为左闭右开，
/// 与仓颉切片一致（也与 flac_crc.cj 的两个 crc 函数一致）。
///
/// 【调用方必须先把自己的 CRC 字段置零】这一步很容易漏：CRC 字段就在页头
/// 第 22..25 字节，而校验覆盖整页。故在调用点与本注释各写一次，
/// 且由真实素材的测试兜底 —— 若忘了置零，所有页面都会报不匹配。
protected func crc32Ogg(bytes: Array<UInt8>, from: Int64, until: Int64): UInt32 {
    if (from < 0 || until < from || until > bytes.size) {
        throw CorruptedFileException("Ogg 页 CRC 的计算区间非法：[${from}, ${until})（缓冲 ${bytes.size} 字节）")
    }

    var crc: UInt64 = 0
    var i = from
    while (i < until) {
        let idx = Int64(((crc >> 24) ^ UInt64(bytes[i])) & 0xFF)
        crc = ((crc << 8) ^ UInt64(OGG_CRC32_TABLE[idx])) & 0xFFFFFFFF
        i += 1
    }
    UInt32(crc)
}
