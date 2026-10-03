/* ============================================================================
 * drlibs_wrapper.c —— dr_libs 实现侧 + 薄封装适配层
 *
 * 【为什么需要这个文件】
 * dr_libs 是「单头文件库」(header-only)：头文件里只有声明，实现代码被包在
 * `#ifdef DR_XXX_IMPLEMENTATION` 之内。因此必须在一个（且仅一个）翻译单元中
 * 先定义 DR_XXX_IMPLEMENTATION 再 #include 头文件，才会产出真正的实现符号。
 *
 * ---------------------------------------------------------------------------
 * 【关键：DRWAV_DLL 必须定义（2026-10-02 实测踩坑）】
 *
 * dr_wav.h 内部逻辑（约 L192-L216）：
 *
 *     #if defined(DRWAV_DLL)
 *         #if defined(_WIN32)
 *             #define DRWAV_DLL_EXPORT  __declspec(dllexport)
 *         #else
 *             #define DRWAV_DLL_EXPORT  __attribute__((visibility("default")))
 *         #endif
 *     #else
 *         #define DRWAV_DLL_EXPORT          // 空！
 *     #endif
 *
 * 若不定义 DRWAV_DLL，编译出的 Windows DLL 不导出任何符号，链接时报：
 *     ld.lld: error: undefined symbol: drwav_open_file_and_read_pcm_frames_f32
 * 反之定义后，DRWAV_PRIVATE 仍为 static，内部辅助函数不会被导出，符号表干净。
 * ---------------------------------------------------------------------------
 *
 * 【薄封装适配层（M2 新增）】
 *
 * M0 阶段只用 dr_libs 的「一次读完」API（drwav_open_file_and_read_pcm_frames_f32），
 * 该接口返回指针，调用方无需知道 drwav 结构体布局。
 *
 * 但**流式解码**必须使用 drwav_init_file(pWav, ...) —— 它要求调用方自行提供
 * drwav 结构体内存。该结构体极大且字段构成属实现细节，在仓颉侧完整镜像既
 * 脆弱又无必要。
 *
 * 因此在 C 侧追加一层薄封装：
 *   - 用 malloc(sizeof(drwav)) 在 C 侧分配实例，对仓颉**只暴露不透明句柄 void***
 *   - 仓颉侧无需镜像任何 @C struct，也无需关心字段偏移
 *   - 该模式对 dr_flac / dr_mp3 同样适用（M4 照此扩展）
 *
 * 这是 FFI 适配层的通用做法，也是开发文档 §12.3「堆分配风格」思路的推广。
 *
 * ---------------------------------------------------------------------------
 * 【编译方式（三平台，产物均为**静态库**）】
 *   由 build.cj 自动执行，无需手工编译。形态是「编译成目标文件 → 归档」：
 *     Windows 必须用 MinGW 口径的 gcc（原因见下）：
 *         gcc -c -O2 -fstack-protector-all -I third-party/dr_libs \
 *             third-party/drlibs_wrapper.c -o <dir>/drlibs.o
 *         ar rcs <dir>/libdrlibs.a <dir>/drlibs.o
 *     Linux / macOS：
 *         clang -c -fPIC -O2 -fstack-protector-all -I third-party/dr_libs \
 *               third-party/drlibs_wrapper.c -o <dir>/drlibs.o
 *         ar rcs <dir>/libdrlibs.a <dir>/drlibs.o
 *   其中 <dir> = libs/<平台>/（见 build.cj 与 cjpm.toml 的 target 级 [ffi.c]）。
 *
 *   Windows 必须 MinGW 口径：cjc 在 Windows 上走 MinGW 链接器，而 clang 默认的
 *   MSVC 目标所编目标文件静态链接时会缺 __chkstk / _fltused（MSVC CRT 符号）。
 *   编**动态库**时不存在该问题，这是改成静态链接之后才暴露的。详见 build.cj。
 *
 * 【安全】
 * - 始终启用 -fstack-protector-all（对应开发文档 §6.5 规约 #13）
 * - C 函数实际栈用量仓颉无法感知，FFI 侧需按需调整 cjStackSize
 * - 函数名不使用 CJ_ 前缀，避免与编译器内部符号冲突
 * ========================================================================== */

#include <stdlib.h>

#define DRWAV_DLL                /* 启用 DLL 导出语义（Windows 需要 dllexport） */
#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"

/* 本文件自定义的函数不在 dr_wav.h 内，须自行声明导出 */
#if defined(_WIN32)
    #define A4CJ_EXPORT __declspec(dllexport)
#else
    #define A4CJ_EXPORT __attribute__((visibility("default")))
#endif


