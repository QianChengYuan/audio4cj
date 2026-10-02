package audio4cj.drlibs

import audio4cj.core.*

/* ============================================================================
 * dr_libs 适配层 —— 把 FFI 调用收敛为受控的 protected API
 *
 * 职责边界（开发文档 §6.5）：
 *   - 封装 unsafe 上下文，业务层（format / facade）**不直接触碰 unsafe**；
 *   - 管理句柄生命周期（打开失败即抛异常，关闭幂等）；
 *   - 零拷贝读取 PCM（acquireArrayRawData / releaseArrayRawData 严格配对）；
 *   - 把 C 侧的返回值语义翻译为项目契约：
 *       总帧数 0        -> 由调用方按 -1（不可知）处理
 *       读取返回 0 帧   -> 由调用方按「流结束」处理（None，不是错误）
 *
 * 设计要点：
 *   - **不暴露任何 dr_libs 的结构体或类型**，只暴露 Int64 / Array<Float32>，
 *     头文件升级被隔离在 C 封装层内；
 *   - 句柄用不透明指针表示，仓颉侧不关心其内部布局；
 *   - 本类**非线程安全**（与 AudioFile / FrameStream 的既有约定一致），
 *     多线程并行解码须各自持有独立实例。
 * ========================================================================== */

/// dr_libs 当前接入的压缩音频格式。
protected enum DrLibsFormat {
    | Flac
    | Mp3
}

/// dr_libs 解码句柄的受控封装。
protected class DrLibsDecoder {
    private var _handle: CPointer<Unit> = CPointer<Unit>()
    private let _format: DrLibsFormat
    private var _closed: Bool = false

    /// 打开文件并初始化解码器。
    ///
    /// `format` 必须与文件实际格式一致 —— 调用方应先用探测层判定容器，
    /// 不做二次猜测。打开失败（数据损坏 / 编码不受 dr_libs 支持）抛异常。
    protected init(format: DrLibsFormat, path: String) {
        this._format = format

        let kind: Int32 = match (format) {
            case Flac => DR_LIBS_KIND_FLAC
            case Mp3 => DR_LIBS_KIND_MP3
        }

        var h = CPointer<Unit>()
        unsafe {
            // CString 由 LibC 分配，须在用完后立即释放
            let cs = LibC.mallocCString(path)
            h = audio4cj_drlibs_open(kind, cs)
            LibC.free(cs)
        }

        if (h.isNull()) {
            throw CorruptedFileException("dr_libs 无法解析该文件（数据损坏或编码不受支持）：${path}")
        }
        this._handle = h
    }

    // ------------------------------------------------------------------
    // 音频参数
    // ------------------------------------------------------------------

    /// 采样率（Hz）。
    protected func sampleRate(): Int64 {
        checkOpen()
        Int64(unsafe { audio4cj_drlibs_sample_rate(_handle) })
    }

    /// 声道数。
    protected func channels(): Int64 {
        checkOpen()
        Int64(unsafe { audio4cj_drlibs_channels(_handle) })
    }

    /// 源位深：FLAC 为 STREAMINFO 的真实位深；**MP3 恒为 32**（有损格式无源位深）。
    protected func bitsPerSample(): Int64 {
        checkOpen()
        Int64(unsafe { audio4cj_drlibs_bits_per_sample(_handle) })
    }

    /// 总帧数；**返回 0 表示不可知**。调用方应据此上报 `-1`（既有约定）。
    protected func totalFrames(): Int64 {
        checkOpen()
        Int64(unsafe { audio4cj_drlibs_total_frames(_handle) })
    }

    /// 解码器当前所在的 PCM 帧索引。
    protected func currentFrame(): Int64 {
        checkOpen()
        Int64(unsafe { audio4cj_drlibs_current_frame(_handle) })
    }

    // ------------------------------------------------------------------
    // 读取与定位
    // ------------------------------------------------------------------

