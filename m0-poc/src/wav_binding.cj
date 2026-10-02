package m0poc

/* ============================================================================
 * dr_wav FFI 绑定 —— 手写最小绑定（M0 验证用）
 *
 * 来源：third-party/dr_libs/dr_wav.h（版本 0.14.6，commit dfe8377）
 * 依据：开发文档 §12.3「备选方案：手写最小绑定」
 *
 * 【为什么手写而非 cjbind 生成】
 * 实测 cjbind 0.3.1 生成的绑定有语法错误（泛型参数 `<类型名,$4>` 非法、
 * 类型名重复拼接如 drwav_uint8_drwav_uint8），无法通过仓颉编译（13 个错误）。
 *
 * 【为什么只需 2 个函数】
 * 采用 dr_libs 的「堆分配风格」接口 `*_open_file_and_read_pcm_frames_f32`：
 * 它接收文件名、返回堆分配的 f32 交错 PCM 指针，**调用方无需知道 drwav
 * 结构体的内部布局**，因此完全不必镜像那个巨型 `@C struct`。
 *
 * ⚠️【重要架构约束（2026-10-02 实测发现）】
 *   1. `foreign` 函数**不能带访问修饰符**：写 `public foreign func` 会报
 *      "unexpected modifier / conflicted with this"，因为 `public` 与 `foreign` 冲突。
 *      → 因此 foreign 声明的可见性无法提升，**默认的 internal 只对"当前包及子包"可见，
 *        父包看不到子包内的 foreign 函数**。
 *   2. 结论：**跨包使用 foreign 必须经由 public 包装函数**
 *      （这正是 cjbind `--make-func-wrapper` 选项存在的原因 ——
 *        "生成 foreign 函数包装器以允许包外调用"）。
 *   3. 而包装函数是普通仓颉函数，**无法使用 `inout`**（`inout` 仅限 CFunc 调用处），
 *      故包装层需要改用真正分配的内存（如 `LibC.malloc`）传址。
 *   → 正式设计建议：**让 FFI 适配层与绑定声明同包**，由适配层向外暴露
 *     public 的高级 API（见开发文档 §3.2 中 `codec/drlibs_adapter.cj` 与
 *     `codec/dr_libs/` 的分包安排）。
 *
 * ⚠️ 以下签名逐字对照 dr_wav.h 原始声明，未凭记忆编写。
 * ⚠️ 类型宽度按开发文档 §6.5 规约 #3 显式指定：
 *      unsigned int  -> UInt32
 *      drwav_uint64  -> UInt64
 *      float*        -> CPointer<Float32>
 *      void*         -> CPointer<Unit>
 * ========================================================================== */

/* ---------------------------------------------------------------------------
 * dr_wav.h:1311
 * DRWAV_API float* drwav_open_file_and_read_pcm_frames_f32(
 *     const char* filename,
 *     unsigned int* channelsOut,
 *     unsigned int* sampleRateOut,
 *     drwav_uint64* totalFrameCountOut,
 *     const drwav_allocation_callbacks* pAllocationCallbacks);
 *
 * 一次读入整个文件的 PCM（f32 交错，范围 [-1, 1]）；失败返回空指针。
 * pAllocationCallbacks 传空指针（CPointer<Unit>()）表示使用默认分配器，
 * 此时必须用 drwav_free 配对释放。
 * ------------------------------------------------------------------------- */
foreign func drwav_open_file_and_read_pcm_frames_f32(
    filename: CString,
    channelsOut: CPointer<UInt32>,
    sampleRateOut: CPointer<UInt32>,
    totalFrameCountOut: CPointer<UInt64>,
    pAllocationCallbacks: CPointer<Unit>
): CPointer<Float32>

/* ---------------------------------------------------------------------------
 * dr_wav.h:1328
 * DRWAV_API void drwav_free(void* p, const drwav_allocation_callbacks* pAllocationCallbacks);
 * ------------------------------------------------------------------------- */
foreign func drwav_free(
    p: CPointer<Unit>,
    pAllocationCallbacks: CPointer<Unit>
): Unit
