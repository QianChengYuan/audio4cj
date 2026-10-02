package audio4cj.drlibs

/* ============================================================================
 * dr_libs FFI 绑定（FLAC / MP3）—— 手写最小绑定，开发文档 §12.3
 *
 * 来源：third-party/drlibs_wrapper.c 中「统一句柄层」的导出函数，
 *       其 C 侧实现逐字对照 dr_flac.h / dr_mp3.h 的原始声明，未凭记忆编写。
 *
 * 【为什么手写而非 cjbind 生成】
 *   cjbind 在本机不可用：动态链接版要求 libclang 17+，而本机为 LLVM 12，
 *   运行即以 0xC0000139（STATUS_ENTRYPOINT_NOT_FOUND）退出；且 M0 实测
 *   cjbind 0.3.1 生成的绑定本身含语法错误（13 个编译错误）。
 *
 * 【为什么无需镜像任何 @C struct】
 *   C 侧 wrapper 已实现统一句柄层，把 FLAC 与 MP3 的句柄风格差异抹平：
 *     FLAC —— dr_libs 内部堆分配，返回 drflac*
 *     MP3  —— 调用方需自备 drmp3 结构体内存，故 C 侧 malloc 后只暴露 void*
 *   仓颉侧因此只见不透明句柄 CPointer<Unit>，不依赖 dr_libs 的结构体布局，
 *   头文件升级的影响被限制在 C 封装层内。
 *
 * 【可见性约束（M0 实测，不可违背）】
 *   foreign 函数**不能带访问修饰符**（`public foreign func` 报编译错误），
 *   默认 internal 仅对「当前包及子包」可见。因此本文件必须与使用者
 *   dr_libs_adapter.cj 同包（audio4cj.drlibs），对外的包装由适配层完成。
 *
 * 【为什么独立成 drlibs 包，而不是放在 codec 包】
 *   适配层需要同时被两侧使用：format 包的 FlacFormatReader 持有句柄读取数据，
 *   codec 包的 FlacPcmDecoder 做字节到 f32 的视角转换。而 codec 依赖 format
 *   的 Packet —— 若适配层置于任一包内都会形成 codec <-> format 的循环依赖
 *   （实测报错：cyclic dependency）。下沉为各方共同依赖的底层包即打破此环：
 *       drlibs -> core
 *       format -> core / meta / pcm / drlibs
 *       codec  -> core / pcm / format / drlibs
 *
 * 【类型宽度显式映射（开发文档 §6.5 规约 #3）】
 *   C uint64_t      -> UInt64
 *   C uint32_t      -> UInt32
 *   C int           -> Int32
 *   C const char*   -> CString
 *   C float*        -> CPointer<Float32>
 *   C void*         -> CPointer<Unit>
 * ========================================================================== */

/// 格式标识，取值与 C 侧 A4CJ_KIND_FLAC / A4CJ_KIND_MP3 一一对应。
///
/// 改动此处必须同步修改 third-party/drlibs_wrapper.c，否则会静默解错格式。
protected let DR_LIBS_KIND_FLAC: Int32 = 0
protected let DR_LIBS_KIND_MP3: Int32 = 1

/* ---------------------------------------------------------------------------
 * void* audio4cj_drlibs_open(int kind, const char* filename);
 *
 * 打开文件并初始化解码器。成功返回不透明句柄，失败返回空指针。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_open(kind: Int32, filename: CString): CPointer<Unit>

/* ---------------------------------------------------------------------------
 * uint64_t audio4cj_drlibs_read_f32(void* handle, uint64_t frames, float* out);
 *
 * 读取至多 frames **帧**的 f32 交错 PCM 到 out，返回实际读取的帧数
 * （0 表示流结束）。out 的容量须为 frames * 声道数 个 Float32。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_read_f32(
    handle: CPointer<Unit>,
    frames: UInt64,
    out: CPointer<Float32>
): UInt64

/* ---------------------------------------------------------------------------
 * int audio4cj_drlibs_seek(void* handle, uint64_t frameIndex);
 *
 * 定位到指定 PCM 帧索引。返回 1 表示成功、0 表示失败。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_seek(handle: CPointer<Unit>, frameIndex: UInt64): Int32

/* ---------------------------------------------------------------------------
 * uint32_t audio4cj_drlibs_sample_rate(void* handle);
 * 采样率（Hz）；句柄为空时返回 0。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_sample_rate(handle: CPointer<Unit>): UInt32

/* ---------------------------------------------------------------------------
 * uint32_t audio4cj_drlibs_channels(void* handle);
 * 声道数；句柄为空时返回 0。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_channels(handle: CPointer<Unit>): UInt32

/* ---------------------------------------------------------------------------
 * uint32_t audio4cj_drlibs_bits_per_sample(void* handle);
 *
 * 源位深。FLAC 返回 STREAMINFO 中的真实位深；**MP3 恒返回 32** ——
 * MP3 为有损格式、无源位深，输出为 f32，故按「32 代表 float32」约定报告。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_bits_per_sample(handle: CPointer<Unit>): UInt32

/* ---------------------------------------------------------------------------
 * uint64_t audio4cj_drlibs_total_frames(void* handle);
 *
 * 总帧数；**0 表示不可知**（C 侧已归一化两个库不同的「未知」表示法：
 * FLAC 用 0，MP3 用 DRMP3_UINT64_MAX）。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_total_frames(handle: CPointer<Unit>): UInt64

/* ---------------------------------------------------------------------------
 * uint64_t audio4cj_drlibs_current_frame(void* handle);
 * 解码器当前所在的 PCM 帧索引（seek 后用于回推实际落点）。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_current_frame(handle: CPointer<Unit>): UInt64

/* ---------------------------------------------------------------------------
 * void audio4cj_drlibs_close(void* handle);
 * 释放解码器与句柄（幂等，接受空指针）。
 * ------------------------------------------------------------------------- */
foreign func audio4cj_drlibs_close(handle: CPointer<Unit>): Unit