/* ==========================================================================
 * 一、流式解码薄封装（M2 使用）
 *
 * 生命周期契约：
 *   audio4cj_wav_open()  成功返回非空句柄；失败返回 NULL。
 *   audio4cj_wav_close() 必须与 open 配对调用（幂等，接受 NULL）。
 *   句柄由 C 侧 malloc 分配，故**只能用 close 释放**，不可用 drwav_free。
 * ======================================================================== */

/// 打开 WAV 文件并初始化解码器。成功返回不透明句柄，失败返回 NULL。
A4CJ_EXPORT
void* audio4cj_wav_open(const char* filename)
{
    drwav* pWav;

    if (filename == NULL) {
        return NULL;
    }

    pWav = (drwav*)malloc(sizeof(drwav));
    if (pWav == NULL) {
        return NULL;
    }

    /* 第三个参数传 NULL 表示使用 dr_libs 默认分配器 */
    if (drwav_init_file(pWav, filename, NULL) == DRWAV_FALSE) {
        free(pWav);
        return NULL;
    }

    return (void*)pWav;
}

/// 读取至多 frames 帧的 f32 交错 PCM 到 out，返回实际读取的帧数（0 表示流结束）。
A4CJ_EXPORT
drwav_uint64 audio4cj_wav_read_f32(void* handle, drwav_uint64 frames, float* out)
{
    if (handle == NULL || out == NULL) {
        return 0;
    }
    return drwav_read_pcm_frames_f32((drwav*)handle, frames, out);
}

/// 采样率（Hz）。句柄为空时返回 0。
A4CJ_EXPORT
drwav_uint32 audio4cj_wav_sample_rate(void* handle)
{
    if (handle == NULL) {
        return 0;
    }
    return ((drwav*)handle)->sampleRate;
}

/// 声道数。句柄为空时返回 0。
A4CJ_EXPORT
drwav_uint16 audio4cj_wav_channels(void* handle)
{
    if (handle == NULL) {
        return 0;
    }
    return ((drwav*)handle)->channels;
}

/// 源位深（16 / 24 / 32）。句柄为空时返回 0。
A4CJ_EXPORT
drwav_uint16 audio4cj_wav_bits_per_sample(void* handle)
{
    if (handle == NULL) {
        return 0;
    }
    return ((drwav*)handle)->bitsPerSample;
}

/// 总帧数（若不可知则为 0）。句柄为空时返回 0。
A4CJ_EXPORT
drwav_uint64 audio4cj_wav_total_frames(void* handle)
{
    if (handle == NULL) {
        return 0;
    }
    return ((drwav*)handle)->totalPCMFrameCount;
}

/// 释放解码器与句柄（幂等，接受 NULL）。
A4CJ_EXPORT
void audio4cj_wav_close(void* handle)
{
    if (handle != NULL) {
        drwav_uninit((drwav*)handle);   /* 归还 dr_libs 内部资源 */
        free(handle);                    /* 归还本文件 malloc 的内存 */
    }
}


/* ==========================================================================
 * 二、释放 dr_libs 内部分配的内存（M0 使用的「一次读完」API 配套）
 *   drwav_open_file_and_read_pcm_frames_f32 返回的指针由 dr_libs 默认分配器
 *   分配，必须用 drwav_free 释放（而非 free）。
 * ======================================================================== */

A4CJ_EXPORT
void audio4cj_drwav_free(void* p)
{
    drwav_free(p, NULL);
}


/* ==========================================================================
 * 三、dr_flac / dr_mp3 实现（M4 新增）
 *
 * 与 dr_wav 置于**同一翻译单元**：dr_libs 各头文件使用互不冲突的符号前缀
 * （drwav_ / drflac_ / drmp3_），实测可共存，一次编译即产出三种格式的实现。
 *
 * DRFLAC_DLL / DRMP3_DLL 与 DRWAV_DLL 同理（见文件头说明）：
 * 不定义则 Windows DLL **不导出任何符号**，链接时报 undefined symbol。
 * 定义后 DRFLAC_PRIVATE / DRMP3_PRIVATE 仍为 static，内部符号不外泄。
 * ======================================================================== */

#define DRFLAC_DLL
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"

#define DRMP3_DLL
#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"


/* ==========================================================================
 * 四、统一句柄层（M4 新增）—— 抹平 FLAC 与 MP3 的句柄风格差异
 *
 * 两者的打开方式并不一致（已逐字核对头文件）：
 *
 *   FLAC : drflac* drflac_open_file(const char*, const drflac_allocation_callbacks*);
 *          —— dr_libs 内部完成堆分配，失败返回 NULL
 *   MP3  : drmp3_bool32 drmp3_init_file(drmp3*, const char*, const drmp3_allocation_callbacks*);
 *          —— **调用方自备 drmp3 结构体内存**
 *
 * drmp3 结构体是巨型实现细节（含解码器状态、缓冲区、seek 点等），
 * 在仓颉侧镜像既脆弱又无必要。因此本层对 MP3 采用
 * malloc(sizeof(drmp3)) 在 C 侧分配，对仓颉只暴露**不透明句柄 void\*** ——
 * 与上文 WAV 薄封装完全同构，仓颉侧无需镜像任何 @C struct。
 *
 * 生命周期契约：
 *   audio4cj_drlibs_open()  成功返回非空句柄；失败返回 NULL。
 *   audio4cj_drlibs_close() 必须与 open 配对调用（幂等，接受 NULL）。
 * ======================================================================== */

