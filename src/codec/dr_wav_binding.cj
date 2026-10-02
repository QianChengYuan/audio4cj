package audio4cj.codec

/* ============================================================================
 * dr_wav FFI 绑定（薄封装版）—— M2
 *
 * 对应 C 侧：third-party/drlibs_wrapper.c 中的 audio4cj_wav_* 系列
 *
 * 【约束一：foreign 函数不能带访问修饰符（2026-10-02 实测）】
 *   `public foreign func` 会报 "unexpected modifier / conflicted with this"，
 *   因为 public 与 foreign 冲突。因此 foreign 声明保持默认 internal
 *   （只对"当前包及子包"可见）。
 *   → 结论：绑定声明必须与其使用者（适配层）**同包**。
 *   故本包同时容纳：FFI 声明 + WavDecoder 适配层。
 *
 * 【约束二：为什么不镜像 drwav 结构体】
 *   流式解码需要 drwav 结构体内存（drwav_init_file 要求调用方提供），
 *   但该结构体极大且字段属实现细节。C 侧薄封装已用
 *   malloc(sizeof(drwav)) 隐藏它，对仓颉只暴露**不透明句柄** CPointer<Unit>，
 *   因此本文件不含任何 @C struct。
 *
 * 【约束三：类型宽度必须显式指定（§6.5 规约 #3）】
 *   drwav_uint16 -> UInt16    drwav_uint32 -> UInt32
 *   drwav_uint64 -> UInt64    float*       -> CPointer<Float32>
 *   void*        -> CPointer<Unit>
 *
 * 【定位说明】
 *   M2 的主解码路径是**纯仓颉** WAV 实现（format/wav.cj + pcm/convert.cj）；
 *   本 FFI 绑定在本阶段主要充当**交叉验证基准**（golden 参照），
 *   同时为 M4 的 FLAC/MP3 压缩格式解码铺路。
 * ========================================================================== */

// ---------------------------------------------------------------------------
// 流式解码（薄封装）
// ---------------------------------------------------------------------------

/// 打开 WAV 并初始化解码器。成功返回不透明句柄，失败返回空指针。
foreign func audio4cj_wav_open(filename: CString): CPointer<Unit>

/// 读取至多 frames 帧的 f32 交错 PCM 到 out，返回实际读取帧数（0 表示流结束）。
foreign func audio4cj_wav_read_f32(
    handle: CPointer<Unit>,
    frames: UInt64,
    out: CPointer<Float32>
): UInt64

/// 采样率（Hz）。
foreign func audio4cj_wav_sample_rate(handle: CPointer<Unit>): UInt32

/// 声道数。
foreign func audio4cj_wav_channels(handle: CPointer<Unit>): UInt16

/// 源位深（16 / 24 / 32）。
foreign func audio4cj_wav_bits_per_sample(handle: CPointer<Unit>): UInt16

/// 总帧数（不可知时为 0）。
foreign func audio4cj_wav_total_frames(handle: CPointer<Unit>): UInt64

/// 关闭并释放解码器与句柄（幂等，接受空指针）。
foreign func audio4cj_wav_close(handle: CPointer<Unit>): Unit

// ---------------------------------------------------------------------------
// 内存释放（「一次读完」API 配套）
// ---------------------------------------------------------------------------

/// 释放 dr_libs 内部分配的内存（须与默认分配器配对）。
foreign func audio4cj_drwav_free(p: CPointer<Unit>): Unit
