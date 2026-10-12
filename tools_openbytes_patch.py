# -*- coding: utf-8 -*-
import io

p = 'src/facade/audio_file.cj'
s = io.open(p, encoding='utf-8').read()

def patch(old, new, label):
    global s
    assert old in s, 'NOT FOUND: ' + label
    assert s.count(old) == 1, 'NOT UNIQUE: ' + label
    s = s.replace(old, new, 1)
    print('patched:', label)

# import
patch('''import audio4cj.codec.*
import std.collection.*''',
'''import audio4cj.codec.*
import std.collection.*
import std.env.*
import std.time.*''', 'import')

# 字段
patch('''    private var _closed: Bool = false''',
'''    private var _closed: Bool = false

    /// openBytes 的临时文件路径；非空表示 close 时需删除（v0.1.6）
    private var _tempPath: String = ""''', '字段')

# openBytes（插在 open() 结尾 `    }` 之后——用 open 的 case _ 行定位尾部）
patch('''            case _ => throw FormatNotSupportedException("容器 ${formatLabel(probe)} 尚无对应实现（${path}）")
        }
    }''',
'''            case _ => throw FormatNotSupportedException("容器 ${formatLabel(probe)} 尚无对应实现（${path}）")
        }
    }

    /// 从内存字节打开音频（v0.1.6）。
    ///
    /// 实现：写入临时文件后走 `open(path)`——探测与各解码器当前都以文件为
    /// I/O 单元，临时文件是**务实桥接**；临时文件在本实例 close 时自动删除，
    /// 使用方无需感知。在线播放场景（网络字节 → 解码）由此免手工落盘管理。
    public static func openBytes(bytes: Array<UInt8>): AudioFile {
        let dir = getVariable("TEMP") ?? getVariable("TMP") ?? "."
        let tmp = "${dir}/audio4cj_${MonoTime.now().toNanoseconds()}.tmp"
        File.writeTo(Path(tmp), bytes)
        let af = open(tmp)
        af._tempPath = tmp
        af
    }''', 'openBytes')

# close 清理
patch('''    /// 释放资源（幂等）。会一并关闭底层 reader。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            match (_reader) {
                case Some(r) => r.close()
                case None => ()
            }
        }
    }''',
'''    /// 释放资源（幂等）。会一并关闭底层 reader；
    /// openBytes 的临时文件在此一并删除。
    public func close(): Unit {
        if (!_closed) {
            _closed = true
            match (_reader) {
                case Some(r) => r.close()
                case None => ()
            }
            if (_tempPath != "") {
                removeIfExists(Path(_tempPath))
                _tempPath = ""
            }
        }
    }''', 'close')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ALL OK')
