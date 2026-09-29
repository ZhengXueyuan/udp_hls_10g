#!/usr/bin/env python
"""F4 下游判别实验刺激: 慢路径失聪假设检验 (mac_rx_64 -> vlan_strip -> rx_classify ->
slow_rx_adp -> HLS 模型 / fast 侧监视器)。

每例: [触发帧 (被 stall 打成 F4(a)/(b) 截断)] + 6 个跟随帧 (慢/快交替) + IFG + 空隙。
判据: 一次截断事件会造成**几个**后续帧丢失/错路, 以及是否**立刻自愈**。
若损失有界 (≤2 帧且下一帧即恢复) ⇒ 不能解释"慢路径失聪 ~20 分钟"。

帧标记: 净荷 byte20 = tag (0..255), 交付流里从 word2 的 bit[47:40] 读出。
路由: etype@byte12-13 (0x0806 ARP/0x0800 IP), proto@byte23 (1=ICMP,6=TCP),
      flags@byte47 (0x10=纯 ACK -> fast; SYN/FIN/RST -> slow)。
产出 (写到给定目录): f5_data/dv/er/wr.memh + f5_frames.txt (tag kind i0 i1) + f5_wr.memh
"""
import os
import struct
import sys
import zlib

DST = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
SRC = bytes([0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0])
PRE = bytes([0x55] * 7) + bytes([0xD5])
IFG = bytes([0x07] * 12)
GAP = 600


def eth_fcs(p):
    return struct.pack('<I', zlib.crc32(p) & 0xFFFFFFFF)


def mk(kind, n, tag):
    """净荷长 n (不含 FCS), tag 写在 byte20; 返回线上字节 (前导+净荷+FCS)。"""
    if kind == "ARP":
        et = b"\x08\x06"
    elif kind in ("ICMP", "TCP"):
        et = b"\x08\x00"
    else:
        raise ValueError(kind)
    body = bytearray(n - 14)
    for i in range(len(body)):
        body[i] = (i * 31 + tag * 7 + 5) & 0xFF
    p = bytearray(DST + SRC + et + bytes(body))
    p[20] = tag & 0xFF
    if kind == "ICMP":
        p[23] = 1
    elif kind == "TCP":
        p[23] = 6
        if n > 48:
            p[47] = 0x10          # 纯 ACK -> fast
    return PRE + bytes(p) + eth_fcs(bytes(p))


def cases():
    """(name, [(kind, payload_len, tag)...], stall_from, stall_to) — 索引相对例起点。"""
    c = []
    # 每例: 触发帧 + 6 跟随帧 (ARP/ICMP = 慢, TCP = fast)
    def follow(t0):
        return [("ARP", 60, t0), ("TCP", 100, t0 + 1), ("ICMP", 74, t0 + 2),
                ("TCP", 100, t0 + 3), ("ARP", 60, t0 + 4), ("ICMP", 74, t0 + 5)]
    # C1 基线: 无截断 (三帧慢 + 三帧混合)
    c.append(("base", [("ARP", 60, 1), ("ICMP", 74, 2), ("TCP", 100, 3),
                       ("ARP", 60, 4), ("TCP", 100, 5), ("ICMP", 74, 6)], None, None))
    # ⚠️ stall 窗只覆盖**触发帧自身**的传输期 (108B 帧 ~ 96 拍 / 220B 帧 ~ 228 拍),
    #    到触发帧结束即释放 —— 否则跟随帧也落进停窗, 损失会混入"消费者停 ⇒ 正常丢帧"
    #    (那是设计合同允许的, 不是 F4 的效应), 无法归因。
    # C2 触发帧 = 慢 (ARP, 72B = 9 字) 被打成 F4(b) (帧尾字丢) -> 跟随帧 11..16
    #    (108B 帧 = 84 拍, 跟随帧前导在 96 拍 -> 停窗 90 收)
    c.append(("trig_slow_b", [("ARP", 72, 10)] + follow(11), 8, 90))
    # C3 触发帧 = 慢 (ICMP, 200B) 帧中丢 (F4(a), 孤儿字) -> 跟随帧 21..26
    #    (212B 帧 = 212 拍, 帧中丢发生在 ~93 拍; 停窗 120 收, 远早于跟随帧前导 224)
    c.append(("trig_slow_a", [("ICMP", 200, 20)] + follow(21), 16, 120))
    # C4 触发帧 = fast (TCP, 72B) 帧尾丢 -> 跟随帧 31..36 (第 1 跟随帧是慢帧: 看错路)
    c.append(("trig_fast_b", [("TCP", 72, 30)] + follow(31), 8, 90))
    # C5 触发帧 = fast (TCP, 200B) 帧中丢 -> 跟随帧 41..46
    c.append(("trig_fast_a", [("TCP", 200, 40)] + follow(41), 16, 120))
    # C6 TERM 等空间路径: 停窗放到帧尾之后、跟随帧前导之前 (215 < 224) -> TERM 等 ~95 拍
    c.append(("wait_term", [("ICMP", 200, 50)] + follow(51), 16, 215))
    # C7 消费者停到下一帧前导 (260 > 224): 该跟随帧被"牺牲"(设计合同允许的丢帧, 有计数)
    c.append(("stall_into_next", [("ICMP", 200, 60)] + follow(61), 16, 260))
    return c


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    data, dv, er, wr, frames = [], [], [], [], []
    for name, fl, sfrom, sto in cases():
        i0 = len(data)
        for kind, n, tag in fl:
            seg = mk(kind, n, tag)
            b0 = len(data)
            data += list(seg)
            dv += [1] * len(seg)
            er += [0] * len(seg)
            frames.append((tag, kind, n, name, b0))
            data += list(IFG)
            dv += [0] * len(IFG)
            er += [0] * len(IFG)
        i1 = len(data)
        for k in range(i0, i1):
            off = k - i0
            wr.append(0 if (sfrom is not None and sfrom <= off < sto) else 1)
        data += [0x07] * GAP
        dv += [0] * GAP
        er += [0] * GAP
        wr += [1] * GAP

    def w(fn, rows, fmt):
        with open(os.path.join(outdir, fn), "w") as fh:
            fh.write("\n".join(fmt % r for r in rows) + "\n")

    w("f5_data.memh", data, "%02X")
    w("f5_dv.memh", dv, "%d")
    w("f5_er.memh", er, "%d")
    w("f5_wr.memh", wr, "%d")
    with open(os.path.join(outdir, "f5_frames.txt"), "w") as fh:
        for tag, kind, n, name, b0 in frames:
            kk = {"ARP": 0, "ICMP": 1, "TCP": 2}[kind]
            route = 2 if kind == "TCP" else 1
            fh.write("%d %d %d %d %d\n" % (tag, kk, n, b0, route))
    print("gen_f4_chain: %d 帧 / %d 拍 -> %s" % (len(frames), len(data), outdir))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "sim/f4chain")
