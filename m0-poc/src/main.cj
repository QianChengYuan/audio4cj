package m0poc

/* ============================================================================
 * M0 可行性验证 —— dr_wav FFI 端到端链路
 *
 * 验证目标（对应开发文档 §12.1）：
 *   A3 — clang 编译 dr_libs wrapper 产出 C 动态库
 *   A4 — Windows 动态库 lib 前缀双副本方案
 *   A6 — 端到端解码一个 WAV，样本值与预期一致
 *
 * ⚠️ 这是验证代码，非最终 API 设计。
 *    正式实现见开发文档 §4（接口契约：流式 FrameStream + 异常体系 + Resource）。
 * ========================================================================== */
main(): Int64 {
    let path = "m0_test.wav"
    println("=== M0 POC: dr_wav FFI 端到端验证 ===")
    println("输入文件: ${path}")

    // 1) 仓颉 String -> C 字符串
    let csPath = unsafe { LibC.mallocCString(path) }

    // 2) 一次性读入 f32 交错 PCM（dr_libs 内部堆分配）
    //    用 inout 将局部变量地址作为出参传给 C 侧
    var channels: UInt32 = 0
    var sampleRate: UInt32 = 0
    var totalFrames: UInt64 = 0
    let pcm = unsafe {
        drwav_open_file_and_read_pcm_frames_f32(
            csPath,
            inout channels,
            inout sampleRate,
            inout totalFrames,
            CPointer<Unit>() // 空指针 = 使用默认分配器
        )
    }
    unsafe { LibC.free(csPath) }

    // 3) 失败判定：dr_libs 约定返回空指针
    if (pcm.isNull()) {
        eprintln("解码失败：返回空指针（文件不存在或格式不支持）")
        return 1
    }

    // 4) 解码元信息
    println("声道数   : ${channels}")
    println("采样率   : ${sampleRate}")
    println("总帧数   : ${totalFrames}")

    // 5) 抽查前 5 个样本（f32 交错，范围 [-1, 1]）
    print("前 5 个样本: ")
    for (i in 0..5) {
        let v = unsafe { pcm.read(i) }
        print("${v} ")
    }
    println()

    // 6) 释放 C 侧内存（默认分配器必须用 drwav_free 配对释放）
    unsafe { drwav_free(CPointer<Unit>(pcm), CPointer<Unit>()) }
    println("资源已释放 —— M0 链路打通")
    return 0
}