#include <stdint.h>

/* 格式标识：取值与仓颉侧 DrLibsFormat 枚举一一对应，不得随意改动 */
#define A4CJ_KIND_FLAC  0
#define A4CJ_KIND_MP3   1

typedef struct
{
    int   kind;     /* A4CJ_KIND_FLAC 或 A4CJ_KIND_MP3 */
    void* impl;     /* drflac*，或 drmp3*（后者为本层 malloc 的结构体） */
} audio4cj_handle;

/// 打开文件并初始化解码器。kind 取 A4CJ_KIND_FLAC / A4CJ_KIND_MP3。
/* --------------------------------------------------------------------------
 * 【Windows 路径编码：必须走宽字符接口（2026-10-02 实测踩坑）】
 *
 * C 运行时的 fopen 在 Windows 上按 **ANSI 代码页**（简体中文环境为 GBK）
 * 解释路径，而仓颉的 String 是 UTF-8 编码。若直接调用 dr_libs 的窄字符
 * 接口 drflac_open_file / drmp3_init_file，**凡是含中文等非 ASCII 字符的
 * 文件路径一律打不开** —— 实测现象是报「dr_libs 无法解析该文件」，
 * 而文件本身完全正常，极易误判为数据损坏。
 *
 * 因此 Windows 下统一：UTF-8 路径 -> MultiByteToWideChar -> 宽字符接口
 * （drflac_open_file_w / drmp3_init_file_w，内部使用 _wfopen）。
 *
 * POSIX 平台以 UTF-8 为原生编码，窄字符接口即正确，无需转换。
 * ------------------------------------------------------------------------ */
#if defined(_WIN32)
    #define WIN32_LEAN_AND_MEAN
    #define NOMINMAX
    #include <windows.h>

    #define A4CJ_CP_UTF8 65001

    /// 把 UTF-8 路径转为宽字符字符串。失败返回 NULL；成功时由调用方 free。
    static wchar_t* a4cj_utf8ToWide(const char* utf8)
    {
        int len;
        wchar_t* out;

        len = MultiByteToWideChar(A4CJ_CP_UTF8, 0, utf8, -1, NULL, 0);
        if (len <= 0) {
            return NULL;
        }
        out = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)len);
        if (out == NULL) {
            return NULL;
        }
        if (MultiByteToWideChar(A4CJ_CP_UTF8, 0, utf8, -1, out, len) <= 0) {
            free(out);
            return NULL;
        }
        return out;
    }
#endif

A4CJ_EXPORT
void* audio4cj_drlibs_open(int kind, const char* filename)
{
    audio4cj_handle* h;

    if (filename == NULL) {
        return NULL;
    }

    h = (audio4cj_handle*)malloc(sizeof(audio4cj_handle));
    if (h == NULL) {
        return NULL;
    }
    h->kind = kind;
    h->impl = NULL;

#if defined(_WIN32)
    {
        wchar_t* wpath = a4cj_utf8ToWide(filename);
        if (wpath == NULL) {
            free(h);
            return NULL;
        }

        if (kind == A4CJ_KIND_FLAC) {
            h->impl = (void*)drflac_open_file_w(wpath, NULL);
        } else if (kind == A4CJ_KIND_MP3) {
            drmp3* pMP3 = (drmp3*)malloc(sizeof(drmp3));
            if (pMP3 != NULL) {
                if (drmp3_init_file_w(pMP3, wpath, NULL) == DRMP3_FALSE) {
                    free(pMP3);
                } else {
                    h->impl = (void*)pMP3;
                }
            }
        }

        free(wpath);
    }
#else
    if (kind == A4CJ_KIND_FLAC) {
        h->impl = (void*)drflac_open_file(filename, NULL);
    } else if (kind == A4CJ_KIND_MP3) {
        drmp3* pMP3 = (drmp3*)malloc(sizeof(drmp3));
        if (pMP3 != NULL) {
            if (drmp3_init_file(pMP3, filename, NULL) == DRMP3_FALSE) {
                free(pMP3);
            } else {
                h->impl = (void*)pMP3;
            }
        }
    }
#endif

    if (h->impl == NULL) {
        free(h);
        return NULL;
    }

    return (void*)h;
}

