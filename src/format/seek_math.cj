package audio4cj.format

/* ============================================================================
 * 时间戳 → 帧号的**饱和**换算（WAV / FLAC / MP3 三处 seekTo 共用）
 *
 * 背景：三处 seekTo 原先都用 `timestampMs * _sampleRate / 1000` 换算目标帧。
 * timestampMs 由调用方给出，可以是任意 Int64（例如 `Int64.Max`），而**仓颉的
 * 整数溢出是抛异常而不是回绕**：
 *
 *     Int64.Max * 44100   ->   OverflowException: mul
 *
 * 那是标准库异常，不是本库异常，违反「所有失败路径抛 Exception 子类」的错误
 * 契约 —— 调用方按文档用单个 `catch (e: Audio4CjException)` 兜不住它。
 * 故此处统一做饱和换算：超出可表示范围时返回 Int64.Max，再由各调用点按自己的
 * 总帧数/数据长度裁剪，任何中间乘法都不会溢出。
 * ========================================================================== */

/// 把毫秒时间戳换算为帧号，**饱和**处理（溢出时返回 `Int64.Max`，恒非负）。
///
/// - `ms <= 0` 或 `sampleRate <= 0`：返回 0（防御性，不抛异常）
/// - `ms > 0` 且换算结果超出 Int64 时返回 `Int64.Max`
///
/// 不溢出的依据：`ms / 1000` 与 `ms % 1000` 均不溢出；`sampleRate` 在三种
/// 格式下都来自字段或查表（WAV 采样率字段 32 位、FLAC 20 位、MP3 固定表），
/// 上限 4.3e9 量级，故 `remainder * sampleRate / 1000` 不会溢出；唯一的风险项
/// `secs * sampleRate` 与随后的加法都在乘/加之前做了上界判断。
protected func msToFramesSaturating(ms: Int64, sampleRate: Int64): Int64 {
    if (ms <= 0 || sampleRate <= 0) {
        return 0
    }

    let secs = ms / 1000
    if (secs > Int64.Max / sampleRate) {
        return Int64.Max
    }

    let base = secs * sampleRate
    let remainder = ms % 1000
    let extra = remainder * sampleRate / 1000
    if (base > Int64.Max - extra) {
        return Int64.Max
    }
    return base + extra
}
