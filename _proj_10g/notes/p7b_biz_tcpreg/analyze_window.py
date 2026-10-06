#!/usr/bin/env python3
"""analyze_window.py -- TCP 上行 A/B 的窗口轨迹分析 (Windows 侧, 用 tshark)。

判据核心 (本轮设计):
  板通告的接收右沿 redge_est = ack_raw + (win_raw << wscale)。
  · 若 **redge_est 在板上行数据被 ACK 期间恒定** ⇒ 信用**没有回收** (右沿冻结,
    窗口只是随 rcv_nxt 前进而被动变小) —— 这是"信用不回收"的**直接判据**。
  · 若 redge_est 随消费阶梯上升 ⇒ 信用在回收 (则退化在别处, 如回收太慢/被饿死)。
用法:
  python analyze_window.py <pcap> [--board-ip 192.168.100.2] [--port 8080] [--csv out.csv]
"""
import argparse
import csv
import re
import subprocess
import sys

TSHARK = r"C:\Program Files\Wireshark\tshark.exe"

FIELDS = [
    "frame.time_relative", "ip.src", "ip.dst", "tcp.srcport", "tcp.dstport",
    "tcp.flags.str", "tcp.seq_raw", "tcp.ack_raw", "tcp.len",
    "tcp.window_size_value", "tcp.window_size",
]


def run_tshark(pcap):
    cmd = [TSHARK, "-r", pcap, "-T", "fields", "-E", "separator=/t", "-E", "occurrence=f"]
    for f in FIELDS:
        cmd += ["-e", f]
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        # 截断的 pcap (timeout 杀 tcpdump) ⇒ tshark 报 "cut short" 但仍转出己解析的行
        sys.stderr.write("[tshark rc=%d] %s\n" % (p.returncode,
                         p.stderr.decode("utf-8", "replace")[:200]))
        if not p.stdout.strip():
            sys.exit(1)
    rows = []
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split("\t")
        if len(parts) < len(FIELDS):
            continue
        rows.append(parts)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--board-ip", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--csv")
    a = ap.parse_args()

    rows = run_tshark(a.pcap)
    print("TSHARK_ROWS %d" % len(rows))
    if not rows:
        return

    # 握手: 找 SYN-ACK (board -> peer), 记录 wscale
    wscale = None
    for p in rows:
        if p[1] == a.board_ip and "SYN" in p[5] and "ACK" in p[5]:
            print("SYNACK t=%s ack=%s win_raw=%s flags=%s" % (p[0], p[7], p[9], p[5]))
            break
    # wscale 由 tshark 的 tcp.window_size (已算好的) 与 raw 的比值反推
    for p in rows:
        if p[1] == a.board_ip and p[9] and p[10]:
            try:
                raw, comp = int(p[9]), int(p[10])
            except ValueError:
                continue
            if raw > 0 and comp > raw:
                ws = 0
                c = comp
                while c > raw and ws < 14:
                    c >>= 1
                    ws += 1
                wscale = ws
                break
    print("WSCALE_EST %s (None=未观测到缩放/未捕获握手)" % wscale)

    # 收集板的纯 ACK (无载荷) 与数据包 —— **按 4 元组分组** (J6 单连接, 多连接 pcap 用)
    conns = {}
    data_frames = 0
    peer_bytes = 0
    for p in rows:
        try:
            t = float(p[0]); ack = int(p[7]); seq = int(p[6]); ln = int(p[8])
            win_raw = int(p[9]); win_c = int(p[10]); sp = p[3]; dp = p[4]
        except (ValueError, IndexError):
            continue
        if p[1] == a.board_ip:      # 板 -> 对端
            key = (sp, dp)
            if ln == 0:
                conns.setdefault(key, []).append((t, ack, win_raw, win_c))
            else:
                data_frames += 1
        else:                        # 对端 -> 板 (上行载荷)
            peer_bytes += ln
    if not conns:
        print("NO_BOARD_ACKS")
        return
    # 主连接 = ACK 数最多者 (J6 单连接即唯一)
    key_main = max(conns, key=lambda k: len(conns[k]))
    print("CONNS %d  MAIN %s->%s  acks=%d"
          % (len(conns), key_main[0], key_main[1], len(conns[key_main])))
    for k, v in sorted(conns.items(), key=lambda kv: -len(kv[1]))[:6]:
        print("  conn %s->%s acks=%d win_raw[%d..%d]"
              % (k[0], k[1], len(v), min(x[2] for x in v), max(x[2] for x in v)))
    ack_pts = conns[key_main]

    print("PEER_SENT_BYTES %d  BOARD_DATA_FRAMES %d  BOARD_ACKS %d"
          % (peer_bytes, data_frames, len(ack_pts)))
    if not ack_pts:
        return

    # redge 判据: ack + (win_raw << ws)  (ws=None 时按 0)
    ws = wscale or 0
    redge = [(t, ack + (w << ws), ack, w) for (t, ack, w, _c) in ack_pts if ack > 0]
    if not redge:
        print("NO_ACK_WITH_ACKNUM")
        return
    r0 = redge[0][1]
    rmin = min(r[1] for r in redge)
    rmax = max(r[1] for r in redge)
    print("REDGE first=%d min=%d max=%d (max-min=%d)" % (r0, rmin, rmax, rmax - rmin))
    print("WIN_RAW first=%d last=%d min=%d max=%d" %
          (redge[0][3], redge[-1][3], min(r[3] for r in redge), max(r[3] for r in redge)))

    # 打印前 12 / 后 12 个 ACK 点
    def show(pts, tag):
        print("--- %s ---" % tag)
        for (t, re_, ack, w) in pts:
            print("t=%8.4f ack=%10d win_raw=%6d redge_est=%10d" % (t, ack, w, re_))
    show(redge[:12], "first 12 board ACKs")
    show(redge[-12:], "last 12 board ACKs")

    # 分段 (每 1/8 窗) 的 redge 变化
    n = len(redge)
    print("--- per-octet redge (信用回收轨迹) ---")
    for k in range(8):
        seg = redge[k * n // 8:(k + 1) * n // 8]
        if not seg:
            continue
        print("seg%d t=[%.3f,%.3f] ack=[%d,%d] redge=[%d,%d] win_raw=[%d,%d]"
              % (k, seg[0][0], seg[-1][0], seg[0][2], seg[-1][2],
                 seg[0][1], seg[-1][1],
                 min(s[3] for s in seg), max(s[3] for s in seg)))

    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["t", "ack", "win_raw", "redge_est"])
            w.writerows(redge)
        print("CSV_WRITTEN %s" % a.csv)


if __name__ == "__main__":
    main()
