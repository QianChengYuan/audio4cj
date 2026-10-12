# -*- coding: utf-8 -*-
# audio4cj v0.1.6 gapless 补丁：anchor 解析 LAME 头 + mp3.cj 解码层裁剪
import io

def patch(path, old, new, label):
    s = io.open(path, encoding='utf-8').read()
    assert old in s, 'NOT FOUND: ' + label
    assert s.count(old) == 1, 'NOT UNIQUE: ' + label
    io.open(path, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
    print('patched:', label)

A = 'src/format/mp3_anchor.cj'
M = 'src/format/mp3.cj'

# ---- 1. anchor: readVbrFrames 返回 XingInfo，顺带解析 LAME delay/padding ----
patch(A, '''private func readVbrFrames(data: Array<UInt8>, bytes: Int64, frameOffset: Int64, hdr: Array<UInt8>): (Int64, Bool) {''',
'''/// Xing/Info/VBRI 锚点解析结果（v0.1.6 增补 LAME gapless 字段）。
protected struct XingInfo {
    var frames: Int64 = -1
    var isVbr: Bool = false
    // LAME 头的 encoder delay / padding（PCM 帧数）；-1 = 未知（无 LAME 头）
    var lameDelay: Int64 = -1
    var lamePadding: Int64 = -1
}

private func readVbrFrames(data: Array<UInt8>, bytes: Int64, frameOffset: Int64, hdr: Array<UInt8>): XingInfo {
    let out = XingInfo()''', 'readVbrFrames 签名')

patch(A, '''    // Xing / Info：紧随帧头 + CRC + side info 之后
    let xOff = frameOffset + HDR_SIZE + crc + sideInfo
    if (tagEquals(data, xOff, "Xing") || tagEquals(data, xOff, "Info")) {
        let flags = readU32BE(data, xOff + 4)
        if ((flags & 1) != 0 && xOff + 12 <= bytes) {
            // "Info" 是 LAME 写 CBR 时的锚点名；"Xing"/"VBRI" 才是 VBR
            let isVbr = tagEquals(data, xOff, "Xing")
            return (readU32BE(data, xOff + 8), isVbr)
        }
    }

    // VBRI：固定在帧头之后 32 字节处；其 frames 字段位于 VBRI 起点 +14
    let vOff = frameOffset + HDR_SIZE + 32
    if (tagEquals(data, vOff, "VBRI") && vOff + 18 <= bytes) {
        return (readU32BE(data, vOff + 14), true)
    }

    (-1, false)
}''',
'''    // Xing / Info：紧随帧头 + CRC + side info 之后
    let xOff = frameOffset + HDR_SIZE + crc + sideInfo
    if (tagEquals(data, xOff, "Xing") || tagEquals(data, xOff, "Info")) {
        let flags = readU32BE(data, xOff + 4)
        if ((flags & 1) != 0 && xOff + 12 <= bytes) {
            // "Info" 是 LAME 写 CBR 时的锚点名；"Xing"/"VBRI" 才是 VBR
            out.isVbr = tagEquals(data, xOff, "Xing")
            out.frames = readU32BE(data, xOff + 8)
            parseLameHeader(data, bytes, xOff, flags, out)
            return out
        }
    }

    // VBRI：固定在帧头之后 32 字节处；其 frames 字段位于 VBRI 起点 +14
    let vOff = frameOffset + HDR_SIZE + 32
    if (tagEquals(data, vOff, "VBRI") && vOff + 18 <= bytes) {
        out.frames = readU32BE(data, vOff + 14)
        out.isVbr = true
        return out
    }

    out
}

/// 解析 LAME 头的 encoder delay / padding（gapless）。
///
/// 位置：紧随锚点的可选字段（flags 逐位回退）之后是 LAME 版本串（"LAME…"，
/// 9 字节起）；版本串后依次为 rev/method(1) + lowpass(1) + peak(4) + radio(2)
/// + audiophile(2) + flags(2)，**偏移 21 处的 3 字节**是 big-endian 的
/// delay/padding 打包值：高 12 位 delay、低 12 位 padding。
/// 解析结果做合理性夹紧（0..8191），离谱值按未知处理（保守不裁剪）。
private func parseLameHeader(data: Array<UInt8>, bytes: Int64, xOff: Int64, flags: Int64, out: XingInfo): Unit {
    // 从 "Xing"/"Info" 之后逐位回退可选字段，定位 LAME 版本串
    var p = xOff + 4
    if ((flags & 1) != 0) {
        p += 4 // frames
    }
    if ((flags & 2) != 0) {
        p += 4 // bytes
    }
    if ((flags & 4) != 0) {
        p += 100 // TOC
    }
    if ((flags & 8) != 0) {
        p += 4 // quality
    }
    if (!tagEquals(data, p, "LAME") || p + 24 > bytes) {
        return
    }
    // 3 字节打包值位于 LAME 版本串起点 +21
    let v = (Int64(data[p + 21]) << 16) | (Int64(data[p + 22]) << 8) | Int64(data[p + 23])
    let delay = v >> 12
    let padding = v & 0xFFF
    // 合理性：LAME 默认 delay=576，padding 通常 0..3000
    if (delay <= 8191 && padding <= 8191) {
        out.lameDelay = delay
        out.lamePadding = padding
    }
}''', 'readVbrFrames 主体 + LAME 解析')

patch(A, '''    // Xing/VBRI 里记的是 **MP3 帧数**，需乘每帧样本数才是本库口径的 PCM 帧数
    let (vbrFrames, vbrFlag) = readVbrFrames(data, bytes, found.offset, hdr)
    a.totalFrames = if (vbrFrames >= 0) {
        vbrFrames * a.samplesPerFrame
    } else {
        -1
    }
    a.isVbr = vbrFlag
    Some(a)''',
'''    // Xing/VBRI 里记的是 **MP3 帧数**，需乘每帧样本数才是本库口径的 PCM 帧数
    let xing = readVbrFrames(data, bytes, found.offset, hdr)
    a.totalFrames = if (xing.frames >= 0) {
        xing.frames * a.samplesPerFrame
    } else {
        -1
    }
    a.isVbr = xing.isVbr
    a.lameDelay = xing.lameDelay
    a.lamePadding = xing.lamePadding
    Some(a)''', 'anchor 填充 LAME 字段')

# ---- 2. mp3.cj: 字段 + init 裁剪参数 + nextPacket 裁剪 + seekTo 对齐 ----
patch(M, '''    /// LAME 头的 encoder delay/padding 解析见 mp3_anchor.cj；本层只做裁剪。
''', '''    /// LAME 头的 encoder delay/padding 解析见 mp3_anchor.cj；本层只做裁剪。
''') if False else None

patch(M, '''    private let _channelMode: String
''',
'''    private let _channelMode: String

    /// gapless（v0.1.6）：交付层裁剪参数。
    /// 解码器输出的流首 delay 帧、流尾 padding 帧是编码器填充（LAME 头声明），
    /// 不裁剪则连续播放有可闻咔哒/静音缝。二者未知（-1）时全部按 0 处理。
    /// 口径：`_skipFrames` = 输出流起点要丢弃的 PCM 帧；`_deliverFrames` =
    /// 应交付的有效 PCM 帧总数（-1 = 未知，不设上限）。
    private let _skipFrames: Int64
    private let _deliverFrames: Int64
    private var _deliveredFrames: Int64 = 0
''', 'mp3 字段')

patch(M, '''        this._channelMode = match (a.stereoMode) {
            case 0 => "stereo"
            case 1 => "joint stereo"
            case 2 => "dual channel"
            case _ => "mono"
        }
    }''',
'''        this._channelMode = match (a.stereoMode) {
            case 0 => "stereo"
            case 1 => "joint stereo"
            case 2 => "dual channel"
            case _ => "mono"
        }
        // gapless 裁剪参数：仅在有 Xing/Info 总帧数与 LAME 头时可用
        this._skipFrames = if (a.lameDelay >= 0) {
            a.lameDelay
        } else {
            0
        }
        let rawTotal = a.totalFrames
        if (rawTotal > 0 && a.lameDelay >= 0 && a.lamePadding >= 0) {
            let effective = rawTotal - this._skipFrames - a.lamePadding
            this._deliverFrames = if (effective > 0) {
                effective
            } else {
                0
            }
            // 时长口径同步收紧（有效时长而非含填充的原始时长）
            this._totalFrames = this._deliverFrames
        } else {
            this._deliverFrames = -1
        }
    }''', 'mp3 init 裁剪参数')

# _totalFrames 是 let——需要改为 var 以允许收紧。查声明。
s = io.open(M, encoding='utf-8').read()
old_dec = '''    /// 总帧数；**-1 表示不可知**（无 Xing/VBRI 且无法估算）。
    private let _totalFrames: Int64'''
new_dec = '''    /// 总帧数；**-1 表示不可知**（无 Xing/VBRI 且无法估算）。
    /// 有 LAME 头时为裁剪后的有效帧数（init 末尾收紧，故为 var）。
    private var _totalFrames: Int64'''
assert old_dec in s, 'NOT FOUND: _totalFrames 声明'
s = s.replace(old_dec, new_dec, 1)
io.open(M, 'w', encoding='utf-8', newline='').write(s)
print('patched: _totalFrames let->var')

# nextPacket 裁剪：替换收尾段
patch(M, '''        if (framesOut == 0) {
            return None
        }

        _framesConsumed += framesOut
        let data = f32ToBytes(acc[0..framesOut * _channels])
        let timestampMs = startFrame * 1000 / _sampleRate
        let durationMs = framesOut * 1000 / _sampleRate
        Packet(0, data, timestampMs, durationMs)
    }''',
'''        // ---- gapless 裁剪（v0.1.6）----
        // 解码帧坐标 [startFrame, startFrame+framesOut) 与有效交付区间
        // [_skipFrames, _skipFrames+_deliverFrames) 取交集；交集为空且已越过
        // 区间末端即流结束。_framesConsumed 保持"原始解码帧"口径（seek 用）。
        var lo = startFrame
        var hi = startFrame + framesOut
        if (_deliverFrames >= 0) {
            let limitEnd = _skipFrames + _deliverFrames
            lo = if (startFrame > _skipFrames) {
                startFrame
            } else {
                _skipFrames
            }
            hi = if (hi < limitEnd) {
                hi
            } else {
                limitEnd
            }
        }
        let outFrames = hi - lo
        if (outFrames <= 0) {
            return None
        }
        if (lo != startFrame || hi != startFrame + framesOut) {
            // 把交集样本搬到 acc 头部（区间可能重叠，手动循环最稳）
            let src0 = lo - startFrame
            var k: Int64 = 0
            while (k < outFrames * _channels) {
                acc[k] = acc[src0 * _channels + k]
                k += 1
            }
        }
        framesOut = outFrames

        _framesConsumed = startFrame + framesOutRaw
        let data = f32ToBytes(acc[0..framesOut * _channels])
        // 时间戳用交付口径（减去流首被丢弃的 delay 帧）
        let deliveredStart = lo - _skipFrames
        let timestampMs = if (deliveredStart > 0) {
            deliveredStart * 1000 / _sampleRate
        } else {
            0
        }
        let durationMs = framesOut * 1000 / _sampleRate
        Packet(0, data, timestampMs, durationMs)
    }''', 'nextPacket 裁剪')

# framesOutRaw：裁剪前的解码帧数。在上面裁剪代码之前原始 framesOut 被覆盖前需要保存——
# 在 `if (framesOut == 0) {` 之前插入 framesOutRaw 保存。
patch(M, '''        if (framesOut == 0) {
            return None
        }

        // ---- gapless 裁剪（v0.1.6）----''',
'''        if (framesOut == 0) {
            return None
        }
        let framesOutRaw = framesOut

        // ---- gapless 裁剪（v0.1.6）----''', '保存原始帧数')

# seekTo 对齐：target 是交付口径，内部用原始口径推进
patch(M, '''        var target = msToFramesSaturating(timestampMs, _sampleRate)
        if (_totalFrames > 0 && target >= _totalFrames) {
            target = _totalFrames - 1
        }
        if (target < 0) {
            target = 0
        }

        if (target < _framesConsumed) {''',
'''        var target = msToFramesSaturating(timestampMs, _sampleRate)
        if (_totalFrames > 0 && target >= _totalFrames) {
            target = _totalFrames - 1
        }
        if (target < 0) {
            target = 0
        }
        // 交付帧坐标 → 原始解码帧坐标（流首 delay 帧会被裁掉）
        var rawTarget = target + _skipFrames

        if (rawTarget < _framesConsumed) {''', 'seekTo 对齐 1')
patch(M, '''        let info = Mp3FrameInfo()
        while (_framesConsumed < target) {''',
'''        let info = Mp3FrameInfo()
        while (_framesConsumed < rawTarget) {''', 'seekTo 对齐 2')

print('ALL OK')
