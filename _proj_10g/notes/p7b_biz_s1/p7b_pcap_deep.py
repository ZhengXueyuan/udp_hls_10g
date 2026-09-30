#!/usr/bin/env python3
"""p7b_pcap_deep.py -- **流式** pcap 深析 (修正 plan 版工具的载荷切片缺陷)

为什么不用 p7b_pcap_check.py (它给的是假读数):
  它的 `pay = d[t + doff : t + ihl + (tot - ihl)]` 端点算成 `t + tot` (应为 `off + tot`)
  => 越界 ~20 B, 靠 Python 切片**钳位**掩盖: 数据帧恰好仍得 1460 (缓冲 1514),
     但**纯 ACK/FIN 帧**(缓冲 60 B) 被切片成 6 B / 2 B 的**幻影载荷**
     => 同一 4 元组里的 ACK 帧会以幻影字节污染 seq 重建流
     => 它给出 `PCHK_MISMATCH first=0` 的**假红** (socket 口径是干净的 -1)。
  本脚本按 IP 头字段**算**载荷长度 (`tot - ihl - doff`), 不切片钳位; 全程流式, 不驻留 pcap。

输出 (全部 PCHK_ 前缀):
  PCHK_*_HIST   几何 (载荷长度 / ip_tot) —— 来自 IP/TCP 头字段, 不来自切片
  PCHK_RETX     重传 = 同一 (flow, seq) 出现 >1 次的数据帧计数
  PCHK_GAPS     seq 空洞 (真正丢段)
  PCHK_FLOW     每个 flow 的账: 帧数 / 数据帧 / 纯ACK / 重复seq / 载荷字节
  PCHK_MISMATCH 最大 flow 的逐字节复算 (修正版)
用法: python3 p7b_pcap_deep.py --pcap F [--host H --port P] [--top N]
"""
import argparse
import struct
import sys

SEED = 0x9E3779B97F4A7C15
M64 = (1 << 64) - 1


