# -*- coding: utf-8 -*-
import io

p = 'src/format/mp3_anchor.cj'
lines = io.open(p, encoding='utf-8').read().splitlines(keepends=True)

# 行号（1 基）：265=签名（含 marker）、285=early return、293/294=赋值、找调用点
def find(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    raise AssertionError('not found')

sig_i = find(lambda l: 'private func parseLameHeader' in l)
early_i = find(lambda l: l.strip().startswith('return') and 'tagEquals' not in l, sig_i)
asg_i = find(lambda l: 'out.lameDelay = delay' in l, sig_i)
call_i = find(lambda l: 'parseLameHeader(data, bytes, xOff, flags, out)' in l)

# 签名
lines[sig_i] = lines[sig_i].replace('flags: Int64, out: XingInfo): Unit', 'flags: Int64): (Int64, Int64)')
# early return
lines[early_i] = lines[early_i].replace('return', 'return (-1, -1)')
# 赋值 → 返回
lines[asg_i] = lines[asg_i].replace('out.lameDelay = delay', 'return (delay, padding)')
lines[asg_i + 1] = ''
lines[asg_i + 2] = ''  # 吞掉 if 的收尾 }? 不——保持 if 结构：改为在 if 内 return 后仍有 }
# 上面 if 块：return (delay, padding) 在 if 内合法，块尾 } 保留——只删 out.lamePadding 行
# 调用点
lines[call_i] = lines[call_i].replace(
    'parseLameHeader(data, bytes, xOff, flags, out)',
    'let (lameD, lameP) = parseLameHeader(data, bytes, xOff, flags)\n            out.lameDelay = lameD\n            out.lamePadding = lameP')

io.open(p, 'w', encoding='utf-8', newline='').write(''.join(lines))
print('patched by line numbers')
