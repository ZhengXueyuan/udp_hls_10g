#!/usr/bin/env python3
"""f5b_rx_probe.py — F5 的 **RX 侧** 正/负对照 (对端机侧跑, 与 f5_probe.sh 同族).

背景 (已在 f5_probe/tcp_dump/xs_solve 里定案):
  · 板子在 TCP 上**不回显** —— 它**发自己的图案流**, 且每个新连接把图案 LFSR 归零
    (`P5d 文档: 板侧 ev_up 把 rx_lfsr <= SEED ⇒ 每连接图案归零`)。
    已用 GF(2) 线性求解证明: 收到的首 96 B 就是 xorshift64 流 offset 0 起 (状态 == 公共种子)。
  ⇒ 正确的 F5 激励 = **对端灌"正确的图案"** (板侧 app 校验器按 offset 0 起核对, W13 必须 0),
     而不是灌任意字节。

本脚本 (每轮: 连 -> 灌 4096 B -> 短 drain -> 关):
  轮 A **正确图案** (offset 0 起 4096 B) ⇒ 期望 W10/W11 (app 收帧/字节) 增长, **W13 (失配) 不变**;
  轮 B **错误图案** (同一段流整体 +1 字节偏移) ⇒ 期望 **W13 增长** (证明校验器有牙, 不是真空判据)。
判据: A 的 ΔW13 == 0 且 ΔW11 >= 4096 ; B 的 ΔW13 > 0。两条都成立才算 F5 的 RX 侧收口。
"""
import argparse
import socket
import sys
import time

M64 = (1 << 64) - 1
SEED = 0x9E3779B97F4A7C15


def step(s):
    s ^= (s << 13) & M64
    s ^= s >> 7
    s ^= (s << 17) & M64
    return s & M64


def pattern(n, skip=0):
    s = SEED
    for _ in range(skip):
        s = step(s)
    out = bytearray()
    for _ in range(n):
        out.append((s >> 24) & 0xFF)
        s = step(s)
    return bytes(out)


def rd(t, a):
    import os
    o = os.popen("%s/reg_rw /dev/xdma0_user %s w 2>/dev/null | tail -1" % (t, a)).read()
    return o.strip().split()[-1]


def snap(t, tag):
    import os
    os.system("%s/reg_rw /dev/xdma0_user 0x18 w 0x1 >/dev/null 2>&1" % t)
    s = ""
    for _ in range(400):
        s = rd(t, "0x1c")
        try:
            if int(s, 16) & 2:
                break
        except ValueError:
            pass
        time.sleep(0.002)
    d = {k: rd(t, a) for k, a in
         [("gen", "0x1c"), ("W0", "0x20"), ("W3", "0x2c"), ("W10", "0x48"), ("W11", "0x4c"),
          ("W12", "0x50"), ("W13", "0x54"), ("W14", "0x58"), ("W15", "0x5c"),
          ("W22", "0x78"), ("W23", "0x7c"), ("W39", "0xbc")]}
    print("SNAP %-4s %s gen=%d W0=%s W3=%s W10=%s W11=%s W12=%s W13=%s W14=%s W15=%s W22=%s W23=%s W39=%s"
          % (tag, time.time(), (int(s, 16) >> 16) & 0xFFFF, *[d[k] for k in
             ["W0", "W3", "W10", "W11", "W12", "W13", "W14", "W15", "W22", "W23", "W39"]]))
    return d


def send_once(board, port, payload, note):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(6.0)
    t0 = time.time()
    s.connect((board, port))
    print("  轮 %s: connect OK (%.2f ms)" % (note, (time.time() - t0) * 1e3))
    s.sendall(payload)
    s.settimeout(0.6)
    got = 0
    try:
        while got < 1 << 20:
            b = s.recv(65536)
            if not b:
                break
            got += len(b)
    except socket.timeout:
        pass
    print("  轮 %s: 灌 %d B ; 短 drain 收到板子 %d B" % (note, len(payload), got))
    s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--tools", default="/home/a/xdma_test/dma_ip_drivers-patched/XDMA/linux-kernel/tools")
    ap.add_argument("--n", type=int, default=4096)
    a = ap.parse_args()

    import os
    os.system("ip addr add 192.168.100.100/32 dev enp1s0f1np1 2>/dev/null")
    os.system("ip route add %s/32 dev enp1s0f1np1 src 192.168.100.100 2>/dev/null" % a.board)
    print("ROUTE %s" % os.popen("ip route get %s 2>&1 | head -1" % a.board).read().strip())

    good = pattern(a.n, 0)
    bad = pattern(a.n, 1)          # 整体差 1 字节 (偏移错) ⇒ 校验器必须抓到
    a0 = snap(a.tools, "A_pre")
    send_once(a.board, a.port, good, "正确图案")
    time.sleep(0.3)
    a1 = snap(a.tools, "A_post")
    send_once(a.board, a.port, bad, "错误图案")
    time.sleep(0.3)
    a2 = snap(a.tools, "B_post")

    def dd(x, y, k):
        return (int(y[k], 16) - int(x[k], 16)) & 0xFFFFFFFF

    d11 = dd(a0, a1, "W11")
    d13a = dd(a0, a1, "W13")
    d13b = dd(a1, a2, "W13")
    d10all = dd(a0, a2, "W10")
    d11all = dd(a0, a2, "W11")
    # ⚠️ 2026-09-30 订正 (P7B_W13_AUDIT.md §②-V4): 原文把 J_f5b 的 FAIL 归因成 "校验器是真空门" ——
    #   这是**对 oracle 能力的错误指控**, 也是唯一一条会推翻"校验器有牙"这个正确结论的假证据。
    #   真因: 本探针喂的是 **TCP** 载荷, 而本构建的 app 是 **UDP** 版 ⇒ 三块快照 W10=0x1 / W11=0x64
    #   **全程不变** ⇒ ΔW11 = 0 ⇒ **载荷从没喂进 app** ⇒ "期望 ΔW13 > 0" 这个前提本就不成立。
    #   校验器**有牙**: 教学期 G9 +1991 / G10 +1995; 逐字节精确性的反证见
    #   ISSUE_RX_BYTE_CORRUPTION.md:207-210。
    print("J_f5a 正确图案: ΔW11=%d (期望 >=%d) ; ΔW13=%d (期望 0) ⇒ %s"
          % (d11, a.n, d13a, "PASS" if (d11 >= a.n and d13a == 0) else "FAIL"))
    print("J_f5b 错误图案: ΔW13=%d (期望 >0) ⇒ %s"
          % (d13b, "PASS" if d13b > 0 else "未测(未喂进 app: ΔW10=%d, ΔW11=%d)" % (d10all, d11all)))
    print("附: ΔW0=%d ΔW3=%d ΔW10=%d ΔW14=%d ΔW15=%d ΔW22=%d ΔW23=%d"
          % (dd(a0, a2, "W0"), dd(a0, a2, "W3"), dd(a0, a2, "W10"), dd(a0, a2, "W14"),
             dd(a0, a2, "W15"), dd(a0, a2, "W22"), dd(a0, a2, "W23")))
    print("F5B_DONE")


main()