/// 读取至多 frames 帧的 f32 交错 PCM 到 out，返回**实际读取的帧数**（0 表示流结束）。
A4CJ_EXPORT
uint64_t audio4cj_drlibs_read_f32(void* handle, uint64_t frames, float* out)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL || out == NULL) {
        return 0;
    }

    if (h->kind == A4CJ_KIND_FLAC) {
        return (uint64_t)drflac_read_pcm_frames_f32((drflac*)h->impl, (drflac_uint64)frames, out);
    }
    return (uint64_t)drmp3_read_pcm_frames_f32((drmp3*)h->impl, (drmp3_uint64)frames, out);
}

/// 定位到指定 PCM 帧索引。返回 1 表示成功、0 表示失败。
A4CJ_EXPORT
int audio4cj_drlibs_seek(void* handle, uint64_t frameIndex)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL) {
        return 0;
    }

    if (h->kind == A4CJ_KIND_FLAC) {
        return (drflac_seek_to_pcm_frame((drflac*)h->impl, (drflac_uint64)frameIndex) == DRFLAC_TRUE) ? 1 : 0;
    }
    return (drmp3_seek_to_pcm_frame((drmp3*)h->impl, (drmp3_uint64)frameIndex) == DRMP3_TRUE) ? 1 : 0;
}

/// 采样率（Hz）。句柄为空时返回 0。
A4CJ_EXPORT
uint32_t audio4cj_drlibs_sample_rate(void* handle)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL) {
        return 0;
    }
    if (h->kind == A4CJ_KIND_FLAC) {
        return (uint32_t)((drflac*)h->impl)->sampleRate;
    }
    return (uint32_t)((drmp3*)h->impl)->sampleRate;
}

/// 声道数。句柄为空时返回 0。
A4CJ_EXPORT
uint32_t audio4cj_drlibs_channels(void* handle)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL) {
        return 0;
    }
    if (h->kind == A4CJ_KIND_FLAC) {
        return (uint32_t)((drflac*)h->impl)->channels;
    }
    return (uint32_t)((drmp3*)h->impl)->channels;
}

/// 源位深。
///   FLAC：STREAMINFO 中的真实位深（16 / 24 等）
///   MP3 ：**恒为 32** —— MP3 是有损格式、无源位深概念，解码输出为 f32，
///         故按本项目「32 代表 float32」的既有约定报告（见开发文档 §4.2）。
A4CJ_EXPORT
uint32_t audio4cj_drlibs_bits_per_sample(void* handle)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL) {
        return 0;
    }
    if (h->kind == A4CJ_KIND_FLAC) {
        return (uint32_t)((drflac*)h->impl)->bitsPerSample;
    }
    return 32u;
}

/// 总帧数；**0 表示不可知**。
///
/// 两个库的「未知」表示法**不同**，本层负责归一化：
///   FLAC：totalPCMFrameCount == 0 本身即表示未知（如流式来源）
///   MP3 ：totalPCMFrameCount == DRMP3_UINT64_MAX 表示未知（如未预扫描的 VBR）
A4CJ_EXPORT
uint64_t audio4cj_drlibs_total_frames(void* handle)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL) {
        return 0;
    }

    if (h->kind == A4CJ_KIND_FLAC) {
        return (uint64_t)((drflac*)h->impl)->totalPCMFrameCount;
    }

    {
        drmp3_uint64 n = ((drmp3*)h->impl)->totalPCMFrameCount;
        return (n == DRMP3_UINT64_MAX) ? 0u : (uint64_t)n;
    }
}

/// 当前所在的 PCM 帧索引（seek 后用于回推实际落点）。
A4CJ_EXPORT
uint64_t audio4cj_drlibs_current_frame(void* handle)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL || h->impl == NULL) {
        return 0;
    }
    if (h->kind == A4CJ_KIND_FLAC) {
        return (uint64_t)((drflac*)h->impl)->currentPCMFrame;
    }
    return (uint64_t)((drmp3*)h->impl)->currentPCMFrame;
}

/// 释放解码器与句柄（幂等，接受 NULL）。
A4CJ_EXPORT
void audio4cj_drlibs_close(void* handle)
{
    audio4cj_handle* h = (audio4cj_handle*)handle;

    if (h == NULL) {
        return;
    }

    if (h->impl != NULL) {
        if (h->kind == A4CJ_KIND_FLAC) {
            drflac_close((drflac*)h->impl);     /* 注意：FLAC 无 drflac_uninit，只有 close */
        } else if (h->kind == A4CJ_KIND_MP3) {
            drmp3_uninit((drmp3*)h->impl);
            free(h->impl);                       /* 归还本层 malloc 的结构体 */
        }
    }

    free(h);
}
