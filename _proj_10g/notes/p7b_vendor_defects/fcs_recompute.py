#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fcs_recompute.py -- 独立复算 AMD 官方 `xxv_ethernet` example 图案发生器的 FCS 通路。

目的 (P7B 闸 2 §5.1 遗留的 U3):
  闸 2 只做了**长度论证** (CRC 覆盖 252 B vs 实际 244 B)，没有逐位复算。
  本脚本把厂商 RTL 的 gen_CRC_const() **逐位**在 Python 里复现，并与标准 zlib.crc32 对拍，
  把"厂商 example 插入的 FCS 与它自己发出的帧对不上"从【推定】升级为【复算】。

被复算的 RTL (三处副本逐字相同, 行号以 pristine 副本为准):
  文件 : _proj_10g/xxv_probe/pcs64_ex/pcs64_ex/imports/pcs64_pkt_gen_mon.v
  常量 : :997-1003   preamble / dest_addr / source_addr / length_type / eth_header
                     / CRC_POLYNOMIAL / init_crc
  参数 : :1007-1018  xfer_cnt / xfer_rmdr / crc_cnt / crc_rmdr / crc_insrt / crc_bits ...
  参数 : :1030-1032  PKT0_CRC = gen_CRC_const(pkt_len-4,1'b0)      <-- n = 256-4 = 252
  函数 : :1216-1226  gen_CRC_const()
  函数 : :1234-1235  crc_jiggle()
  函数 : :1237-1241  swapn()
  发帧 : :1078-1160  FSM (S3/S4/S5)          :1183-1195 end_packet
  顶层 : :494-585    FIXED_PACKET_LENGTH=256 -> .pkt_len(FIXED_PACKET_LENGTH)

"标准"参照系:
  以太网 FCS = CRC-32 (reflected, poly=0x04C11DB7, init=0xFFFFFFFF, xorout=0xFFFFFFFF,
  refin=true refout=true)，即 zlib.crc32() 的语义；FCS 四字节按 CRC 值的**小端**顺序上线。
  本脚本用 zlib.crc32 做 oracle (与厂商 RTL 无任何共同代码)。

用法: python fcs_recompute.py            (纯标准库; 输出同时存 fcs_recompute_out.txt)
"""

import sys
import zlib

try:                                    # Windows 控制台是 GBK, 直接打中文/箭头会炸
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# ---------------------------------------------------------------------------
# 0. 厂商 RTL 里的常量 (逐字抄自 pcs64_pkt_gen_mon.v:997-1003)
# ---------------------------------------------------------------------------
PREAMBLE    = 0xFB_55_55_55_55_55_55_D5   # 64 bit : /S/ + 6x55 + D5
DEST_ADDR   = 0xFF_FF_FF_FF_FF_FF         # 48 bit : broadcast
SOURCE_ADDR = 0x14_FE_B5_DD_9A_82         # 48 bit
LENGTH_TYPE = 0x0600                      # 16 bit
CRC_POLYNOMIAL = 0b100000100110000010001110110110111   # 33 bit (x^32 打头)
INIT_CRC = 0b11010111011110111101100110001011          # 32 bit (RTL 里只用它做 PRBS 种子)

# eth_header = {preamble, dest_addr, source_addr, length_type} -> 176 bit
ETH_HEADER = (PREAMBLE << 112) | (DEST_ADDR << 64) | (SOURCE_ADDR << 16) | LENGTH_TYPE

PKT_LEN   = 256            # FIXED_PACKET_LENGTH (xxv_loop_top.v:302 传 256)
XFER_CNT  = PKT_LEN // 8   # 32 个 XGMII 数据字
XFER_RMDR = PKT_LEN % 8    # 0
CRC_N     = PKT_LEN - 4    # 252  <-- 厂商用的 n
FCS_LEN   = 4

CRC32_RESIDUE = 0x2144DF1C  # 标准 CRC-32 的"整帧残差"常数 (外部已知量, 用于交叉确认)

# ---------------------------------------------------------------------------
# 1. 逐位复现厂商的 gen_CRC_const(n, const_bit)     (pcs64_pkt_gen_mon.v:1216-1226)
# ---------------------------------------------------------------------------
def crc_jiggle(d):
    """pcs64_pkt_gen_mon.v:1234-1235   crc_jiggle(d) = {d[31:3], ~d[2:0]}"""
    return ((d >> 3) << 3) | ((~d) & 0x7)


def gen_CRC_const(n, const_bit, header=ETH_HEADER):
    """逐位复现厂商的 CRC 计算, 返回 RTL 语义下的 32 位 op_crc。
    n = 覆盖的**字节**数; const_bit = i>111 之后逐位喂进去的常量比特。"""
    loc_poly = 0xFFFFFFFF
    for i in range(n * 8):                       # 循环次数是 n*8 (位)
        bit = (header >> crc_jiggle(111 - i)) & 1 if i <= 111 else const_bit
        cond = ((loc_poly >> 31) & 1) ^ bit
        loc_poly = ((CRC_POLYNOMIAL if cond else 0) ^ (loc_poly << 1)) & 0xFFFFFFFF
    # for(i=0;i<=31;i=i+1) gen_CRC_const[i] = ~loc_poly[{i[3+:2],~i[0+:3]}];
    out = 0
    for i in range(32):
        idx = ((i >> 3) << 3) | ((~i) & 0x7)
        if not ((loc_poly >> idx) & 1):
            out |= (1 << i)
    return out


# ---------------------------------------------------------------------------
# 2. 帧几何: 按发帧 FSM 逐拍复现真正上线的字节流
# ---------------------------------------------------------------------------
def tx_lanes(datain):
    """swapn(d): lane k = datain[63-8k -: 8]  (pcs64_pkt_gen_mon.v:1237-1241 + :1147)"""
    return bytes(((datain >> (8 * (7 - k))) & 0xFF) for k in range(8))


def sel(hi, lo):
    """Verilog 的降序 part-select  eth_header[hi-:n]  (hi 是**最高**位)"""
    return (ETH_HEADER >> lo) & ((1 << (hi - lo + 1)) - 1)


def packet_words(n_words=XFER_CNT, op_data=0):
    """复现 FSM (S3/S4/S5/end_packet) 发出的 n_words 个 XGMII 数据字。
    ⚠️ 只用它的"数据字内容"; end_packet 里被 FCS 顶掉的 lane4..7 由调用方补。
    op_data = d_sel=0 时 op_data = 64'h0 (assign data_select = 2'b0)。"""
    words = []
    hbc = 175                                    # S3 拍设的初值 (:1253)
    for _ in range(n_words):
        datain = op_data
        if (hbc >> 8) & 1 == 0:                  # header_bit_count[8]==0 -> 还有 header
            if hbc < 63:                         # tx_datain[63-:48] = eth_header[0+:48]
                datain = (op_data & 0xFFFF) | (sel(47, 0) << 16)
            else:                                # tx_datain = eth_header[hbc-:64]
                datain = sel(hbc, hbc - 63)
        words.append(tx_lanes(datain))
        hbc = hbc if (hbc >> 8) & 1 else (hbc - 64) & 0x1FF
    return b''.join(words)


def frame_geometry(n_words=XFER_CNT):
    """返回 (wire, frame, m)
    wire  = 全部 XGMII 数据字 (含 word0 的 /S/ 字)      = 256 B
    frame = 网卡按 DA 起算的帧 (含 FCS)                 = 248 B
    m     = 该被 FCS 保护的部分 (去掉 word0, 再去掉末尾 FCS) = 244 B"""
    wire = packet_words(n_words)
    frame = wire[8:]
    return wire, frame, frame[:-FCS_LEN]


# ---------------------------------------------------------------------------
# 3. 对拍
# ---------------------------------------------------------------------------
def hx(b):
    return ' '.join(f'{x:02X}' for x in b)


def main():
    out = []

    def p(s=''):
        print(s)
        out.append(s)

    wire, frame, m244 = frame_geometry()

    p('=' * 78)
    p('A. 帧几何 (由发帧 FSM 逐拍复现, 不是读注释)')
    p('=' * 78)
    p(f'pkt_len (FIXED_PACKET_LENGTH) = {PKT_LEN}   xfer_cnt = {XFER_CNT} 个 XGMII 字')
    p(f'FSM 实际发出 {len(wire)} 字节 = {XFER_CNT} 字 x 8')
    p(f'  word0     = /S/ + 6x55 + D5 (前导/SFD, c[0]=1)  = {hx(wire[0:8])}')
    p(f'  word1     = DA + SA[47:32]                       = {hx(wire[8:16])}')
    p(f'  word2     = SA[31:0] + type + payload[0:1]       = {hx(wire[16:24])}')
    p(f'  word3..30 = payload  (d_sel hardwired 0 -> 全 0)')
    p(f'  word31    = payload[0:3] (+ FCS 由 end_packet 顶掉 lane4..7; 本函数不含 FCS) = {hx(wire[248-8:248])}')
    p()
    p(f'上线的"帧"(网卡按 DA 起算, 含 FCS)      = {len(frame)} 字节')
    p(f'  ↳ 与闸 2 的网卡硬件计数 Δbytes/Δpackets = 248.000000 **逐字节吻合**')
    p(f'其中被 FCS 保护的部分 M244              = {len(m244)} 字节  (14 头 + 230 载荷)')
    p(f'厂商 RTL 实算的覆盖长度 CRC_N           = {CRC_N} 字节')
    p(f'  ↳ 差值 = {CRC_N - len(m244)} 字节 = word0 那个"前导+/S/"字')
    p(f'  ↳ 头 14 B 两边一致; 多算的 {CRC_N-len(m244)} B 全是 d_sel=0 的常量 0 比特')
    p()
    p('  ⭐ 几何的**外部确认**: P7B_GATE1.md:1085 记录了板级 XGMII 逐字 trace (该文件按')
    p('     d[63:0] 打印, 即 lane0 落在**最低**字节 = 我这三行的字节反转)。逐字比对:')
    p(f'      板级 word0 = 64\'hD5555555555555FB   vs 模型 bswap = '
      f'0x{int.from_bytes(wire[0:8], "little"):016X}  {int.from_bytes(wire[0:8], "little") == 0xD5555555555555FB}')
    p(f'      板级 word1 = 64\'hFE14FFFFFFFFFFFF   vs 模型 bswap = '
      f'0x{int.from_bytes(wire[8:16], "little"):016X}  {int.from_bytes(wire[8:16], "little") == 0xFE14FFFFFFFFFFFF}')
    p(f'      板级 word2 = 64\'h00000006829ADDB5   vs 模型 bswap = '
      f'0x{int.from_bytes(wire[16:24], "little"):016X}  {int.from_bytes(wire[16:24], "little") == 0x00000006829ADDB5}')
    p(f'      板级 "29 个全 0 字" (word3..word31)  vs 模型 = {len(wire[24:])//8} 个字, '
      f'全 0 ? {set(wire[24:]) == {0}}')
    p()

    p('=' * 78)
    p('B. 逐位复现 gen_CRC_const 并与 zlib.crc32 对拍')
    p('=' * 78)
    rtl_252 = gen_CRC_const(CRC_N, 0)     # 厂商参数: n = pkt_len-4 = 252
    rtl_244 = gen_CRC_const(244, 0)       # "本应如此": n = 244
    z_244 = zlib.crc32(m244)
    z_252 = zlib.crc32(m244 + b'\x00' * 8)

    def wire_fcs(v):
        """RTL 的 op_crc -> word31 lane4..7 的上线四字节 (end_packet: tmp_dat[0+:32]=op_crc,
        再 swapn 把 byte-reverse; 于是 lane4=OP[31:24] ... lane7=OP[7:0])"""
        return bytes([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])

    fcs_244 = wire_fcs(rtl_244)
    fcs_252 = wire_fcs(rtl_252)
    le = z_244.to_bytes(4, 'little')
    be = z_244.to_bytes(4, 'big')

    p(f'  zlib.crc32(M244)              = 0x{z_244:08X}   (标准 CRC-32 值)')
    p(f'  zlib.crc32(M244||0x00*8)      = 0x{z_252:08X}')
    p(f'  RTL gen_CRC_const(244, 0)     = 0x{rtl_244:08X}')
    p(f'  RTL gen_CRC_const(252, 0)     = 0x{rtl_252:08X}   (厂商参数 pkt_len-4)')
    p('  ⚠️ 两边的 **32 位整数**差一个字节序约定 (RTL 的 op_crc = 标准值的字节反转),')
    p('     所以对拍必须落在**上线的 4 个字节**上, 不能比整数 —— 见下。')
    p()
    p(f'  RTL(244) 上线序 (word31 lane4..7) = {hx(fcs_244)}')
    p(f'  RTL(252) 上线序 (word31 lane4..7) = {hx(fcs_252)}   <-- 厂商实际发出去的')
    p(f'  zlib(M244) 的 little-endian 4 字节 = {hx(le)}')
    p(f'  zlib(M244) 的 big-endian 4 字节    = {hx(be)}')
    p()
    p(f'  [判据 1] RTL(244) 上线序 == le(zlib(M244))            ? {fcs_244 == le}')
    p(f'  [判据 2] RTL(252) 上线序 == le(zlib(M244 || 8 个 0))  ? '
      f'{fcs_252 == z_252.to_bytes(4, "little")}')
    p('  => 判据 1 把"RTL 模型"钉死在标准 CRC-32 上 (模型可信, 非自说自话);')
    p('     判据 2 说明厂商的 252 恰好 = "正确的 244 后面又追加 8 个 0 字节"。')
    p(f'  [判据 3] FCS 上线序 == 小端 (802.3 约定) ? {fcs_244 == le}   (== 大端 ? {fcs_244 == be})')
    p()

    p('=' * 78)
    p('C. 网卡看到了什么 (收到帧按 802.3 clause 3.2.9 校验)')
    p('=' * 78)
    res_correct = zlib.crc32(m244 + le)
    res_vendor = zlib.crc32(m244 + fcs_252)
    p(f'  正确 FCS 四字节        = {hx(le)}')
    p(f'  厂商插入的 FCS 四字节  = {hx(fcs_252)}'
      f'   (与正确值{"相同" if fcs_252 == le else "不同"})')
    p(f'  crc32(M244 || 正确 FCS) = 0x{res_correct:08X}')
    p(f'  crc32(M244 || 厂商 FCS) = 0x{res_vendor:08X}')
    p(f'  [判据 4] 正确 FCS 的残差 == 标准常数 0x{CRC32_RESIDUE:08X} ? '
      f'{res_correct == CRC32_RESIDUE}   (外部已知量, 独立确认)')
    p(f'  [判据 5] 厂商 FCS 的残差 == 0x{CRC32_RESIDUE:08X} (网卡判 good 的条件) ? '
      f'{res_vendor == CRC32_RESIDUE}')
    p()
    p('  => 每一帧都会被任何 802.3 接收器判 FCS 错 (残差对不上);')
    p('     与闸 2 实测 port_rx_good=0 / rx_eth_crc_err≈100% 方向一致。')
    p('     随机帧被误判 good 的概率 ~2^-32 ⇒ 10.2e8 帧里期望 ~0.24 帧, 可忽略。')
    p()

    p('=' * 78)
    p('D. 与闸 2 实测的逐档对账 (解释了"差分负对照没有按期望翻转")')
    p('=' * 78)
    p('  闸 2 §5 的 C-3: crc_en=0 与 crc_en=1 两档, rx_eth_crc_err 都没有变好,')
    p('  port_rx_good 两档都是 0。本模型给出两档的**同一结论**:')
    p()
    p(f'  (a) insert_crc=0 (厂商 example 出厂值, `assign insert_crc = 1\'b0` @ :186)')
    p(f'      => word31 的 lane4..7 = op_data = 00 00 00 00  (FCS 字段恒为 0)')
    p(f'      残差 crc32(M244 || 00 00 00 00) = 0x{zlib.crc32(m244 + bytes(4)):08X}'
      f'   == 0x{CRC32_RESIDUE:08X} ? {zlib.crc32(m244 + bytes(4)) == CRC32_RESIDUE}')
    p(f'  (b) insert_crc=1 (闸 2 的 v2 把它接成 VIO 可控)')
    p(f'      => word31 的 lane4..7 = {hx(fcs_252)}  (覆盖 {CRC_N} B, 见 B 节)')
    p(f'      残差 = 0x{res_vendor:08X}   == 0x{CRC32_RESIDUE:08X} ? {res_vendor == CRC32_RESIDUE}')
    p(f'  (c) 假想的"修好了"档 (覆盖 244 B)')
    p(f'      => word31 的 lane4..7 = {hx(le)}')
    p(f'      残差 = 0x{res_correct:08X}   == 0x{CRC32_RESIDUE:08X} ? {res_correct == CRC32_RESIDUE}')
    p()
    p('  => (a)(b) 都判坏, 只有 (c) 判好 ⇒ 与闸 2 实测的"两档都 100% 坏"完全一致。')
    p()

    p('=' * 78)
    p('D2. 差异的另一种表述 (便于交叉核对)')
    p('=' * 78)
    p(f'  厂商插入的 FCS = CRC32(M244 || 0x00 x 8)  (不是 CRC32(M244))')
    p(f'  即: 覆盖长度用 pkt_len-4 ({CRC_N}) 而不是 (pkt_len-8)-4 = {PKT_LEN-12}')
    p()

    p('=' * 78)
    p('E. 最小修复 (仅陈述, 本任务不改厂商源码)')
    p('=' * 78)
    p(f'  :1030-1032  gen_CRC_const(pkt_len-4, ...)  ->  gen_CRC_const(pkt_len-12, ...)')
    p(f'              三个 n 都要改 (PKT0/PKT1/PKT3 对应 d_sel=0/1/PRBS 三条通路)')
    p(f'              即 CRC_N: {CRC_N} -> {PKT_LEN-12}   (减去 word0 的 8 字节)')
    p('  ⚠️ 闸 1 的板级证据来自**未改一行**的官方 example ⇒ 改它会让"原件可复现性"变差。')

    with open('fcs_recompute_out.txt', 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    print()
    print('[输出已存 fcs_recompute_out.txt]')


if __name__ == '__main__':
    main()
