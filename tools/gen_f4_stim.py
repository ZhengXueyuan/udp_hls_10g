#!/usr/bin/env python
"""F4 缺陷门刺激生成 (mac_rx_64 的 FIFO 溢出/截断角落)。

产出 (写到给定目录):
  f4_data.memh / f4_dv.memh / f4_er.memh  GMII 字节流 (1 字节/拍 @125MHz)
  f4_wr.memh    每拍的 m_axis_tready 计划值 (1=收, 0=停) —— 与字节流同索引
  f4_cases.txt  每例一行: name i_start i_stop stall_from stall_to nframes payload_bytes

每例结构: [触发帧][跟随帧A][跟随帧B] + 12 字节 IFG + 400 拍空闲 (让 FIFO 排空、计数器稳定)。
触发帧配不同的 tready 停窗, 用来命中 mac_rx_64 的两条缺陷支:
  (a) 帧中丢帧 (S_DATA 的 bcnt==7 && hwv && fifo 满) -> 已推字变成孤儿字 (有 popc 无 TLAST)
  (b) 帧尾决策拍读 full=0 (7/8) 但同拍在飞写把 wptr 顶满 -> 下一拍写被静默丢弃 (TLAST 丢)
FCS = zlib.crc32 小端 (与 tools/gen_stim_mac.py 同一口径, 线上 LSB-first)。
"""
import os
import struct
import sys
import zlib

DST = bytes([0xFF] * 6)
SRC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
PRE = bytes([0x55] * 7) + bytes([0xD5])
IFG = bytes([0x07] * 12)
GAP = 400          # 例间空闲拍 (tready 拉高, 让 FIFO 排空)
IPV4_UDP = b"\x08\x00"      # 只是字节模式; 路由由 rx_classify 按字节判, 与 mac 门无关


def eth_fcs(p):
    return struct.pack('<I', zlib.crc32(p) & 0xFFFFFFFF)


def pad_payload(n):
    """链路层净荷, 总长**恰为 n** (不含 FCS), n ∈ [0, 64]。

    ⚠️ 旧版写成 `14B 头 + body` 且 n<14 时 body 为空 ⇒ 实际净荷恒 >= 14:
    L=0..13 的请求全部退化成 14 ⇒ **G=0 (净荷 <8) 与 G=1 的短帧落点一个都没覆盖到**
    (F4-2 缺陷正是藏在"净荷 8..15"这一支里)。现在按 n 截断, n<14 时头被截短 ——
    单元门只关心长度 (内容无意义), 绝不为了凑以太网布局而丢掉长度覆盖。"""
    p = DST + SRC + IPV4_UDP + bytes(((i * 29 + 7) & 0xFF) for i in range(64))
    return p[:n]


def mk_frame(n):
    p = pad_payload(n)
    return PRE + p + eth_fcs(p)


