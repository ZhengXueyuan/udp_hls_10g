#!/usr/bin/env python3
"""tcp_echo_probe.py — F5 (TCP fast path @10G) 的**端到端定性**激励 + 判据 (对端机侧跑).

为什么是"定性": 规格 §6.1 F5 写的是"TCP fast path 在 10G 下不掉链（RTO/重传计数不异常）"。
但 `tx_stat_retx` 是 wrapper 的**内部 wire**, **不在 51 字快照窗口内** (证据: 51 字清单 +
`board/wrapper_p4.v:1496` 的注释 "暂留内部 wire") ⇒ 判据的"重传计数"那一半**结构性不可读**。
本脚本因此只给可读的那一半 + 端到端:
  ① TCP 三次握手必须完成 (板侧 = HLS 慢路径 `layer_tcp.cpp:17 TCP_PORT_ECHO 8080`);
  ② 载荷必须**逐字节回显** (HLS udp/tcp echo 的语义);
  ③ 多轮 (默认 3) 都要成功 ⇒ "不掉链"的定性证据;
  ④ 板侧读数 (另由 accept/探针取): W6/W7 慢路径动、W22 (TCP fast path 接受帧) 动、
     W3 (FCS 错) 恒 0、W39 PCS 状态位不掉。

⚠️ 每次发送前现补 /32 路由 (NetworkManager 会静默冲掉)。
用法: sudo python3 tcp_echo_probe.py [--board 192.168.100.2] [--port 8080] [--rounds 3] [--bytes 4096]
"""
import argparse
import os
import socket
import sys
import time


def pattern(n):
    return bytes((i * 7 + 13) & 0xFF for i in range(n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", default="192.168.100.2")
    ap.add_argument("--port", type=int, default=8080)     # HLS TCP_PORT_ECHO
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--bytes", type=int, default=4096)
    ap.add_argument("--iface", default="enp1s0f1np1")
    ap.add_argument("--src", default="192.168.100.100")
    a = ap.parse_args()

    # ---- 每次发送前现取现补路由 (本工程实测: /32 会被 NetworkManager 静默冲掉) ----
    print("ROUTE_BEFORE %s" % os.popen("ip route get %s 2>&1 | head -1" % a.board).read().strip())
    os.system("ip addr add %s/32 dev %s 2>/dev/null" % (a.src, a.iface))
    os.system("ip route add %s/32 dev %s src %s 2>/dev/null" % (a.board, a.iface, a.src))
    print("ROUTE_AFTER  %s" % os.popen("ip route get %s 2>&1 | head -1" % a.board).read().strip())

    payload = pattern(a.bytes)
    ok = 0
    for r in range(a.rounds):
        t0 = time.time()
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(6.0)
        try:
            s.connect((a.board, a.port))
            print("  轮%d: connect OK (%.1f ms)" % (r + 1, (time.time() - t0) * 1e3))
        except Exception as e:
            print("  轮%d: connect **失败**: %r (%.1f ms)" % (r + 1, e, (time.time() - t0) * 1e3))
            s.close()
            continue
        try:
            s.sendall(payload)
            got = b""
            while len(got) < len(payload):
                b = s.recv(65536)
                if not b:
                    break
                got += b
            el = time.time() - t0
            if got == payload:
                print("  轮%d: 回显 **逐字节相等** %d B (%.1f ms, %.2f Mbps)"
                      % (r + 1, len(got), el * 1e3, len(got) * 8 / max(el, 1e-9) / 1e6))
                ok += 1
            else:
                print("  轮%d: 回显 **不匹配**: 收到 %d B (期望 %d), 首个不同 @%s"
                      % (r + 1, len(got), len(payload),
                         next((i for i in range(min(len(got), len(payload))) if got[i] != payload[i]), "N/A")))
        except Exception as e:
            print("  轮%d: 传输异常: %r" % (r + 1, e))
        finally:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            s.close()
        time.sleep(0.5)
    print("TCP_ECHO_SUMMARY ok=%d/%d" % (ok, a.rounds))
    return 0 if ok == a.rounds else 1


sys.exit(main())
