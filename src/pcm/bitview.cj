package audio4cj.pcm

/* ============================================================================
 * f32 ↔ 字节的**位视角**转换
 *
 * 职责：在同一条内存的两种视角之间搬运位，**不做任何数值运算**。
 *
 * 【为什么不能用 Float32(x) 之类去"转换"】
 *   那不是重解释，而是**数值转换**（会截断、会舍入）。本项目对纯仓颉实现的判据是
 *   "与参考实现逐位相同"（容差 0）：一旦舍入策略与硬件不一致，结果就会在最低位
 *   出现差异。位视角转换天然一致，没有这个风险。
 *
 * 【为什么这两个函数搬到了本包（原先在 src/drlibs/）】
 *   它们原先在 `src/drlibs/dr_libs_adapter.cj` 中，唯一原因是开发文档 §6.5 的规约：
 *   "库内只有 drlibs 包允许触碰 unsafe"。但它们与 C **毫无关系** ——
 *   纯仓颉 FLAC 内核（`format/flac_bitstream.cj`）只是需要 `f32ToBytes`，
 *   却因此被迫 `import audio4cj.drlibs`，使"删掉 C"这件事被卡住。
 *   故随纯仓颉化把它们搬到中立的 pcm 包。
 *
 *   ⚠ 规约的**实质**（unsafe 只允许出现在一处）随之转移：drlibs 包会随 C 依赖
 *     一起删除，届时本文件是库内**唯一**触碰 unsafe 的地方。业务层与解码内核
 *     仍不得直接接触裸指针 —— 需要位视角转换时，一律调用本文件这两个函数。
 * ========================================================================== */

/// 把 f32 的**字节表示**重解释为 `Array<Float32>`。
///
/// 这不是数值转换（`Float32(someUInt32)` 会做截断改变数值），而是**按位重解释**：
/// 参考实现已把 f32 交错 PCM 写入字节缓冲，此处只是换一个视角读取同一块内存。
///
/// 放在本包而不是各 decoder 内，是为了让业务层（format / codec 其余文件）
/// 不必直接触碰 `unsafe`（开发文档 §6.5 的既定规约）。
///
/// 实现注意：两个 acquire/release 之间**只做裸指针读写**，不构造仓颉对象、
/// 不执行复杂逻辑（配对约束）。
protected func reinterpretF32Bytes(bytes: Array<UInt8>): Array<Float32> {
    let count = bytes.size / 4 // 尾部不足 4 字节的残缺数据被忽略
    let out = Array<Float32>(count, repeat: 0.0)
    if (count <= 0) {
        return out
    }

    unsafe {
        let srcRaw = acquireArrayRawData(bytes)
        let dstRaw = acquireArrayRawData(out)
        let src = CPointer<Float32>(srcRaw.pointer)
        let dst = CPointer<Float32>(dstRaw.pointer)
        for (i in 0..count) {
            dst.write(i, src.read(i))
        }
        releaseArrayRawData(dstRaw)
        releaseArrayRawData(srcRaw)
    }

    out
}

/// 把 f32 数组按**位表示**转成小端字节数组（与 `reinterpretF32Bytes` 互逆）。
///
/// 【为什么必须用位视角转换，而不是按 IEEE-754 手工构造字节】
///   手工拆分符号/阶码/尾数需要自己实现舍入。一旦舍入策略与硬件不一致，
///   结果会出现**最低位不一致** —— 而本项目对纯仓颉实现的判据是
///   "与参考实现逐位相同"，容差为 0。位视角转换天然一致，没有这个风险。
///
/// 【为什么放在本文件】
///   与 `reinterpretF32Bytes` 同理：本包承担库内**唯一**允许触碰 unsafe 的角色
///   （开发文档 §6.5 的规约，随 C 依赖移除而由 drlibs 包转移到本包）。
///   业务层与纯仓颉解码内核都不得直接接触裸指针，这类"同一块内存换视角"的操作
///   统一在此提供。
///
/// 说明：该转换不含数值运算，因此与原数组的字节序一致（本库目标平台均为小端，
/// 与既有 WAV/f32 路径一致）。
protected func f32ToBytes(samples: Array<Float32>): Array<UInt8> {
    let count = samples.size
    let bytesPerSample: Int64 = 4
    let out = Array<UInt8>(count * bytesPerSample, repeat: 0)
    if (count <= 0) {
        return out
    }

    unsafe {
        let srcRaw = acquireArrayRawData(samples)
        let dstRaw = acquireArrayRawData(out)
        let src = CPointer<UInt8>(srcRaw.pointer)
        let dst = CPointer<UInt8>(dstRaw.pointer)
        for (i in 0..count * bytesPerSample) {
            dst.write(i, src.read(i))
        }
        releaseArrayRawData(dstRaw)
        releaseArrayRawData(srcRaw)
    }

    out
}
