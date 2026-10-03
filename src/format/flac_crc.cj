package audio4cj.format

import audio4cj.core.CorruptedFileException

/* ============================================================================
 * FLAC 的 CRC-8 与 CRC-16（纯仓颉）
 *
 * 【规范定义】两个 CRC 都是 **MSB-first、输入输出均不反转、初值 0**：
 *   帧头 CRC-8 ：多项式 x^8+x^2+x^1+1（0x07）
 *                覆盖范围 = 帧起点 → CRC 字节**之前**的全部字节
 *   帧尾 CRC-16：多项式 x^16+x^15+x^2+1（0x8005）
 *                覆盖范围 = 帧起点 → CRC 两字节**之前**的全部字节
 *                （注意：其中**已包含**帧头那一个 CRC-8 字节）
 *
 * 【为什么要有它】
 *   参考实现（dr_libs）会校验这两个 CRC，而纯仓颉内核此前只把 CRC 读掉不校验
 *   （见 flac_frame.cj 的历史注释）。补齐它是为了让替换内核后**检测能力不下降**：
 *   损坏的文件必须在解码阶段被明确拒绝，而不是产出听起来"差不多"的样本。
 *
 * 【校验放在流式层，不放在本文件也不放在帧解码器里】
 *   重算 CRC 需要**原始字节**，而帧解码器只持有位读取器。
 *   流式内核（flac_bitstream.cj）才有完整的帧字节窗口 —— 见那里的调用点。
 *   本文件只提供"给定字节区间，算出 CRC"这一原语。
 *
 * 【为什么用查表法而不是逐位循环】
 *   CRC-16 要覆盖整帧（每帧可达数 KB），且这是解码主路径上的逐帧工作；
 *   逐位循环是 8 倍开销。查表把内层压成一次移位加一次异或。
 *   两张表在模块初始化时**按多项式生成**，而不是硬编码 256 项数字墙 ——
 *   多项式就写在代码里，不存在"改了多项式忘了改表"的可能。
 *
 * 【为什么内部一律用 UInt32 累加】
 *   仓颉的整数运算**默认带溢出检查**（溢出抛异常而非回绕）。CRC 的中途值
 *   天然会超出 UInt8/UInt16 的范围，若就地用窄类型会频繁抛 OverflowException。
 *   故内部统一用 UInt32 承载，再在返回处收窄 —— 与 flac_bits.cj 用 Int64
 *   承载位字段是同一个理由。
 * ========================================================================== */

/// CRC-8 查表（多项式 0x07，MSB-first）。
private let CRC8_TABLE: Array<UInt8> = buildCrc8Table()

/// CRC-16 查表（多项式 0x8005，MSB-first）。
private let CRC16_TABLE: Array<UInt16> = buildCrc16Table()

private func buildCrc8Table(): Array<UInt8> {
    let table = Array<UInt8>(256, repeat: 0)
    for (i in 0..256) {
        // 【必须按 8 位口径生成，不能照搬 CRC-16 的写法】
        //   CRC-16 的表是"值放高字节、判 0x8000、掩 0xFFFF"，那是 16 位寄存器的
        //   自然写法；但它**不能**平移到 8 位 —— 判定位会错位（该看 0x80 却看
        //   0x8000），多项式套用的时机随之全错。
        //   实测代价：这样写出来的表对 "123456789" 算不出 0xF4，而 CRC-16 侧
        //   却完全正常 —— 单看哪一边都"像是对的"，只有标准校验值能戳穿。
        var crc: UInt32 = UInt32(i)
        var bit: Int64 = 0
        while (bit < 8) {
            if ((crc & 0x80) != 0) {
                crc = ((crc << 1) ^ 0x07) & 0xFF
            } else {
                crc = (crc << 1) & 0xFF
            }
            bit += 1
        }
        table[i] = UInt8(crc & 0xFF)
    }
    table
}

private func buildCrc16Table(): Array<UInt16> {
    let table = Array<UInt16>(256, repeat: 0)
    for (i in 0..256) {
        var crc: UInt32 = UInt32(i) << 8
        var bit: Int64 = 0
        while (bit < 8) {
            if ((crc & 0x8000) != 0) {
                crc = ((crc << 1) ^ 0x8005) & 0xFFFF
            } else {
                crc = (crc << 1) & 0xFFFF
            }
            bit += 1
        }
        table[i] = UInt16(crc & 0xFFFF)
    }
    table
}

/// 校验区间合法性：越界一律抛异常（§4.1 铁律：不用返回值表达错误）。
///
/// 区间语义是**左闭右开** `[from, until)`，与仓颉切片一致。
private func checkRange(bytes: Array<UInt8>, from: Int64, until: Int64, what: String): Unit {
    if (from < 0 || until < from || until > bytes.size) {
        throw CorruptedFileException("${what} 的 CRC 计算区间非法：[$from, $until)（缓冲 ${bytes.size} 字节）")
    }
}

/// 计算 `[from, until)` 区间内字节的 CRC-8（多项式 0x07）。
protected func crc8Of(bytes: Array<UInt8>, from: Int64, until: Int64): UInt8 {
    checkRange(bytes, from, until, "CRC-8")
    var crc: UInt32 = 0
    var i = from
    while (i < until) {
        let idx = Int64((crc ^ UInt32(bytes[i])) & 0xFF)
        crc = UInt32(CRC8_TABLE[idx])
        i += 1
    }
    UInt8(crc)
}

/// 计算 `[from, until)` 区间内字节的 CRC-16（多项式 0x8005）。
protected func crc16Of(bytes: Array<UInt8>, from: Int64, until: Int64): UInt16 {
    checkRange(bytes, from, until, "CRC-16")
    var crc: UInt32 = 0
    var i = from
    while (i < until) {
        let idx = Int64(((crc >> 8) ^ UInt32(bytes[i])) & 0xFF)
        crc = ((crc << 8) & 0xFFFF) ^ UInt32(CRC16_TABLE[idx])
        i += 1
    }
    UInt16(crc & 0xFFFF)
}
