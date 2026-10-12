# -*- coding: utf-8 -*-
import io

def patch(path, old, new, label):
    s = io.open(path, encoding='utf-8').read()
    assert old in s, 'NOT FOUND: ' + label
    assert s.count(old) == 1, 'NOT UNIQUE: ' + label
    io.open(path, 'w', encoding='utf-8', newline='').write(s.replace(old, new, 1))
    print('patched:', label)

A = 'src/format/mp3_anchor.cj'
M = 'src/format/mp3.cj'

# struct 值语义：let 改 var
patch(A, '''    let out = XingInfo()''', '''    var out = XingInfo()''', 'XingInfo let->var')

# 保存原始帧数（裁剪覆盖 framesOut 前）
patch(M, '''        if (framesOut == 0) {
            return None
        }

        // ---- gapless 裁剪（v0.1.6）----''',
'''        if (framesOut == 0) {
            return None
        }
        let framesOutRaw = framesOut

        // ---- gapless 裁剪（v0.1.6）----''', '保存原始帧数')

# seekTo 对齐
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
