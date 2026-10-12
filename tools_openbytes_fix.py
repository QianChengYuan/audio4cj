# -*- coding: utf-8 -*-
import io

p = 'src/facade/audio_file.cj'
s = io.open(p, encoding='utf-8').read()

def rep(old, new, label):
    global s
    assert old in s, 'NOT FOUND: ' + label
    s = s.replace(old, new, 1)
    print('patched:', label)

rep('''import std.env.*
import std.time.*''',
'''import std.env.*
import std.fs.*
import std.sync.*
import std.time.*''', 'import fs/sync')

rep('''    /// openBytes 的临时文件路径；非空表示 close 时需删除（v0.1.6）
    private var _tempPath: String = ""''',
'''    /// openBytes 的临时文件路径；非空表示 close 时需删除（v0.1.6）
    private var _tempPath: String = ""

    /// 临时文件序号（同进程内唯一）
    private static let _tmpSeq: AtomicInt64 = AtomicInt64(0)''', '静态序号')

rep('''        let tmp = "${dir}/audio4cj_${MonoTime.now().toNanoseconds()}.tmp"''',
'''        let tmp = "${dir}/audio4cj_${_tmpSeq.fetchAdd(1)}.tmp"''', 'tmp 文件名')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ALL OK')
