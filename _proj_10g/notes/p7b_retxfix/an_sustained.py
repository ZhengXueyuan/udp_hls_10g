#!/usr/bin/env python3
# an_sustained.py -- P7B-RETXFIX: 从下行 pcap 提取**建连后稳态载荷速率** (目标口径)。
#
# 背景 (用户 2026-10-08 裁定): ~10G 目标是"正常连接建立以后处理数据的速度",
#   不含建连/控制开销; "发 1 MB 就断开"的 30 连台架 = 鲁棒性/兜底口径。
#   本脚本给出目标口径读数: 每条连接**修好初始洞之后**的载荷速率
#   (= 无停摆连取全程; 有停摆连取"最后一个洞结束 -> 最后一个数据帧")。
#
# 用法: python an_sustained.py RXM.pcap [RXV.pcap ...]
#   依赖: tshark (C:/Program Files/Wireshark/tshark.exe)；板帧按 ack 字段 == 该连
#   对端 ISN+1 分流 (板侧 ISN 全连相同 0x12345678)。
import subprocess
import sys
import statistics

TSH = "C:/Program Files/Wireshark/tshark.exe"
STALL_S = 0.003          # 停摆判定阈值 (r5/r6 量子 = 20 ms; 3 ms 足以分辨)


def frames(pcap):
    out = subprocess.run(
        [TSH, "-r", pcap, "-T", "fields", "-E", "separator=;",
         "-e", "frame.time_relative", "-e", "ip.src", "-e", "tcp.srcport",
         "-e", "tcp.seq_raw", "-e", "tcp.ack_raw", "-e", "tcp.len"],
        capture_output=True, text=True, errors="replace").stdout
    rows = []
    for ln in out.splitlines():
        p = ln.rstrip("\n").split(";")
        if len(p) >= 6:
            try:
                # ⚠️ 纯 SYN 帧的 ack/len 字段在 tshark 里可能是空串 (不是 0)
                rows.append(dict(t=float(p[0]), src=p[1], sport=p[2],
                                 seq=int(p[3] or 0), ack=int(p[4] or 0),
                                 ln=int(p[5] or 0)))
            except ValueError:
                pass
    return rows


def main():
    print(f"{'conn':>6} {'dataB':>9} {'gaps':>4} {'sustB':>9} {'sustMS':>8} "
          f"{'sustMbps':>9} {'wholeMbps':>10}")
    allsust = []
    for pcap in sys.argv[1:]:
        rows = frames(pcap)
        peers = {}
        for r in rows:
            if r["src"] == "192.168.100.100" and r["ln"] == 0 and r["ack"] == 0:
                peers.setdefault(r["sport"], r["seq"])   # SYN: peer ISN
        print(f"== {pcap} (peers={len(peers)}) ==")
        for P, isn in sorted(peers.items(), key=lambda x: x[1]):
            conn_ack = isn + 1
            b = sorted([r for r in rows if r["src"] == "192.168.100.2"
                        and r["ack"] == conn_ack and r["ln"] > 0], key=lambda r: r["t"])
            if not b:
                continue
            total = sum(r["ln"] for r in b)
            t0, t1 = b[0]["t"], b[-1]["t"]
            # 停摆 (相邻板帧间隔 > 阈值); 稳态 = 最后一个停摆结束 -> t1
            gaps = []
            for i in range(1, len(b)):
                if b[i]["t"] - b[i - 1]["t"] > STALL_S:
                    gaps.append(i)
            if gaps:
                gi = gaps[-1]
                sust_bytes = sum(r["ln"] for r in b[gi:])
                sust_ms = (t1 - b[gi]["t"]) * 1e3
            else:
                sust_bytes = total
                sust_ms = (t1 - t0) * 1e3
            rate = sust_bytes * 8 / max(sust_ms, 1e-9) / 1e3      # Mbps
            whole = total * 8 / max((t1 - t0) * 1e3, 1e-9) / 1e3
            allsust.append(rate)
            print(f"{P:>6} {total:>9} {len(gaps):>4} {sust_bytes:>9} {sust_ms:>8.3f} "
                  f"{rate:>9.1f} {whole:>10.1f}")
    if allsust:
        print(f"\n全连稳态载荷速率: min={min(allsust):.1f} med={statistics.median(allsust):.1f} "
              f"mean={statistics.mean(allsust):.1f} max={max(allsust):.1f} Mbps (n={len(allsust)})")


if __name__ == "__main__":
    main()