def xs_next(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def iter_pcap(path):
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
            raise SystemExit("short pcap header")
        magic = struct.unpack("<I", gh[:4])[0]
        if magic in (0xA1B2C3D4, 0xA1B23C4D):
            endian = "<"
            nano = (magic == 0xA1B23C4D)
        elif magic in (0xD4C3B2A1, 0x4D3CB2A1):
            endian = ">"
            nano = (magic == 0x4D3CB2A1)
        else:
            raise SystemExit("bad pcap magic 0x%08X" % magic)
        while True:
            ph = f.read(16)
            if len(ph) < 16:
                return
            ts, tu, incl, orig = struct.unpack(endian + "IIII", ph)
            d = f.read(incl)
            if len(d) < incl:
                return
            yield ts + (tu / 1e9 if nano else tu / 1e6), d


def parse(d):
    """-> dict 或 None; 载荷长度来自头字段 (不切片钳位)"""
    if len(d) < 14:
        return None
    eth = struct.unpack("!H", d[12:14])[0]
    off = 14
    while eth in (0x8100, 0x88A8):
        if len(d) < off + 4:
            return None
        eth = struct.unpack("!H", d[off + 2:off + 4])[0]
        off += 4
    if eth != 0x0800 or len(d) < off + 20:
        return None
    ihl = (d[off] & 0x0F) * 4
    proto = d[off + 9]
    tot = struct.unpack("!H", d[off + 2:off + 4])[0]
    src = ".".join(str(b) for b in d[off + 12:off + 16])
    dst = ".".join(str(b) for b in d[off + 16:off + 20])
    r = dict(proto=proto, tot=tot, ihl=ihl, src=src, dst=dst, off=off)
    if proto != 6 or len(d) < off + ihl + 20:
        return r
    t = off + ihl
    r["sport"], r["dport"] = struct.unpack("!HH", d[t:t + 4])
    r["seq"] = struct.unpack("!I", d[t + 4:t + 8])[0]
    r["flags"] = d[t + 13]
    doff = (d[t + 12] >> 4) * 4
    r["doff"] = doff
    r["plen"] = tot - ihl - doff
    r["pay_at"] = t + doff
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcap", required=True)
    ap.add_argument("--host", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--dir", choices=["down", "up"], default="down")
    ap.add_argument("--top", type=int, default=3, help="逐字节复算的最大 N 条 flow")
    a = ap.parse_args()

    hist_plen, hist_tot = {}, {}
    flows = {}          # key -> dict(frames,data,ack,plen_sum,seqs{seq:plen},dup,first_ts,last_ts)
    npk = 0
    for ts, d in iter_pcap(a.pcap):
        npk += 1
        r = parse(d)
        if not r or r["proto"] != 6:
            continue
        if a.dir == "down":
            if r["src"] != a.host or r["sport"] != a.port:
                continue
        else:
            if r["dst"] != a.host or r["dport"] != a.port:
                continue
        key = (r["src"], r["sport"], r["dst"], r["dport"])
        fl = flows.setdefault(key, dict(frames=0, data=0, ack=0, plen_sum=0,
                                        seqs={}, dup=0, first=ts, last=ts))
        fl["frames"] += 1
        fl["first"] = min(fl["first"], ts)
        fl["last"] = max(fl["last"], ts)
        hist_tot[r["tot"]] = hist_tot.get(r["tot"], 0) + 1
        if r["plen"] > 0:
            fl["data"] += 1
            fl["plen_sum"] += r["plen"]
            hist_plen[r["plen"]] = hist_plen.get(r["plen"], 0) + 1
            if r["seq"] in fl["seqs"]:
                fl["dup"] += 1
            else:
                fl["seqs"][r["seq"]] = (r["plen"], ts, d[r["pay_at"]:r["pay_at"] + r["plen"]])
        else:
            fl["ack"] += 1

    print("PCHK_PKTS %d" % npk)
    print("PCHK_PLEN_HIST %s  (数据帧载荷字节 -> 帧数; 权威来源 = IP 头字段)" %
          sorted(hist_plen.items(), key=lambda kv: -kv[1]))
    print("PCHK_IPTOT_HIST %s" % sorted(hist_tot.items(), key=lambda kv: -kv[1]))
    print("PCHK_FLOWS %d" % len(flows))
    tot_data = sum(f["data"] for f in flows.values())
    tot_ack = sum(f["ack"] for f in flows.values())
    tot_dup = sum(f["dup"] for f in flows.values())
    tot_plen = sum(f["plen_sum"] for f in flows.values())
    print("PCHK_TOTAL frames=%d data=%d pureack=%d dupseq=%d payload_bytes=%d"
          % (sum(f["frames"] for f in flows.values()), tot_data, tot_ack, tot_dup, tot_plen))
    if flows:
        k0 = next(iter(flows))
        f0 = flows[k0]
        g = sorted(f["data"] for f in flows.values())
        print("PCHK_DATA_PER_FLOW min=%d max=%d median=%d" % (g[0], g[-1], g[len(g) // 2]))
        print("PCHK_DUP_PER_FLOW sum=%d over %d flows (mean %.3f)"
              % (tot_dup, len(flows), tot_dup / len(flows)))

    # ---- 逐字节复算 (取载荷字节数最大的 top N 条 flow) ----
    order = sorted(flows.items(), key=lambda kv: -kv[1]["plen_sum"])[:a.top]
    for key, fl in order:
        if not fl["seqs"]:
            continue
        segs = fl["seqs"]
        base = min(segs)
        # 真实数据起点 = 第一个数据段; SYN 不在此表 (plen==0)
        stream = bytearray()
        nxt = base
        gaps = 0
        gap_bytes = 0
        out_of_order = 0
        for s in sorted(segs):
            plen, _, pay = segs[s]
            if s < nxt:
                out_of_order += 1
                continue
            if s > nxt:
                gaps += 1
                gap_bytes += s - nxt
            stream += pay
            nxt = s + plen
        st = SEED
        first = -1
        mis = 0
        for i, b in enumerate(stream):
            if ((st >> 24) & 0xFF) != b:
                mis += 1
                if first < 0:
                    first = i
            st = xs_next(st)
        print("PCHK_FLOW %s:%d -> %s:%d frames=%d data=%d ack=%d dupseq=%d "
              "payload=%d uniq_bytes=%d segs=%d gaps=%d gap_bytes=%d ooo=%d "
              "first_mismatch=%d mism_bytes=%d"
              % (key[0], key[1], key[2], key[3], fl["frames"], fl["data"], fl["ack"],
                 fl["dup"], fl["plen_sum"], len(stream), len(segs), gaps, gap_bytes,
                 out_of_order, first, mis))
        if first == -1 and gaps == 0 and fl["dup"] == 0:
            verdict = "CLEAN"
        elif fl["dup"] > 0 and first == -1 and gaps == 0:
            verdict = "CLEAN_WITH_RETX (重传但流完整)"
        else:
            verdict = "BAD"
        print("PCHK_FLOW_VERDICT port=%d %s" % (key[1], verdict))
    print("PCHK_DONE")


if __name__ == "__main__":
    main()
