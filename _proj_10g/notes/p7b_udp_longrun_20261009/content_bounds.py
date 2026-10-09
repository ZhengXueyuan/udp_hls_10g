#!/usr/bin/env python3
"""content_bounds.py -- 用 W8/W20 帧计数把抓包帧的**流绝对偏移区间**圈出来。

为什么: 板上 W9(app 字节) 3.604 s 就回卷, 长流的流绝对偏移早已 > 2^32 ⇒ 离线搜索必须
用**帧号**定位: 每帧载荷恰 1472 B ⇒ 第 n 帧 = 流偏移 [1472n, 1472(n+1))。
本脚本把 W8L 循环 (含 W5/W8/W9/W20, ~20 ms/点) 与 pcap 的**首末帧墙钟时间戳**对齐,
给出 [klo,khi] (帧号, 带 margin) 供 p7b_udp_content_check --klo/--khi 用。
"""
import re
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

loop, pcap = sys.argv[1], sys.argv[2]
margin = int(sys.argv[3]) if len(sys.argv) > 3 else 256

# --- 解析循环 ---
pts = []
cur = None
for line in open(loop, encoding="utf-8", errors="replace"):
    m = re.match(r"^W8L (\d+) ([\d.]+)", line)
    if m:
        cur = {"j": int(m.group(1)), "t": float(m.group(2)), "w": {}}
        pts.append(cur)
        continue
    m = re.match(r"^W(\d+)\s+\S+\s+(\S+)\s+(0x[0-9a-fA-F]+)", line)
    if m and cur is not None:
        cur["w"][int(m.group(1))] = int(m.group(3), 16)
print("LOOP points=%d first_t=%.6f last_t=%.6f" % (len(pts), pts[0]["t"], pts[-1]["t"]))

# --- 解析 pcap 首末时间戳 ---
d = open(pcap, "rb").read()
magic = struct.unpack("<I", d[:4])[0]
end = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
off = 24
ts_list = []
while off + 16 <= len(d):
    ts, tus, ln, orig = struct.unpack(end + "IIII", d[off:off + 16])
    off += 16 + ln
    ts_list.append(ts + tus / 1e6)
t0, t1 = ts_list[0], ts_list[-1]
print("PCAP frames=%d t_first=%.6f t_last=%.6f span_ms=%.3f" % (len(ts_list), t0, t1, (t1 - t0) * 1e3))

# --- 找包围点 ---
before = [p for p in pts if p["t"] <= t0]
after = [p for p in pts if p["t"] >= t1]
if not before or not after:
    print("BOUNDS_FAIL 循环与 pcap 时间不重叠 (拿不到包围点)")
    sys.exit(2)
a = before[-1]
b = after[0]
print("BRACKET before j=%d t=%.6f W5=%#x W8=%d W9=%#x W20=%d" %
      (a["j"], a["t"], a["w"].get(5, 0), a["w"].get(8, 0), a["w"].get(9, 0), a["w"].get(20, 0)))
print("BRACKET after  j=%d t=%.6f W5=%#x W8=%d W9=%#x W20=%d" %
      (b["j"], b["t"], b["w"].get(5, 0), b["w"].get(8, 0), b["w"].get(9, 0), b["w"].get(20, 0)))
klo = a["w"][20] - margin
khi = b["w"][20] + margin
print("BOUNDS klo=%d khi=%d span_frames=%d span_bytes=%d (margin=%d)" % (klo, khi, khi - klo, (khi - klo) * 1472, margin))
print("CHECK_CMD ./p7b_udp_content_check %s --klo %d --khi %d" % (pcap, klo, khi))
# 一致性: 抓包首帧的帧号若 = W20-1, 则偏移/1472 落在 [klo,khi] 内
