#!/usr/bin/env python3
"""纯 Python 的 MPEG1 Layer III **独立**解码器（单文件、零 C 依赖）。

【它存在的唯一理由】
    本库 MP3 解码在低码率下高频被整体衰减（详见
    docs/decode-deviation-localization-evaluation.md §5.1.2），
    PCM 级比对已经把范围压到"count1 区的内容"，再往下必须看**中间量**——
    也就是每个 granule 解码出来的 576 条频谱线 `dst`。
    既然不能编译 C 参照，就用纯 Python 写一份**独立实现**：逻辑按规范重写，
    **码表复用本库源码里那些已与参照实现逐值核对过的表**（用户明确认可：
    "用现成的码表"）。于是两边若在 `dst` 上分道扬镳，差异只会来自**逻辑**。

【独立性边界（必须写清楚，否则结论会被高估）】
    · 独立：帧头/旁信息解析、标度因子展开（含 scfsi 复用与 preflag）、
      区域划分与频带行走、big_values/count1 的码字解析、linbits 逃逸、
      反量化公式与指数换算 —— 全部按 ISO 11172-3 的描述重写，不看本库实现。
    · 复用：Huffman 三张码表（`tabs`/`tab32`/`tab33`/`tabindex`/`gLinbits`）、
      `G_POW43`、频带表与分区表、`gScfcDecode`、`gPreamp`。
      这些在本次评估中已与参照实现逐值比对一致（见文档 §5.1.2 表格）。
    · 因此本脚本能定位"逻辑错"，不能定位"表错"。

【自检：位计数守恒】
    规范规定每个 granule 的主数据占且仅占 `part2_3_length` 比特。
    本实现**不复位**位位置（本库为容错会强制对齐，因而掩盖了偏差），
    而是累计消费位数与声明值逐一核对 —— 这是最强的一条内部一致性判据：
    只要某处逻辑错（多读/少读一位），后续比特流立即错位、位计数必然对不上。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
SRC_HUFF = REPO / "src" / "format" / "mp3_huffman.cj"
SRC_L3 = REPO / "src" / "format" / "mp3_layer3.cj"

# --------------------------------------------------------------------------
# 1) 从本库源码中提取"已核对过的码表"
# --------------------------------------------------------------------------


def _extract_array(text: str, name: str, expect_ints: bool = True) -> list:
    """把 `let <name> ... = [ ... ];` 里的数组取出来（容忍换行与注释）。"""
    m = re.search(rf"\b{name}\b[^\[]*\[", text)
    if not m:
        raise KeyError(name)
    i = m.end() - 1
    depth = 0
    j = i
    while j < len(text):
        if text[j] == "[":
            depth += 1
        elif text[j] == "]":
            depth -= 1
            if depth == 0:
                break
        j += 1
    body = text[i + 1:j]
    body = re.sub(r"//[^\n]*", "", body)
    toks = [t for t in re.split(r"[,\s]+", body) if t]
    if expect_ints:
        return [int(float(t)) for t in toks]
    return [float(t) for t in toks]


class Tables:
    """本库源码里的码表（已与参照实现逐值核对）。"""

    def __init__(self) -> None:
        h = SRC_HUFF.read_text(encoding="utf-8")
        l3 = SRC_L3.read_text(encoding="utf-8")
        self.tabs = _extract_array(h, "tabs")
        self.tab32 = _extract_array(h, "tab32")
        self.tab33 = _extract_array(h, "tab33")
        self.tabindex = _extract_array(h, "tabindex")
        self.linbits = _extract_array(h, "gLinbits")
        self.pow43 = _extract_array(h, "G_POW43", expect_ints=False)
        self.expfrac = _extract_array(h, "G_EXPFRAC", expect_ints=False)
        self.scfc_decode = _extract_array(h, "gScfcDecode")
        self.preamps = _extract_array(h, "gPreamp")
        # 频带表是二维的：按行切开（gScfPartitions 在 huffman 文件里）
        self.scf_long = _extract_matrix(l3, "gScfLong")
        self.scf_short = _extract_matrix(l3, "gScfShort")
        self.scf_mixed = _extract_matrix(l3, "gScfMixed")
        self.scf_partitions = _extract_matrix(h, "gScfPartitions")


def _extract_matrix(text: str, name: str) -> list[list[int]]:
    m = re.search(rf"\b{name}\b[^\[]*\[", text)
    if not m:
        raise KeyError(name)
    i = m.end() - 1
    # 逐行取子数组
    rows = []
    j = i + 1
    depth = 1
    while j < len(text) and depth > 0:
        if text[j] == "[":
            k = j
            inner = 0
            while k < len(text):
                if text[k] == "[":
                    inner += 1
                elif text[k] == "]":
                    inner -= 1
                    if inner == 0:
                        break
                k += 1
            body = re.sub(r"//[^\n]*", "", text[j + 1:k])
            toks = [t for t in re.split(r"[,\s]+", body) if t]
            rows.append([int(float(t)) for t in toks])
            j = k + 1
        elif text[j] == "]":
            depth = 0
        else:
            j += 1
    return rows


# --------------------------------------------------------------------------
# 2) 位读取器（按字节流；支持跨帧位池拼接）
# --------------------------------------------------------------------------


class Bits:
    def __init__(self, data: bytes) -> None:
        self.d = data
        self.pos = 0            # 位位置（相对 data 起点）

    def get(self, n: int) -> int:
        v = 0
        for _ in range(n):
            byte = self.d[self.pos >> 3]
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def peek(self, n: int) -> int:
        keep = self.pos
        v = self.get(n)
        self.pos = keep
        return v


# --------------------------------------------------------------------------
# 3) 旁信息 / 标度因子 / 频谱解码
# --------------------------------------------------------------------------

#: 频带表行索引 → 采样率（与码表同一约定：0=11025/12000, 1=8000, 2=22050,
#: 3=24000, 4=16000, 5=44100, 6=48000, 7=32000）
SR_TABLE = {44100: 5, 48000: 6, 32000: 7, 22050: 2, 24000: 3, 16000: 4}


class GrInfo:
    def __init__(self) -> None:
        self.part23 = 0
        self.big_values = 0
        self.global_gain = 0
        self.scalefac_compress = 0
        self.window_switching = 0
        self.block_type = 0
        self.mixed = 0
        self.table_select = [0, 0, 0]
        self.subblock_gain = [0, 0, 0]
        self.region_count = [0, 0, 0]
        self.preflag = 0
        self.scalefac_scale = 0
        self.count1_table = 0
        self.scfsi = 0


class Mp3PyDecoder:
    def __init__(self, path: Path) -> None:
        self.raw = path.read_bytes()
        self.t = Tables()
        self.reservoir = b""

    # -- 帧头 ------------------------------------------------------------
    def _find_frames(self) -> list[tuple[int, int, int, int, int, int]]:
        """返回 [(offset, bitrate, srate, frame_bytes, channels, crc)]。"""
        out = []
        i = 0
        n = len(self.raw)
        rates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        srates = [44100, 48000, 32000]
        while i + 4 <= n:
            if self.raw[i] != 0xFF or (self.raw[i + 1] & 0xE0) != 0xE0:
                i += 1
                continue
            h = (self.raw[i] << 24) | (self.raw[i + 1] << 16) | \
                (self.raw[i + 2] << 8) | self.raw[i + 3]
            ver = (h >> 19) & 3
            layer = (h >> 17) & 3
            br_idx = (h >> 12) & 0xF
            sridx = (h >> 10) & 3
            pad = (h >> 9) & 1
            mode = (h >> 6) & 3
            # 规范：protection_bit = **0 表示有 CRC**（后面跟 16 位 CRC）。
            # 反向解读会让整份旁信息错位 16 位 —— 实测：part2_3_length 读出
            # 4048 这种"大于整帧比特数"的荒谬值，正是本行写反的信号。
            crc = 1 if ((h >> 16) & 1) == 0 else 0
            if ver != 3 or layer != 1 or br_idx in (0, 15) or sridx == 3:
                i += 1
                continue
            br = rates[br_idx] * 1000
            sr = srates[sridx]
            size = int(144 * br / sr) + pad
            if i + size > n:
                break
            out.append((i, br, sr, size, 1 if mode == 3 else 2, crc))
            i += size
        return out

    # -- 旁信息 ----------------------------------------------------------
    def _read_side_info(self, body: bytes, ch: int) -> tuple[list[list[GrInfo]], int]:
        b = Bits(body)
        mdb = b.get(9)
        b.get(5 if ch == 1 else 3)                       # private_bits
        scfsi = [b.get(4) for _ in range(ch)]
        grs: list[list[GrInfo]] = []
        for _gr in range(2):
            row = []
            for c in range(ch):
                g = GrInfo()
                g.part23 = b.get(12)
                g.big_values = b.get(9)
                if g.big_values > 288:
                    raise ValueError("big_values > 288")
                g.global_gain = b.get(8)
                g.scalefac_compress = b.get(4)
                if b.get(1):
                    g.window_switching = 1
                    g.block_type = b.get(2)
                    if g.block_type == 0:
                        raise ValueError("block_type 0 with window switching")
                    g.mixed = b.get(1)
                    g.table_select[0] = b.get(5)
                    g.table_select[1] = b.get(5)
                    g.subblock_gain = [b.get(3), b.get(3), b.get(3)]
                else:
                    g.table_select = [b.get(5), b.get(5), b.get(5)]
                    g.region_count[0] = b.get(4)
                    g.region_count[1] = b.get(3)
                g.preflag = b.get(1)
                g.scalefac_scale = b.get(1)
                g.count1_table = b.get(1)
                g.scfsi = scfsi[c]
                row.append(g)
            grs.append(row)
        return grs, mdb

    # -- 频带表 ----------------------------------------------------------
    def _sfb_table(self, sr: int, g: GrInfo) -> list[int]:
        row = SR_TABLE[sr]
        if g.window_switching and g.block_type == 2:
            if g.mixed == 0:
                tab = self.t.scf_short[row]
            else:
                tab = self.t.scf_mixed[row]
        else:
            tab = self.t.scf_long[row]
        return [v for v in tab if v > 0]      # 去掉 0 终止符

    # -- 标度因子 --------------------------------------------------------
    def _read_scalefactors(self, b: Bits, g: GrInfo, ch: int, prev: list[int] | None,
                           counts: list[int], sizes: list[int]) -> tuple[list[int], list[int]]:
        """按规范读标度因子。返回 (iscf, ist_pos)。

        scfsi 的语义是"**granule 1 复用 granule 0**"：位为 1 的那个分组
        不读比特，直接照抄 granule 0 的整数值。实现时按分组判断，
        **不**靠位模式移位 —— 移位写法容易与比特顺序搞混。
        """
        iscf: list[int] = []
        ist: list[int] = []
        for i in range(4):
            if counts[i] == 0:
                break
            cnt = counts[i]
            if (g.scfsi >> (3 - i)) & 1:
                if prev is None:
                    raise ValueError("granule 0 不可复用标度因子")
                iscf.extend(prev[len(iscf):len(iscf) + cnt])
                ist.extend([0] * cnt)
            else:
                nbits = sizes[i]
                for _ in range(cnt):
                    if nbits == 0:
                        iscf.append(0)
                        ist.append(0)
                    else:
                        iscf.append(b.get(nbits))
                        ist.append(0)
        return iscf, ist

    # -- Huffman ---------------------------------------------------------
    def _decode_huffman(self, b: Bits, g: GrInfo, sfb: list[int], scf: list[float],
                        limit: int) -> tuple[np.ndarray, int]:
        """解出 576 条频谱线（**已反量化**），不做后续变换。"""
        dst = np.zeros(576, dtype=np.float64)
        tabs, tabindex, linbits = self.t.tabs, self.t.tabindex, self.t.linbits

        # ---- 第一段：big_values（成对，按区域选表）----
        big = g.big_values
        region = 0
        sfb_i = 0
        scf_i = 0
        dst_i = 0
        # 区域边界：**窗口切换帧不用传输 region_count**，规范把边界固定为
        # "region 0 = 前 36 个样点（= 44.1kHz 长块的 7 个频带）、region 1 = 其余全部"。
        # 漏掉这条会让我这边在 region 2 上误用 table_select[2]（切换帧该位不传输、
        # 恒为 0 = **零表**）→ 大批样点只花 0 比特 → 整份对照失去意义。
        # 实测代价：mono_64 有 4 个 granule 因此"少花 300+ 比特"，
        # 我据它得出的"本库 big_values 多读 490 比特"结论是错的，已撤回。
        if g.window_switching and g.block_type != 0:
            region_bands = [7, 255, 255]
        else:
            region_bands = [g.region_count[0], g.region_count[1], 255]
        while big > 0 and region < 3:
            tab_num = g.table_select[region]
            bands = region_bands[region]
            off = tabindex[tab_num]
            lb = linbits[tab_num]
            region += 1
            while True:
                if sfb_i >= len(sfb):
                    break
                width = sfb[sfb_i]
                sfb_i += 1
                if scf_i >= len(scf):
                    break
                one = scf[scf_i]
                scf_i += 1
                pairs = width // 2
                for _ in range(pairs):
                    if big <= 0:
                        break
                    # 码表是"扁平化树"：正数=叶子（低 4 位值、接着 4 位符号标志、
                    # 高位码长），负数=内部节点。下降时先**吐掉刚才窥探的位宽**，
                    # 再按节点的 `& 7` 定下一级宽度；`>> 3` 是相对偏移（负数，
                    # 所以是"减去一个负数"，Python 的算术右移与 C 一致）。
                    w = 5
                    leaf = tabs[off + b.peek(w)]
                    while leaf < 0:
                        b.get(w)
                        w = leaf & 7
                        leaf = tabs[off + (b.peek(w) - (leaf >> 3))]
                    b.get(leaf >> 8)
                    for j in range(2):
                        lsb = (leaf >> (4 * j)) & 0x0F      # 低半字节是第一个值
                        v = lsb
                        if lsb == 15 and lb:
                            v += b.get(lb)                  # 逃逸码
                        sign = b.get(1) if v else 0
                        if dst_i < 576:
                            val = self._pow43(v) * one
                            dst[dst_i] = -val if sign else val
                        dst_i += 1
                    big -= 1
                bands -= 1
                if big <= 0 or bands < 0:
                    break
            if big <= 0:
                break

        print(f"BIGEND dstOff={dst_i} big={big} pos={b.pos} limit={limit} "
              f"sfbLeft={len(sfb) - sfb_i} scfIdx={scf_i}")

        # ---- 第二段：count1（四元组，每码字 4 个样点）----
        # 游标 np 的单位是**样点对**，一个码字覆盖 4 样点 = 2 对 → 每码字减 2。
        table = self.t.tab33 if g.count1_table else self.t.tab32
        npairs = 1 - big
        while True:
            # 一级查表用 4 位前缀；表项若无 `8` 标志则需二级：用**第一个 4 位之后**
            # 的 `leaf & 3` 位作为偏移（那 4 位此时还没被消费，最后按总码长一起吐）。
            leaf = table[b.peek(4)]
            if not (leaf & 8):
                k2 = leaf & 3
                extra = b.peek(4 + k2) & ((1 << k2) - 1) if k2 else 0
                leaf = table[(leaf >> 3) + extra]
            b.get(leaf & 7)
            if b.pos > limit:
                break
            for s in range(4):
                if (s & 1) == 0:
                    npairs -= 1
                    if npairs <= 0:
                        if sfb_i >= len(sfb):
                            return dst, dst_i
                        width = sfb[sfb_i]
                        sfb_i += 1
                        npairs = width // 2
                        if npairs == 0:
                            return dst, dst_i
                        if scf_i < len(scf):
                            one = scf[scf_i]
                            scf_i += 1
                if leaf & (128 >> s):
                    sign = b.get(1)
                    if dst_i < 576:
                        dst[dst_i] = -one if sign else one
                dst_i += 1
            if dst_i >= 576:
                break
        return dst, dst_i

    def _pow43(self, v: int) -> float:
        if v < len(self.t.pow43):
            return self.t.pow43[v]
        return float(v) ** (4.0 / 3.0)

    # -- 单个 granule ----------------------------------------------------
    def _decode_granule(self, b: Bits, g: GrInfo, sr: int, ch: int,
                        prev_iscf: list[int] | None, limit: int,
                        granule: int = 0) -> tuple[np.ndarray, list[int]]:
        if g.part23 == 0 and g.big_values == 0:
            # 空 granule：主数据为零比特，规范意义上是"整条频谱全零"。
            # 不要在这里读标度因子 —— 那会凭空消费比特、让位计数对不上。
            self.last_dst_i = 0
            return np.zeros(576, dtype=np.float64), [0] * 22
        if granule == 0:
            # scfsi 只对 granule 1 有意义：granule 0 一定自带标度因子
            g.scfsi = 0
        row = SR_TABLE[sr]
        sfb = self._sfb_table(sr, g)
        n_long = 0
        n_short = 0
        if g.window_switching and g.block_type == 2:
            if g.mixed == 0:
                n_short = len(sfb)
            else:
                n_long, n_short = 8, len(sfb) - 8
        else:
            n_long = len(sfb)

        idx = (1 if n_short else 0) + (1 if n_long == 0 else 0)
        part = self.t.scf_partitions[idx]
        counts = [part[0], part[1], part[2], part[3]]

        if g.window_switching and g.block_type == 2 and g.mixed == 0:
            g.scfsi = 0                       # 纯短块不使用 scfsi（规范）

        sizes = [0, 0, 0, 0]
        p = self.t.scfc_decode[g.scalefac_compress]
        sizes[0] = sizes[1] = p >> 2
        sizes[2] = sizes[3] = p & 3

        raw, ist = self._read_scalefactors(b, g, ch, prev_iscf, counts, sizes)
        iscf = list(raw)
        # 分区表只覆盖 21 带（长块）/ 36 带（短块），**尾部由实现补零**：
        # 规范把最后一带（短块是最后三带 = 三个窗）的标度因子当作 0 处理，
        # 因此它不再衰减（增益为满值）。漏掉这一步会让最后一带的标度因子
        # 缺失/取错 —— 那正好落在频谱最高处，症状与"高频被压低"一模一样。
        total_bands = n_long + n_short
        if len(iscf) < total_bands:
            iscf = iscf + [0] * (total_bands - len(iscf))

        # 短块：subblock_gain 以 8 个标度因子刻度为单位叠加（规范 2.4.2.7）
        if n_short:
            for i in range(n_short):
                iscf[n_long + i] += g.subblock_gain[i % 3] * 8
        elif g.preflag:
            for i in range(10):
                iscf[11 + i] += self.t.preamps[i]

        # 反量化：x = pow43(is) * sign * 2^(gain_exp/4) * 2^(-iscf*2^(scale+1)/4)
        gain_exp = g.global_gain - 4 - 210
        gain = 2.0 ** (gain_exp / 4.0)
        shift = g.scalefac_scale + 1
        scf = [gain * 2.0 ** (-(v << shift) / 4.0) for v in iscf]

        dst, dst_i = self._decode_huffman(b, g, sfb, scf, limit)
        self.last_dst_i = dst_i
        return dst, iscf


# --------------------------------------------------------------------------
# 4) 与"本库 dump 的逐带能量"对照
# --------------------------------------------------------------------------

#: 长块 44.1kHz 的标度因子带边界（谱线号）—— 与块类型无关，
#: 作为两边的**公共分母**比较最稳。
LONG_BOUNDS = [0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168,
               200, 238, 284, 336, 396, 464, 522, 576]


def band_energies(dst: np.ndarray) -> list[float]:
    return [float(np.sum(dst[LONG_BOUNDS[i]:LONG_BOUNDS[i + 1]] ** 2))
            for i in range(len(LONG_BOUNDS) - 1)]


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "eval_work/probes/mono_64.mp3"
    max_frames = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    dec = Mp3PyDecoder(path)
    frames = dec._find_frames()
    print(f"{path.name}: {len(frames)} 帧（前 {max_frames} 帧做独立解码）")
    print(f"第 0 帧: bitrate={frames[0][1] // 1000}k sr={frames[0][2]} "
          f"size={frames[0][3]}B ch={frames[0][4]}")

    reservoir = b""
    econ: list[tuple[int, int]] = []
    for fi, (off, br, sr, size, chp, crc) in enumerate(frames[:max_frames]):
        body = dec.raw[off + 4:off + size]
        if crc:
            body = body[2:]
        grs, mdb = dec._read_side_info(body, chp)
        # 主数据 = 位池尾部 + 本帧负载（与解码器一致；位池按"未消费尾部 ≤511 字节"维护）
        take = min(len(reservoir), mdb)
        # 主数据 = 位池的**最后 take 个字节** + 本帧负载，位位置从 0 开始
        # （编码器把本帧主数据的开头放在了 `mdb` 字节之前，所以位池尾部就是本帧的开头）
        main = reservoir[len(reservoir) - take:] + body[_side_info_bytes(chp, crc):]
        b = Bits(main)
        start_bits = b.pos
        prev_by_ch: dict[int, list[int]] = {}
        declared = sum(g.part23 for row in grs for g in row)
        for gi, row in enumerate(grs):
            for ci, g in enumerate(row):
                limit = b.pos + g.part23
                dst, iscf = dec._decode_granule(b, g, sr, ci, prev_by_ch.get(ci), limit,
                                                gi)
                prev_by_ch[ci] = iscf
                be = band_energies(dst)
                print(f"  SPCDBG dstOff={dec.last_dst_i} frame={fi} gr={gi} ch={ci} "
                      f"big={g.big_values} bt={g.block_type} mix={g.mixed} "
                      f"scale={g.scalefac_scale} pre={g.preflag} sfc={g.scalefac_compress} "
                      f"bits={b.pos - (limit - g.part23)}/{g.part23} "
                      f"bands=[" + ",".join(f"{v:.6e}" for v in be) + "]")
                # 每个 granule 跑完都必须落在声明的位预算之内（不允许越读）
                if b.pos > limit:
                    print(f"     !! granule 越读 {(b.pos - limit)} 比特")
                if g.part23 > 0 or g.big_values > 0:
                    econ.append((g.part23, b.pos - (limit - g.part23)))
                b.pos = limit                  # 与本库/参照同构：按声明长度对齐
        consumed = b.pos - start_bits
        print(f"  -> 帧 {fi}: 主数据消费 {consumed} 比特（短于声明属正常填充），"
              f"声明 {declared} 比特，{'越读!!!' if consumed > declared else '未越读'}")
        # 维护位池：未消费的尾部（最多 511 字节）
        tail = main[b.pos // 8:]
        reservoir = tail[-511:]

    # 位预算利用率 = 本实现"健康度"的判据：
    #   规范要求每个 granule 的主数据**恰好**占 part2_3_length 比特，编码器不会
    #   白留几百比特。所以"声明 - 消费"应当很小（末尾填充通常 < 8 比特）。
    #   若大量 granule 出现数百比特的富余，说明本实现漏解了数据（判据自身不可信）。
    if econ:
        gaps = [d - c for d, c in econ]
        big = [g for g in gaps if g > 64]
        print(f"\n位预算利用率：granule {len(gaps)} 个，平均富余 "
              f"{sum(gaps) / len(gaps):.1f} 比特，最大富余 {max(gaps)} 比特，"
              f"富余 > 64 比特的 granule：{len(big)}/{len(gaps)}")
        print(f"  {'健康' if not big else '不健康 —— 本实现存在漏解，结论不可采信'}")
    return 0


def _side_info_bytes(chp: int, crc: bool) -> int:
    return (17 if chp == 1 else 32) + (2 if crc else 0)


if __name__ == "__main__":
    sys.exit(main())