def cases():
    """(name, [触发帧净荷长, 跟随A, 跟随B], stall_from, stall_to) — 索引相对例起点。"""
    c = []
    # 对照: 不 stall
    c.append(("ctl",      [60, 200, 72], None, None))
    # (b) 帧尾丢 TLAST: 9 字帧 (净荷 72 = 9x8), 消费者从很早就停
    c.append(("b72_e8",   [72, 60, 60],  8,   400))
    c.append(("b72_e12",  [72, 60, 60],  12,  400))
    c.append(("b72_e20",  [72, 60, 60],  20,  400))
    # (b) 8 字帧 (净荷 64)
    c.append(("b64_e8",   [64, 60, 60],  8,   400))
    # (b) 10 字帧: 净荷 76 -> 9 整字 + 4B 尾字 (走 S_FLUSH)
    c.append(("b76_e10",  [76, 60, 60],  10,  400))
    # (a) 帧中丢帧: 长帧 + 早停 -> FIFO 满发生在帧中
    c.append(("a200_e16", [200, 60, 60], 16,  260))
    c.append(("a200_e24", [200, 60, 60], 24,  260))
    c.append(("a200_e32", [200, 60, 60], 32,  260))
    # (a) 停窗在帧中释放 (测试恢复路径)
    c.append(("a200_r100", [200, 60, 60], 16, 100))
    c.append(("a200_r140", [200, 60, 60], 16, 140))
    # 深丢: 1500B 帧 + 停窗覆盖整帧
    c.append(("a1500",    [1500, 60, 60], 16, 2200))
    # 停窗跨到例间空隙 (恢复发生在触发帧之后的跟随帧上)
    c.append(("a200_x",   [200, 60, 60], 16, 900))
    # ---- 帧长扫描 (0..64): 覆盖 G=0/G=1 全部落点 (短帧帧尾那一支) ----
    # 触发结构: [填充帧 200B (把 FIFO 灌到 8/8, 自身完整交付)] [短帧 L] [跟随帧 60B]
    #   填充帧线长 = 8+204 = 212 拍; IFG 12; 短帧段长 = 12+L; IFG 12; 跟随帧 72 拍。
    #   stall = [148-k, 236+L+6): 覆盖短帧帧尾那拍 (此时 FIFO 满、消费者不动),
    #   并在跟随帧前导 (248+L) 之前 6 拍释放 ⇒ 差别只来自"短帧帧尾那一支怎么走"。
    for L in range(0, 65):
        ks = [0, 8, 16, 24] if L <= 20 else [8]
        for k in ks:
            c.append(("sw_L%02d_k%02d" % (L, k), [200, L, 60], 148 - k, 236 + L + 6))
    # ---- 相位细扫组: 稳定造出 "帧字与 TERM 抢同一拍" (TERM 优先门 push_frame_ok 的判别用例) ----
    # 机理: 填充帧 (200B) 帧中丢 -> term_pend=1 且 FIFO 满; 之后帧 B 的**第 2 个字完成**
    #   那一拍若正好是"停窗释放后第一个 push_ok=1"的拍, 则:
    #     修复版  : push_frame_ok = push_ok && !term_pend = 0 -> 帧 B 整帧丢 (零推入),
    #               TERM 独占该拍 -> 流里 TERM 排在下一个 SOP 之前 (L4 成立);
    #     nogate  : push_frame_ok = push_ok = 1 -> 帧 B 的字 push 与 term_fire 同拍,
    #               同拍赋值后者被 case 覆盖 -> **TERM 静默丢失 + 帧 B 的 SOP 裸奔** (L4/L1/L2/L3/L7 全破)。
    # 相位: 帧 B 净荷首字节在例内 232 (=224 前导 8 字节 + 24B 净荷), 第 2 字完成在净荷
    #   第 20 字节 => 例内 ~251 拍 (fbytes=20); 停窗释放点扫 247..254 (8 个偏移) 覆盖该拍。
    #   净荷固定 24B (>=14, 且 3 个字 => 第 2 字必然存在)。
    # 碰撞窗**只有 1 拍宽** (修复版: term_pend 在第一个 push_ok 拍就被清 ⇒ 只有
    #   "帧 B 的字完成拍 == 停窗释放后第一个读拍" 这一拍能撞上), 故必须 1 拍分辨率扫描:
    #   实测布局 (f4_dv.memh) = 帧 B (24B) 前导起点 例内 102 ⇒ 第 2 字完成 ~129;
    #   扫 108..147 (40 个偏移, 步长 1) 覆盖该拍 ±20。
    for ph in range(108, 148):
        c.append(("ph_%03d" % ph, [200, 24, 60], 16, ph))
    # 实测校正组: 从 f4_dv.memh 量出的真实布局是 [200B 帧][24B 帧起点=例内 102][60B 帧=150],
    #   即 24B 帧的第 2 字完成 ≈ 例内 102+27 = 129 (前导 8 + 净荷 19) ⇒ 释放点扫 118..132
    #   (步长 2, 8 个偏移), 覆盖该拍 ±6 拍。
    # 停摆终态例 (**必须最后, 且后面不留空隙**): 配 TB 的 +NODRAIN 观察
    # "最后一个 SOP 等不到 TLAST" (空隙里 tready=1 会把 TERM 送出去, 就看不到终态了)
    c.append(("nodrain", [200, 60, 60], 40, 99999))
    return c


def build():
    data, dv, er, wr = [], [], [], []
    meta = []
    for name, lens, sfrom, sto in cases():
        i0 = len(data)
        for n in lens:
            seg = mk_frame(n)
            data += list(seg)
            dv += [1] * len(seg)
            er += [0] * len(seg)
            data += list(IFG)             # 每帧后接 IFG (12 拍 dv=0)
            dv += [0] * len(IFG)
            er += [0] * len(IFG)
        i1 = len(data)                    # stall 窗按激励长度截断
        for k in range(i0, i1):
            off = k - i0
            wr.append(0 if (sfrom is not None and sfrom <= off < sto) else 1)
        if sto is None or sto < 10000:     # 无限停窗例后面不留空隙
            data += [0x07] * GAP
            dv += [0] * GAP
            er += [0] * GAP
            wr += [1] * GAP
        i1 = len(data)                    # 例边界 = 空隙末 (= 排空后再快照)
        meta.append((name, i0, i1, -1 if sfrom is None else sfrom,
                     -1 if sto is None else sto, len(lens), sum(lens)))
    return data, dv, er, wr, meta


def main(outdir):
    data, dv, er, wr, meta = build()
    os.makedirs(outdir, exist_ok=True)

    def w(fn, rows, fmt):
        with open(os.path.join(outdir, fn), "w") as fh:
            fh.write("\n".join(fmt % r for r in rows) + "\n")

    w("f4_data.memh", data, "%02X")
    w("f4_dv.memh",   dv,   "%d")
    w("f4_er.memh",   er,   "%d")
    w("f4_wr.memh",   wr,   "%d")
    with open(os.path.join(outdir, "f4_cases.txt"), "w") as fh:
        for m in meta:
            fh.write("%s %d %d %d %d %d %d\n" % m)
    n_nostall = sum(1 for m in meta if m[3] < 0)
    # 帧长覆盖表 (触发帧 = 每例除最后一帧? 不: 这里只统计"扫描例"的短帧长度)
    cov = {}
    for name, lens, sfrom, sto in cases():
        if name.startswith("sw_"):
            L = int(name[4:6])
            cov[L] = cov.get(L, 0) + 1
    miss = [L for L in range(0, 65) if L not in cov]
    print("gen_f4_stim: %d 例 / %d 拍 / %d 例无 stall -> %s" %
          (len(meta), len(data), n_nostall, outdir))
    print("  帧长覆盖 0..64: %d/65 种 (缺 %s)" % (len(cov), miss if miss else "无"))
    print("  每种长度例数: " + ", ".join("L%02d×%d" % (L, cov[L]) for L in sorted(cov)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "sim/f4sim")