    /// 定位到指定 PCM 帧索引。返回是否成功。
    ///
    /// dr_libs 内部已实现 FLAC 的 SEEKTABLE 利用与 MP3 的 VBR 处理，
    /// 因此本层直接委托，不自行重写索引逻辑（开发文档 §10 M4 的有意偏离项）。
    protected func seekToFrame(index: Int64): Bool {
        checkOpen()
        if (index < 0) {
            return false
        }
        unsafe { audio4cj_drlibs_seek(_handle, UInt64(index)) == 1 }
    }

    /// 读取至多 `frames` 帧的 f32 交错 PCM。
    ///
    /// 返回的数组长度 = **实际读到的帧数 × 声道数**；空数组表示流已结束。
    /// 读取长度不足时返回短数组（尾部已被裁掉），不会填充零值。
    protected func readF32(frames: Int64): Array<Float32> {
        checkOpen()
        if (frames <= 0) {
            return Array<Float32>()
        }

        let ch = channels()
        if (ch <= 0) {
            return Array<Float32>()
        }

        let capacity = frames * ch
        let buf = Array<Float32>(capacity, repeat: 0.0)

        var got: UInt64 = 0
        unsafe {
            // 零拷贝：把仓颉数组的底层内存直接交给 C 写入。
            // 两个调用之间**不得构造仓颉对象或执行复杂逻辑**（技能明确要求）。
            let raw = acquireArrayRawData(buf)
            got = audio4cj_drlibs_read_f32(_handle, UInt64(frames), raw.pointer)
            releaseArrayRawData(raw)
        }

        let gotSamples = Int64(got) * ch
        if (gotSamples <= 0) {
            return Array<Float32>() // 流结束
        }
        if (gotSamples >= capacity) {
            return buf
        }
        buf[0..gotSamples] // 尾部截断
    }

    /// 读取至多 `frames` 帧的 f32 交错 PCM，**直接写入调用方提供的字节缓冲**
    /// （零拷贝），返回实际读取的帧数（0 表示流结束）。
    ///
    /// 与 `readF32` 的区别：本方法把 `Array<UInt8>` 的底层内存按 `float*`
    /// 交给 C，因而无需中间数组，也不会触发类型转换。供 Reader 直接构造
    /// `Packet` 的字节载荷使用 —— `bytes.size` 须不小于 `frames * 声道数 * 4`。
    protected func readF32Into(bytes: Array<UInt8>, frames: Int64): Int64 {
        checkOpen()
        if (frames <= 0 || bytes.size <= 0) {
            return 0
        }

        var got: UInt64 = 0
        unsafe {
            // 位视角转换：同一块内存，从 UInt8* 变为 Float32*
            let raw = acquireArrayRawData(bytes)
            let f32ptr = CPointer<Float32>(raw.pointer)
            got = audio4cj_drlibs_read_f32(_handle, UInt64(frames), f32ptr)
            releaseArrayRawData(raw)
        }

        Int64(got)
    }

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    /// 释放解码器与句柄（幂等）。
    protected func close(): Unit {
        if (!_closed) {
            _closed = true
            if (_handle.isNotNull()) {
                unsafe { audio4cj_drlibs_close(_handle) }
                _handle = CPointer<Unit>()
            }
        }
    }

    /// 是否已关闭。
    protected func isClosed(): Bool {
        _closed
    }

    /// 当前格式（供调用方判断位深语义等差异）。
    protected func format(): DrLibsFormat {
        _format
    }

    private func checkOpen(): Unit {
        if (_closed) {
            throw ClosedResourceException("对已关闭的 dr_libs 解码句柄执行操作")
        }
    }
}

/// 把 f32 的**字节表示**重解释为 `Array<Float32>`。
///
/// 这不是数值转换（`Float32(someUInt32)` 会做截断改变数值），而是**按位重解释**：
/// dr_libs 已把 f32 交错 PCM 写入字节缓冲，此处只是换一个视角读取同一块内存。
///
/// 放在适配层而不是各 decoder 内，是为了让业务层（format / codec 其余文件）
/// 不必直接触碰 `unsafe`（开发文档 §6.5 的既定规约）。
///
/// 实现注意：两个 acquire/release 之间**只做裸指针读写**，不构造仓颉对象、
/// 不执行复杂逻辑（技能明确要求的配对约束）。
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
